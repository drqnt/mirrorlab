import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

private enum USBLowLatencyAudioError: LocalizedError {
    case missingFormat
    case unsupportedPCM
    case copyPCM(OSStatus)
    case converterUnavailable
    case outputComponentUnavailable
    case outputUnit(OSStatus)
    case conversion(String)

    var errorDescription: String? {
        switch self {
        case .missingFormat: return "USB audio format description недоступен"
        case .unsupportedPCM: return "USB screen stream не выдал PCM audio"
        case .copyPCM(let status): return "USB PCM copy: \(status)"
        case .converterUnavailable: return "USB PCM converter недоступен"
        case .outputComponentUnavailable: return "CoreAudio DefaultOutput недоступен"
        case .outputUnit(let status): return "CoreAudio output unit: \(status)"
        case .conversion(let message): return "USB PCM conversion: \(message)"
        }
    }
}

/// Wired screen audio is already PCM, so a queued sample-buffer renderer plus
/// media timeline synchronizer only adds a playback queue we do not need.
/// This path copies the capture sample into an AVAudioPCMBuffer, normalizes it to
/// interleaved Float32 if necessary, and feeds a very small ring pulled directly by
/// CoreAudio DefaultOutput.
final class SampleBufferAudioPlayer {
    private let queue = DispatchQueue(label: "MirrorLab.USBRealtimePCM", qos: .userInteractive)
    private let diagnostics: DiagnosticsStore

    var onStatus: ((String) -> Void)?
    var onQueueLead: ((Double) -> Void)?
    var onFormat: ((String) -> Void)?

    private var sourceFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var outputUnit: AudioUnit?
    private var ring: USBInterleavedPCMFrameRing?

    private var sampleRate: Double = 48_000
    private var channels: UInt32 = 2
    private var outputStarted = false
    private var sourceSignature = ""
    private var inputBuffers: UInt64 = 0
    private var converterFailures: UInt64 = 0
    private var overflowTrimEvents: UInt64 = 0
    private var trimmedFrames: UInt64 = 0
    // App-local gain. Kept on the same producer queue as PCM conversion so the
    // realtime CoreAudio callback never takes a lock or touches UserDefaults.
    private var outputVolume: Float = 1.0

    private var startupFrames: Int {
        // Wired transport has no network jitter. One capture packet / roughly
        // 10–20 ms is enough safety; the actual first packet may itself be larger.
        max(Int((sampleRate * 0.012).rounded()), 128)
    }

    private var maxLeadFrames: Int {
        max(Int((sampleRate * 0.050).rounded()), startupFrames * 2)
    }

    private var ringCapacityFrames: Int {
        max(Int((sampleRate * 0.100).rounded()), maxLeadFrames * 2, 2048)
    }

    init(diagnostics: DiagnosticsStore) {
        self.diagnostics = diagnostics
    }

    deinit { stop() }

    var reportDictionary: [String: Any] {
        queue.sync {
            let underflow = ring?.underflowSnapshot ?? (events: 0, frames: 0)
            return [
                "input_buffers": inputBuffers,
                "converter_failures": converterFailures,
                "overflow_trim_events": overflowTrimEvents,
                "trimmed_frames": trimmedFrames,
                "underflow_events": underflow.events,
                "underflow_frames": underflow.frames,
                "sample_rate": sampleRate,
                "channels": channels,
                "startup_target_ms": Double(startupFrames) / sampleRate * 1_000,
                "hard_lead_ceiling_ms": Double(maxLeadFrames) / sampleRate * 1_000,
                "output_volume": Double(outputVolume)
            ]
        }
    }


    func setOutputVolume(_ volume: Float) {
        let clamped = min(max(volume, 0), 1)
        queue.async { [weak self] in
            self?.outputVolume = clamped
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
                let frames = CMSampleBufferGetNumSamples(sampleBuffer)
                guard frames > 0 else { return }

                let signature = try self.ensureFormatLocked(for: sampleBuffer)
                guard let sourceFormat = self.sourceFormat,
                      let outputFormat = self.outputFormat,
                      let converter = self.converter,
                      let ring = self.ring else {
                    throw USBLowLatencyAudioError.converterUnavailable
                }

                guard let sourceBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    frameCapacity: AVAudioFrameCount(frames)
                ) else {
                    throw USBLowLatencyAudioError.unsupportedPCM
                }
                sourceBuffer.frameLength = AVAudioFrameCount(frames)

                let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                    sampleBuffer,
                    at: 0,
                    frameCount: Int32(frames),
                    into: sourceBuffer.mutableAudioBufferList
                )
                guard copyStatus == noErr else {
                    throw USBLowLatencyAudioError.copyPCM(copyStatus)
                }

                let ratio = outputFormat.sampleRate / max(sourceFormat.sampleRate, 1)
                let capacity = AVAudioFrameCount(max(Int((Double(frames) * ratio).rounded(.up)) + 64, frames))
                guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                    throw USBLowLatencyAudioError.unsupportedPCM
                }

                var supplied = false
                var conversionError: NSError?
                let result = converter.convert(to: converted, error: &conversionError) { _, status in
                    if supplied {
                        status.pointee = .noDataNow
                        return nil
                    }
                    supplied = true
                    status.pointee = .haveData
                    return sourceBuffer
                }
                if let conversionError {
                    throw USBLowLatencyAudioError.conversion(conversionError.localizedDescription)
                }
                guard converted.frameLength > 0,
                      result == .haveData || result == .inputRanDry || result == .endOfStream else {
                    self.converterFailures &+= 1
                    self.diagnostics.recordAudioDrop()
                    return
                }

                let buffers = UnsafeMutableAudioBufferListPointer(converted.mutableAudioBufferList)
                guard buffers.count == 1, let data = buffers[0].mData else {
                    throw USBLowLatencyAudioError.conversion("ожидался interleaved Float32 PCM")
                }

                let outputFrames = Int(converted.frameLength)
                let excess = max(0, ring.availableFrames + outputFrames - self.maxLeadFrames)
                if excess > 0 {
                    ring.discardOldest(frames: excess)
                    self.overflowTrimEvents &+= 1
                    self.trimmedFrames &+= UInt64(excess)
                    self.diagnostics.recordAudioDrop()
                }

                ring.writeInterleaved(
                    data.assumingMemoryBound(to: Float.self),
                    frames: outputFrames,
                    gain: self.outputVolume
                )
                self.inputBuffers &+= 1
                self.diagnostics.recordAudio(pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

                let lead = ring.availableFrames
                self.onQueueLead?(Double(lead) / self.sampleRate * 1_000)

                if !self.outputStarted, lead >= self.startupFrames {
                    guard let outputUnit = self.outputUnit else {
                        throw USBLowLatencyAudioError.outputComponentUnavailable
                    }
                    let status = AudioOutputUnitStart(outputUnit)
                    guard status == noErr else { throw USBLowLatencyAudioError.outputUnit(status) }
                    self.outputStarted = true
                    self.onStatus?("PCM realtime")
                    self.diagnostics.addEvent(
                        "USB audio: direct CoreAudio output запущен; startup target ~\(Int((Double(self.startupFrames) / self.sampleRate * 1_000).rounded())) ms."
                    )
                }

                if self.inputBuffers == 1 {
                    self.diagnostics.addEvent("USB audio: \(signature) → interleaved Float32 → CoreAudio DefaultOutput")
                }
            } catch {
                self.converterFailures &+= 1
                self.diagnostics.recordAudioDrop()
                self.onStatus?("Ошибка USB PCM")
                if self.converterFailures <= 4 {
                    self.diagnostics.addEvent("USB low-latency audio: \(error.localizedDescription)", level: .error)
                }
            }
        }
    }

    func stop() {
        queue.sync {
            stopOutputUnitLocked()
            sourceFormat = nil
            outputFormat = nil
            converter = nil
            ring?.clear()
            ring = nil
            sourceSignature = ""
            outputStarted = false
            onQueueLead?(0)
            onStatus?("Остановлен")
        }
    }

    fileprivate func render(frames requestedFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        for index in buffers.indices {
            if let data = buffers[index].mData {
                memset(data, 0, Int(buffers[index].mDataByteSize))
            }
        }
        guard let ring, buffers.count == 1, let output = buffers[0].mData else { return noErr }
        _ = ring.readInterleavedRealtime(
            into: output.assumingMemoryBound(to: Float.self),
            frames: Int(requestedFrames),
            prerollFrames: startupFrames
        )
        return noErr
    }

    @discardableResult
    private func ensureFormatLocked(for sampleBuffer: CMSampleBuffer) throws -> String {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            throw USBLowLatencyAudioError.missingFormat
        }
        var asbd = pointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            throw USBLowLatencyAudioError.unsupportedPCM
        }

        let signature = [
            String(asbd.mSampleRate), String(asbd.mFormatID), String(asbd.mFormatFlags),
            String(asbd.mBytesPerPacket), String(asbd.mFramesPerPacket), String(asbd.mBytesPerFrame),
            String(asbd.mChannelsPerFrame), String(asbd.mBitsPerChannel)
        ].joined(separator: ":")
        if signature == sourceSignature, converter != nil { return describe(asbd) }

        stopOutputUnitLocked()
        sourceFormat = nil
        outputFormat = nil
        converter = nil
        ring = nil

        guard let source = AVAudioFormat(streamDescription: &asbd),
              let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: asbd.mSampleRate,
                channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
                interleaved: true
              ),
              let converter = AVAudioConverter(from: source, to: output) else {
            throw USBLowLatencyAudioError.converterUnavailable
        }
        converter.primeMethod = .none

        sampleRate = asbd.mSampleRate
        channels = asbd.mChannelsPerFrame
        sourceFormat = source
        outputFormat = output
        self.converter = converter
        ring = USBInterleavedPCMFrameRing(capacityFrames: ringCapacityFrames, channels: Int(channels))
        sourceSignature = signature
        try createOutputUnitLocked(outputFormat: output)

        let label = describe(asbd)
        onFormat?(label)
        onStatus?("PCM готов")
        return label
    }

    private func describe(_ asbd: AudioStreamBasicDescription) -> String {
        "Linear PCM \(Int(asbd.mSampleRate.rounded())) Hz / \(asbd.mChannelsPerFrame)ch / \(asbd.mBitsPerChannel)-bit"
    }

    private func createOutputUnitLocked(outputFormat: AVAudioFormat) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw USBLowLatencyAudioError.outputComponentUnavailable
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else { throw USBLowLatencyAudioError.outputUnit(status) }

        var stream = outputFormat.streamDescription.pointee
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &stream,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw USBLowLatencyAudioError.outputUnit(status)
        }

        var callback = AURenderCallbackStruct(
            inputProc: mirrorLabUSBAudioRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw USBLowLatencyAudioError.outputUnit(status)
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw USBLowLatencyAudioError.outputUnit(status)
        }
        outputUnit = unit
        outputStarted = false
    }

    private func stopOutputUnitLocked() {
        guard let outputUnit else { return }
        if outputStarted { AudioOutputUnitStop(outputUnit) }
        AudioUnitUninitialize(outputUnit)
        AudioComponentInstanceDispose(outputUnit)
        self.outputUnit = nil
        outputStarted = false
    }
}

private let mirrorLabUSBAudioRenderCallback: AURenderCallback = {
    refCon, _, _, _, numberFrames, ioData in
    let player = Unmanaged<SampleBufferAudioPlayer>.fromOpaque(refCon).takeUnretainedValue()
    return player.render(frames: numberFrames, ioData: ioData)
}

private final class USBInterleavedPCMFrameRing {
    private let lock = NSLock()
    private let capacityFrames: Int
    private let channels: Int
    private var storage: [Float]
    private var readFrame = 0
    private var writeFrame = 0
    private var frameCount = 0
    private var underflowEvents: UInt64 = 0
    private var underflowFrames: UInt64 = 0
    private var rebuffering = true

    init(capacityFrames: Int, channels: Int) {
        self.capacityFrames = max(capacityFrames, 1)
        self.channels = max(channels, 1)
        self.storage = [Float](repeating: 0, count: self.capacityFrames * self.channels)
    }

    var availableFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return frameCount
    }

    var underflowSnapshot: (events: UInt64, frames: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (underflowEvents, underflowFrames)
    }

    func writeInterleaved(_ input: UnsafePointer<Float>, frames: Int, gain: Float = 1) {
        guard frames > 0 else { return }
        lock.lock(); defer { lock.unlock() }

        var sourceFrame = 0
        var framesToWrite = frames
        if framesToWrite > capacityFrames {
            sourceFrame = framesToWrite - capacityFrames
            framesToWrite = capacityFrames
            readFrame = 0; writeFrame = 0; frameCount = 0
        }
        let overflow = max(0, frameCount + framesToWrite - capacityFrames)
        if overflow > 0 {
            readFrame = (readFrame + overflow) % capacityFrames
            frameCount -= overflow
        }
        for frame in 0..<framesToWrite {
            let dst = ((writeFrame + frame) % capacityFrames) * channels
            let src = (sourceFrame + frame) * channels
            for channel in 0..<channels {
                storage[dst + channel] = input[src + channel] * gain
            }
        }
        writeFrame = (writeFrame + framesToWrite) % capacityFrames
        frameCount += framesToWrite
    }

    @discardableResult
    func readInterleavedRealtime(
        into output: UnsafeMutablePointer<Float>,
        frames: Int,
        prerollFrames: Int
    ) -> Int {
        guard frames > 0 else { return 0 }
        lock.lock(); defer { lock.unlock() }

        if rebuffering {
            guard frameCount >= max(prerollFrames, frames) else { return 0 }
            rebuffering = false
        }
        guard frameCount >= frames else {
            underflowEvents &+= 1
            underflowFrames &+= UInt64(max(frames - frameCount, 0))
            rebuffering = true
            return 0
        }
        for frame in 0..<frames {
            let src = ((readFrame + frame) % capacityFrames) * channels
            let dst = frame * channels
            for channel in 0..<channels { output[dst + channel] = storage[src + channel] }
        }
        readFrame = (readFrame + frames) % capacityFrames
        frameCount -= frames
        return frames
    }

    func discardOldest(frames: Int) {
        guard frames > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let count = min(frames, frameCount)
        readFrame = (readFrame + count) % capacityFrames
        frameCount -= count
    }

    func clear() {
        lock.lock()
        readFrame = 0; writeFrame = 0; frameCount = 0
        underflowEvents = 0; underflowFrames = 0; rebuffering = true
        lock.unlock()
    }
}
