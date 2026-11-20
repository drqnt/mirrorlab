import AudioToolbox
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

private enum AirPlayLowLatencyAudioError: LocalizedError {
    case invalidFormat
    case converterUnavailable
    case outputComponentUnavailable
    case outputUnit(OSStatus)
    case conversion(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "AAC-ELD/PCM audio format недоступен"
        case .converterUnavailable:
            return "AVAudioConverter AAC-ELD → PCM недоступен"
        case .outputComponentUnavailable:
            return "CoreAudio DefaultOutput недоступен"
        case .outputUnit(let status):
            return "CoreAudio output unit: \(status)"
        case .conversion(let message):
            return "AAC-ELD decode: \(message)"
        }
    }
}

/// What the Mac's current audio output adds on top of MirrorLab's own buffer.
struct AirPlayAudioOutputInfo {
    let deviceName: String
    let transport: String
    /// Bluetooth / AirPlay / virtual / aggregate outputs routinely add 100 ms–2 s.
    let isHighLatencyTransport: Bool
    /// Device + safety offset + stream latency + IO buffer, as reported by CoreAudio.
    let reportedLatencyMS: Double
    let bufferFrames: UInt32
    let sampleRate: Double

    var summary: String {
        "\(deviceName) • \(transport) • ~\(Int(reportedLatencyMS.rounded())) мс"
    }
}

/// Snapshot for reports / diagnostics.
struct AirPlayAudioLatencySnapshot {
    let leadMS: Double
    let floorMS: Double
    let prerollMS: Double
    let adaptiveMarginMS: Double
    let drainedMS: Double
    let silencePackets: UInt64
    let underflowEvents: UInt64
    let output: AirPlayAudioOutputInfo?
}

/// Receiver-side audio buffering policy, derived from the shared "Буфер Wi-Fi" mode.
private struct AirPlayAudioBufferPolicy {
    /// Cushion collected before output starts / restarts after an underrun.
    let preroll: TimeInterval
    /// Desired minimum cushion just before a packet arrives. A persistently higher
    /// floor is pure latency and is drained by slight time compression.
    let floor: TimeInterval
    /// Hard ceiling; oldest PCM above it is trimmed.
    let cap: TimeInterval
    /// Extra cushion added after every real underrun, and its upper bound.
    let marginStep: TimeInterval
    let maximumMargin: TimeInterval
    /// Packets without an underrun before the extra cushion starts to decay.
    let marginHoldPackets: Int

    init(mode: AirPlayBufferMode) {
        switch mode {
        case .lowLatency:
            preroll = 0.030; floor = 0.008; cap = 0.120
            marginStep = 0.010; maximumMargin = 0.080; marginHoldPackets = 370
        case .balanced:
            preroll = 0.045; floor = 0.015; cap = 0.220
            marginStep = 0.020; maximumMargin = 0.120; marginHoldPackets = 730
        case .smooth:
            preroll = 0.080; floor = 0.035; cap = 0.300
            marginStep = 0.020; maximumMargin = 0.160; marginHoldPackets = 920
        }
    }
}

/// Minimal-latency AirPlay mirror audio path.
///
/// This intentionally does NOT use a queued sample-buffer media renderer or a media
/// synchronizer. MirrorLab is a live/game mirror: one unique AAC-ELD RTP access
/// unit is decoded immediately to interleaved Float32 PCM and put into a tiny
/// bounded ring. The hardware DefaultOutput AudioUnit pulls PCM directly.
///
/// 0.3.50 latency fixes (0.3.45–0.3.49 effectively sat at the ~220 ms ceiling):
/// * Apple's 4-byte AAC-ELD silence packets used to be dropped before sequencing, so
///   every quiet moment looked like a long RTP loss and the loss path padded the ring
///   with silence up to the 220 ms ceiling. They now keep the sequence continuous and
///   let the ring drain, so each quiet moment resets latency to the preroll.
/// * Loss concealment only restores the preroll cushion instead of filling to the cap.
/// * Nothing ever removed surplus PCM (sender clock drift, post-stall bursts). The
///   cushion floor is now tracked over ~1.5 s and surplus is drained by 2–6 % time
///   compression; real underruns add adaptive margin that decays when Wi-Fi calms.
///
/// 0.3.45 RTP control-channel resend recovery and faded concealment are unchanged.
final class AirPlayLowLatencyAudioPlayer {
    private let queue = DispatchQueue(label: "MirrorLab.AirPlayPCM", qos: .userInteractive)
    private let diagnostics: DiagnosticsStore

    var onStatus: ((String) -> Void)?
    var onQueueLead: ((Double) -> Void)?
    var onSequenceGap: ((UInt64) -> Void)?
    var onRedundantPackets: ((UInt64) -> Void)?
    /// Called as soon as a forward RTP hole is observed. The controller sends
    /// an AirPlay/RAOP range-resend request on the sender's control port.
    var onResendRequest: ((UInt16, UInt16) -> Void)?
    /// Called whenever the CoreAudio output unit is (re)created.
    var onOutputInfo: ((AirPlayAudioOutputInfo?) -> Void)?

    private var sourceFormat: AVAudioFormat?
    private var pcmFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var outputUnit: AudioUnit?
    private var ring: InterleavedPCMFrameRing?
    private var outputInfo: AirPlayAudioOutputInfo?

    private var sampleRate: Double = 44_100
    private var channels: UInt32 = 2
    private var framesPerPacket: UInt32 = 480
    private var outputStarted = false

    private struct BufferedAACPacket {
        let payload: Data
        let rtpTimestamp: UInt32
        let sequence: UInt16
        let isSilence: Bool
    }

    private var expectedSequence: UInt16?
    private var pendingPackets: [UInt16: BufferedAACPacket] = [:]
    private var resendRequestedSequences: Set<UInt16> = []
    // A resend round-trip on local Wi-Fi commonly fits inside 30-50 ms. Hold only
    // after an actual hole, never during normal in-order playback. Six AAC-ELD
    // packets are ~65 ms at 44.1 kHz / 480 spf.
    private let reorderWindowPackets: UInt16 = 6
    // Longer holes are a discontinuity, not a packet loss: no silence padding.
    private let maximumConcealedPackets = 8
    private var sequenceGaps: UInt64 = 0
    private var redundantPackets: UInt64 = 0
    private var redundancyLogged = false
    private var recoveryLogged = false
    private var firstPacketLogged = false
    private var decodedPackets: UInt64 = 0
    private var converterFailures: UInt64 = 0
    // MirrorLab-local output gain. It is applied while decoded PCM is written on
    // this player's serial queue, keeping the hardware render callback lock-free.
    private var outputVolume: Float = 1.0

    // Adaptive latency control (all on `queue`).
    private var policy = AirPlayAudioBufferPolicy(mode: .balanced)
    private var adaptiveMargin: TimeInterval = 0
    private var observedUnderflowEvents: UInt64 = 0
    private var packetsSinceUnderflow = 0
    private var floorWindow = PacketWindowMinimum(capacity: 140)
    private var draining = false
    private var drainedFrames: UInt64 = 0
    private var silencePackets: UInt64 = 0
    // Manually owned so the pointer handed to the ring stays valid (no escaping
    // withUnsafeMutableBufferPointer pointer).
    private var resampleScratch: UnsafeMutablePointer<Float>?
    private var resampleScratchCapacity = 0

    private var startupFrames: Int {
        max(Int(((policy.preroll + adaptiveMargin) * sampleRate).rounded()), Int(framesPerPacket) * 2, 1)
    }

    private var floorTargetFrames: Int {
        Int(((policy.floor + adaptiveMargin) * sampleRate).rounded())
    }

    private var drainHysteresisFrames: Int {
        Int((0.010 * sampleRate).rounded())
    }

    private var maxLeadFrames: Int {
        max(Int((policy.cap * sampleRate).rounded()), startupFrames + Int(framesPerPacket) * 4)
    }

    private var ringCapacityFrames: Int {
        max(Int((sampleRate * 0.600).rounded()), Int(framesPerPacket) * 16, 8192)
    }

    init(diagnostics: DiagnosticsStore) {
        self.diagnostics = diagnostics
    }

    deinit {
        stop()
        resampleScratch?.deallocate()
    }

    func setOutputVolume(_ volume: Float) {
        let clamped = min(max(volume, 0), 1)
        queue.async { [weak self] in
            self?.outputVolume = clamped
        }
    }

    /// Shares the video "Буфер Wi-Fi" mode. Takes effect on the next packet.
    func setLatencyMode(_ mode: AirPlayBufferMode) {
        queue.async { [weak self] in
            guard let self else { return }
            self.policy = AirPlayAudioBufferPolicy(mode: mode)
            self.adaptiveMargin = min(self.adaptiveMargin, self.policy.maximumMargin)
            self.floorWindow.reset()
            self.draining = false
            self.ring?.setPrerollFrames(self.startupFrames)
        }
    }

    func latencySnapshot() -> AirPlayAudioLatencySnapshot {
        queue.sync {
            let rate = max(sampleRate, 1)
            let lead = Double(ring?.availableFrames ?? 0)
            let floor = Double(floorWindow.minimum ?? 0)
            return AirPlayAudioLatencySnapshot(
                leadMS: lead / rate * 1_000,
                floorMS: floor / rate * 1_000,
                prerollMS: Double(startupFrames) / rate * 1_000,
                adaptiveMarginMS: adaptiveMargin * 1_000,
                drainedMS: Double(drainedFrames) / rate * 1_000,
                silencePackets: silencePackets,
                underflowEvents: ring?.underflowSnapshot.events ?? observedUnderflowEvents,
                output: outputInfo
            )
        }
    }

    func configure(sampleRate: Double, channels: UInt32, framesPerPacket: UInt32) throws {
        try queue.sync {
            if converter != nil,
               self.sampleRate == sampleRate,
               self.channels == channels,
               self.framesPerPacket == framesPerPacket {
                onStatus?(outputStarted ? "PCM realtime" : "AAC-ELD готов")
                return
            }

            stopOutputUnitLocked()
            converter = nil
            sourceFormat = nil
            pcmFormat = nil
            ring = nil

            var sourceASBD = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatMPEG4AAC_ELD,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: framesPerPacket,
                mBytesPerFrame: 0,
                mChannelsPerFrame: channels,
                mBitsPerChannel: 0,
                mReserved: 0
            )

            // Let CoreAudio normalize any codec-specific ASBD fields it knows.
            var sourceSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            _ = AudioFormatGetProperty(
                kAudioFormatProperty_FormatInfo,
                0,
                nil,
                &sourceSize,
                &sourceASBD
            )

            guard let source = AVAudioFormat(streamDescription: &sourceASBD),
                  let pcm = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: AVAudioChannelCount(channels),
                    interleaved: true
                  ),
                  let converter = AVAudioConverter(from: source, to: pcm) else {
                throw AirPlayLowLatencyAudioError.invalidFormat
            }

            // "None" is AVAudioConverter's latency mode: do not add normal media
            // priming in front of a conferencing-oriented AAC-ELD stream.
            converter.primeMethod = .none

            self.sampleRate = sampleRate
            self.channels = channels
            self.framesPerPacket = framesPerPacket
            self.sourceFormat = source
            self.pcmFormat = pcm
            self.converter = converter
            self.ring = InterleavedPCMFrameRing(
                capacityFrames: ringCapacityFrames,
                channels: Int(channels)
            )
            resetTimelineLocked(resetCounters: false)
            ring?.setPrerollFrames(startupFrames)
            try createOutputUnitLocked(pcmFormat: pcm)
            onQueueLead?(0)
            onStatus?("AAC-ELD → PCM готов")
        }
    }

    func enqueueAACELD(_ payload: Data, rtpTimestamp: UInt32, sequence: UInt16) {
        guard !payload.isEmpty else { return }
        enqueue(BufferedAACPacket(payload: payload, rtpTimestamp: rtpTimestamp, sequence: sequence, isSilence: false))
    }

    /// Apple's 4-byte AAC-ELD "no media" packet. It carries a real RTP sequence number,
    /// so it must go through sequencing (otherwise resumed audio looks like a loss),
    /// but it produces no PCM: the ring drains and the next sound restarts at preroll.
    func enqueueSilenceMarker(rtpTimestamp: UInt32, sequence: UInt16) {
        enqueue(BufferedAACPacket(payload: Data(), rtpTimestamp: rtpTimestamp, sequence: sequence, isSilence: true))
    }

    private func enqueue(_ packet: BufferedAACPacket) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard let sourceFormat = self.sourceFormat,
                      let pcmFormat = self.pcmFormat,
                      let converter = self.converter,
                      let ring = self.ring else {
                    throw AirPlayLowLatencyAudioError.converterUnavailable
                }

                try self.stagePacket(
                    packet,
                    sourceFormat: sourceFormat,
                    pcmFormat: pcmFormat,
                    converter: converter,
                    ring: ring
                )
            } catch {
                self.converterFailures &+= 1
                self.diagnostics.recordAirPlayAudioConverterFailure()
                self.onStatus?("Ошибка AAC-ELD → PCM")
                if self.converterFailures <= 3 {
                    self.diagnostics.addEvent(
                        "AirPlay low-latency audio: \(error.localizedDescription)",
                        level: .error
                    )
                }
            }
        }
    }

    /// Keep normal in-order audio zero-extra-latency. Only when a sequence hole is
    /// visible do we hold the future packets for up to `reorderWindowPackets` steps.
    /// `redundantAudio=2` means later UDP datagrams commonly carry a second/third
    /// copy of the missing sequence, so this repairs Wi-Fi reordering without a
    /// permanent 20-30 ms jitter buffer.
    private func stagePacket(
        _ packet: BufferedAACPacket,
        sourceFormat: AVAudioFormat,
        pcmFormat: AVAudioFormat,
        converter: AVAudioConverter,
        ring: InterleavedPCMFrameRing
    ) throws {
        if expectedSequence == nil {
            expectedSequence = packet.sequence
        }
        guard let expected = expectedSequence else { return }

        let distance = UInt16(truncatingIfNeeded: packet.sequence &- expected)
        if distance >= 0x8000 || pendingPackets[packet.sequence] != nil {
            recordRedundantPacket()
            return
        }

        if distance == 0, resendRequestedSequences.remove(packet.sequence) != nil {
            diagnostics.recordAirPlayAudioLateRecovery()
            if !recoveryLogged {
                recoveryLogged = true
                diagnostics.addEvent(
                    "AirPlay audio: потерянный RTP packet восстановлен через control-port resend до декодера."
                )
            }
        }

        if distance > 0 {
            // Ask the sender for the missing range immediately. Do not spam the
            // same sequence again while it is still inside the short reorder window.
            let requestCount = min(distance, 16)
            var firstUnrequested: UInt16?
            var contiguousCount: UInt16 = 0
            for offset in 0..<requestCount {
                let sequence = expected &+ offset
                if !resendRequestedSequences.contains(sequence) {
                    if firstUnrequested == nil { firstUnrequested = sequence }
                    resendRequestedSequences.insert(sequence)
                    contiguousCount &+= 1
                } else if firstUnrequested != nil {
                    break
                }
            }
            if let firstUnrequested, contiguousCount > 0 {
                onResendRequest?(firstUnrequested, contiguousCount)
            }
        }

        pendingPackets[packet.sequence] = packet
        try drainPendingPackets(
            sourceFormat: sourceFormat,
            pcmFormat: pcmFormat,
            converter: converter,
            ring: ring
        )
    }

    private func drainPendingPackets(
        sourceFormat: AVAudioFormat,
        pcmFormat: AVAudioFormat,
        converter: AVAudioConverter,
        ring: InterleavedPCMFrameRing
    ) throws {
        while let expected = expectedSequence {
            if let packet = pendingPackets.removeValue(forKey: expected) {
                resendRequestedSequences.remove(expected)
                expectedSequence = expected &+ 1
                if packet.isSilence {
                    noteSilencePacket(ring: ring)
                } else {
                    try decodeUniquePacket(
                        packet,
                        sourceFormat: sourceFormat,
                        pcmFormat: pcmFormat,
                        converter: converter,
                        ring: ring
                    )
                }
                continue
            }

            let forwardDistances = pendingPackets.keys.compactMap { sequence -> UInt16? in
                let distance = UInt16(truncatingIfNeeded: sequence &- expected)
                guard distance > 0, distance < 0x8000 else { return nil }
                return distance
            }
            guard let nearest = forwardDistances.min(),
                  let furthest = forwardDistances.max(),
                  furthest >= reorderWindowPackets else {
                return
            }

            // The missing packet survived the entire redundancy horizon. Advance
            // only to the nearest packet we actually have. Conceal a short loss only
            // up to the preroll cushion it would otherwise eat; a long hole is a
            // discontinuity and must not be turned into extra latency.
            let missingPackets = Int(nearest)
            sequenceGaps &+= UInt64(missingPackets)
            onSequenceGap?(sequenceGaps)

            if missingPackets <= maximumConcealedPackets {
                let requestedConcealmentFrames = missingPackets * Int(framesPerPacket)
                let availableRoom = max(0, startupFrames - ring.availableFrames)
                let concealed = min(requestedConcealmentFrames, availableRoom)
                if concealed > 0 {
                    // A short fade-out / fade-in is much less offensive on music than
                    // inserting a hard block of digital zeroes.
                    ring.writeConcealment(frames: concealed)
                    diagnostics.recordAirPlayAudioConcealment(frames: concealed)
                }
            }
            for offset in 0..<nearest {
                resendRequestedSequences.remove(expected &+ offset)
            }
            expectedSequence = expected &+ nearest
        }
    }

    private func noteSilencePacket(ring: InterleavedPCMFrameRing) {
        silencePackets &+= 1
        ring.noteSilence()
        // Old cushion statistics describe the sound before the pause.
        floorWindow.reset()
        draining = false
    }

    private func recordRedundantPacket() {
        redundantPackets &+= 1
        onRedundantPackets?(redundantPackets)
        if !redundancyLogged, redundantPackets >= 8 {
            redundancyLogged = true
            diagnostics.addEvent(
                "AirPlay audio: redundantAudio=2 копии используются как loss-recovery и дубликаты отбрасываются."
            )
        }
    }

    /// Underruns grow the cushion; a long clean stretch lets it shrink again.
    private func updateAdaptiveMargin(ring: InterleavedPCMFrameRing) {
        let events = ring.underflowSnapshot.events
        if events != observedUnderflowEvents {
            observedUnderflowEvents = events
            adaptiveMargin = min(adaptiveMargin + policy.marginStep, policy.maximumMargin)
            packetsSinceUnderflow = 0
            floorWindow.reset()
            draining = false
            ring.setPrerollFrames(startupFrames)
            return
        }
        packetsSinceUnderflow += 1
        if adaptiveMargin > 0,
           packetsSinceUnderflow > policy.marginHoldPackets,
           packetsSinceUnderflow % 90 == 0 {
            adaptiveMargin = max(0, adaptiveMargin - 0.001)
            ring.setPrerollFrames(startupFrames)
        }
    }

    private func decodeUniquePacket(
        _ packet: BufferedAACPacket,
        sourceFormat: AVAudioFormat,
        pcmFormat: AVAudioFormat,
        converter: AVAudioConverter,
        ring: InterleavedPCMFrameRing
    ) throws {
        let compressed = AVAudioCompressedBuffer(
            format: sourceFormat,
            packetCapacity: 1,
            maximumPacketSize: max(packet.payload.count, 1)
        )
        packet.payload.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                memcpy(compressed.data, base, packet.payload.count)
            }
        }
        compressed.byteLength = UInt32(packet.payload.count)
        compressed.packetCount = 1
        if let descriptions = compressed.packetDescriptions {
            descriptions[0] = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: framesPerPacket,
                mDataByteSize: UInt32(packet.payload.count)
            )
        }

        let outputCapacity = AVAudioFrameCount(max(Int(framesPerPacket) * 2, 1024))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: outputCapacity) else {
            throw AirPlayLowLatencyAudioError.invalidFormat
        }

        var suppliedInput = false
        var conversionError: NSError?
        let result = converter.convert(to: pcm, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return compressed
        }

        if let conversionError {
            throw AirPlayLowLatencyAudioError.conversion(conversionError.localizedDescription)
        }

        guard pcm.frameLength > 0,
              result == .haveData || result == .inputRanDry else {
            converterFailures &+= 1
            if converterFailures <= 3 {
                diagnostics.addEvent(
                    "AirPlay AAC-ELD decoder не выдал PCM (status \(result.rawValue)).",
                    level: .warning
                )
            }
            diagnostics.recordAirPlayAudioConverterFailure()
            return
        }

        let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        guard buffers.count == 1,
              let pcmData = buffers[0].mData else {
            throw AirPlayLowLatencyAudioError.conversion("ожидался interleaved Float32 PCM")
        }

        updateAdaptiveMargin(ring: ring)

        let decodedFrames = Int(pcm.frameLength)
        let availableBefore = ring.availableFrames
        var source = UnsafePointer<Float>(pcmData.assumingMemoryBound(to: Float.self))
        var frames = decodedFrames

        // Cushion floor = lowest PCM level seen just before a packet arrived during
        // the last ~1.5 s. Anything persistently above the target is latency: drain
        // it by playing this packet 2–6 % faster (linear resample, no hard cut).
        let floor = floorWindow.push(availableBefore)
        if outputStarted, floorWindow.isFull {
            let target = floorTargetFrames
            if floor > target + drainHysteresisFrames {
                draining = true
            } else if floor <= target {
                draining = false
            }
            if draining {
                let excess = floor - target
                let ratio: Double
                if excess > Int(0.080 * sampleRate) {
                    ratio = 0.06
                } else if excess > Int(0.030 * sampleRate) {
                    ratio = 0.04
                } else {
                    ratio = 0.02
                }
                let drop = min(excess, max(1, Int(Double(decodedFrames) * ratio)))
                if drop > 0, decodedFrames - drop >= 2 {
                    frames = decodedFrames - drop
                    source = UnsafePointer(compressFrames(source, from: decodedFrames, to: frames))
                    drainedFrames &+= UInt64(drop)
                }
            }
        }

        let excess = max(0, availableBefore + frames - maxLeadFrames)
        if excess > 0 {
            ring.discardOldest(frames: excess)
            diagnostics.recordAirPlayAudioOverflowTrim(frames: excess)
        }

        ring.writeInterleaved(
            source,
            frames: frames,
            gain: outputVolume
        )
        // `source` may point into `pcm`; keep the buffer alive until the copy is done.
        withExtendedLifetime(pcm) {}
        decodedPackets &+= 1
        diagnostics.recordAudio(pts: .invalid)

        let leadFrames = ring.availableFrames
        onQueueLead?(Double(leadFrames) / sampleRate * 1_000)
        let underflow = ring.underflowSnapshot
        diagnostics.setAirPlayAudioUnderflow(
            events: underflow.events,
            frames: underflow.frames
        )

        if !outputStarted, leadFrames >= startupFrames {
            guard let outputUnit else {
                throw AirPlayLowLatencyAudioError.outputComponentUnavailable
            }
            let status = AudioOutputUnitStart(outputUnit)
            guard status == noErr else {
                throw AirPlayLowLatencyAudioError.outputUnit(status)
            }
            outputStarted = true
            onStatus?("PCM realtime")
            diagnostics.addEvent(
                "AirPlay audio: CoreAudio PCM output запущен с ~\(Int((Double(startupFrames) / sampleRate * 1000).rounded())) ms preroll."
            )
        }

        if !firstPacketLogged {
            firstPacketLogged = true
            diagnostics.addEvent(
                "AirPlay audio: первый AAC-ELD packet декодирован напрямую в PCM (\(packet.payload.count) B, seq \(packet.sequence), RTP \(packet.rtpTimestamp))."
            )
        }
    }

    /// Linear-interpolation time compression of one decoded packet. First and last
    /// frames are preserved, so consecutive packets stay continuous.
    private func compressFrames(
        _ input: UnsafePointer<Float>,
        from inputFrames: Int,
        to outputFrames: Int
    ) -> UnsafeMutablePointer<Float> {
        let channelCount = Int(channels)
        let needed = outputFrames * channelCount
        if resampleScratchCapacity < needed || resampleScratch == nil {
            resampleScratch?.deallocate()
            resampleScratch = UnsafeMutablePointer<Float>.allocate(capacity: needed)
            resampleScratchCapacity = needed
        }
        let output = resampleScratch!
        let step = Double(inputFrames - 1) / Double(max(outputFrames - 1, 1))
        for frame in 0..<outputFrames {
            let position = Double(frame) * step
            let lower = min(Int(position), inputFrames - 1)
            let upper = min(lower + 1, inputFrames - 1)
            let fraction = Float(position - Double(lower))
            for channel in 0..<channelCount {
                let a = input[lower * channelCount + channel]
                let b = input[upper * channelCount + channel]
                output[frame * channelCount + channel] = a + (b - a) * fraction
            }
        }
        return output
    }

    func stop(resetCounters: Bool = false) {
        queue.sync {
            stopOutputUnitLocked()
            converter = nil
            sourceFormat = nil
            pcmFormat = nil
            ring?.clear()
            ring = nil
            resetTimelineLocked(resetCounters: resetCounters)
            onQueueLead?(0)
            onStatus?("Остановлен")
        }
    }

    fileprivate func render(frames requestedFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)

        // Always initialize the device buffer. If network/decode is late, silence
        // is preferable to replaying stale PCM one second later.
        for index in buffers.indices {
            if let data = buffers[index].mData {
                memset(data, 0, Int(buffers[index].mDataByteSize))
            }
        }

        guard let ring, buffers.count == 1,
              let output = buffers[0].mData else {
            return noErr
        }

        _ = ring.readInterleavedRealtime(
            into: output.assumingMemoryBound(to: Float.self),
            frames: Int(requestedFrames)
        )
        return noErr
    }

    private func createOutputUnitLocked(pcmFormat: AVAudioFormat) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AirPlayLowLatencyAudioError.outputComponentUnavailable
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            throw AirPlayLowLatencyAudioError.outputUnit(status)
        }

        var stream = pcmFormat.streamDescription.pointee
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
            throw AirPlayLowLatencyAudioError.outputUnit(status)
        }

        var callback = AURenderCallbackStruct(
            inputProc: mirrorLabAirPlayAudioRenderCallback,
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
            throw AirPlayLowLatencyAudioError.outputUnit(status)
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AirPlayLowLatencyAudioError.outputUnit(status)
        }

        outputUnit = unit
        outputStarted = false

        AirPlayAudioOutputProbe.requestSmallIOBuffer(on: unit, frames: 256)
        let info = AirPlayAudioOutputProbe.info(for: unit)
        outputInfo = info
        onOutputInfo?(info)
        if let info {
            diagnostics.addEvent(
                "AirPlay audio output: \(info.summary), IO buffer \(info.bufferFrames) frames.",
                level: info.isHighLatencyTransport ? .warning : .info
            )
            if info.isHighLatencyTransport {
                diagnostics.addEvent(
                    "Звук идёт через \(info.transport): это устройство само добавляет заметную задержку. Для игр выбери встроенные динамики или проводные наушники.",
                    level: .warning
                )
            }
        }
    }

    private func stopOutputUnitLocked() {
        guard let outputUnit else { return }
        if outputStarted {
            AudioOutputUnitStop(outputUnit)
        }
        AudioUnitUninitialize(outputUnit)
        AudioComponentInstanceDispose(outputUnit)
        self.outputUnit = nil
        outputStarted = false
    }

    private func resetTimelineLocked(resetCounters: Bool) {
        expectedSequence = nil
        pendingPackets.removeAll(keepingCapacity: true)
        resendRequestedSequences.removeAll(keepingCapacity: true)
        redundancyLogged = false
        recoveryLogged = false
        firstPacketLogged = false
        decodedPackets = 0
        converterFailures = 0
        floorWindow.reset()
        draining = false
        observedUnderflowEvents = 0
        packetsSinceUnderflow = 0
        if resetCounters {
            sequenceGaps = 0
            redundantPackets = 0
            drainedFrames = 0
            silencePackets = 0
            adaptiveMargin = 0
            onSequenceGap?(0)
            onRedundantPackets?(0)
        }
    }
}

private let mirrorLabAirPlayAudioRenderCallback: AURenderCallback = {
    refCon,
    _,
    _,
    _,
    numberFrames,
    ioData in
    let player = Unmanaged<AirPlayLowLatencyAudioPlayer>
        .fromOpaque(refCon)
        .takeUnretainedValue()
    return player.render(frames: numberFrames, ioData: ioData)
}

/// Fixed-size sliding minimum over the last `capacity` pushed values (monotonic deque).
private struct PacketWindowMinimum {
    private var values: [(index: Int, value: Int)] = []
    private var head = 0
    private var nextIndex = 0
    private var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    var isFull: Bool { count >= capacity }

    var minimum: Int? {
        head < values.count ? values[head].value : nil
    }

    mutating func push(_ value: Int) -> Int {
        while values.count > head, let last = values.last, last.value >= value {
            values.removeLast()
        }
        values.append((index: nextIndex, value: value))
        let oldest = nextIndex - capacity + 1
        while head < values.count - 1 && values[head].index < oldest {
            head += 1
        }
        if head > 512 {
            values.removeFirst(head)
            head = 0
        }
        nextIndex += 1
        count = min(count + 1, capacity)
        return values[head].value
    }

    mutating func reset() {
        values.removeAll(keepingCapacity: true)
        head = 0
        count = 0
    }
}

/// CoreAudio HAL queries for the device the DefaultOutput unit is actually using.
private enum AirPlayAudioOutputProbe {
    static func requestSmallIOBuffer(on unit: AudioUnit, frames: UInt32) {
        guard let device = currentDevice(of: unit) else { return }
        var requested = frames
        var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
        if getProperty(device, kAudioDevicePropertyBufferFrameSizeRange, kAudioObjectPropertyScopeGlobal, &range),
           range.mMaximum > 0 {
            requested = UInt32(min(max(Double(frames), range.mMinimum), range.mMaximum))
        }
        // Per-process IO size on macOS; failures (e.g. some Bluetooth devices) are harmless.
        _ = AudioUnitSetProperty(
            unit,
            kAudioDevicePropertyBufferFrameSize,
            kAudioUnitScope_Global,
            0,
            &requested,
            UInt32(MemoryLayout<UInt32>.size)
        )
    }

    static func info(for unit: AudioUnit) -> AirPlayAudioOutputInfo? {
        guard let device = currentDevice(of: unit) else { return nil }

        var transport: UInt32 = 0
        _ = getProperty(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport)
        var latency: UInt32 = 0
        _ = getProperty(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, &latency)
        var safety: UInt32 = 0
        _ = getProperty(device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, &safety)
        var buffer: UInt32 = 0
        _ = getProperty(device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, &buffer)
        var rate: Float64 = 0
        _ = getProperty(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate)
        let streamLatency = firstOutputStreamLatency(device)

        let effectiveRate = rate > 0 ? rate : 48_000
        let totalFrames = Double(latency) + Double(safety) + Double(buffer) + Double(streamLatency)
        let (label, highLatency) = describe(transport: transport)

        return AirPlayAudioOutputInfo(
            deviceName: name(of: device) ?? "Audio device \(device)",
            transport: label,
            isHighLatencyTransport: highLatency,
            reportedLatencyMS: totalFrames / effectiveRate * 1_000,
            bufferFrames: buffer,
            sampleRate: effectiveRate
        )
    }

    private static func describe(transport: UInt32) -> (String, Bool) {
        if transport == kAudioDeviceTransportTypeBuiltIn { return ("встроенный", false) }
        if transport == kAudioDeviceTransportTypeBluetooth { return ("Bluetooth", true) }
        if transport == kAudioDeviceTransportTypeBluetoothLE { return ("Bluetooth LE", true) }
        if transport == kAudioDeviceTransportTypeAirPlay { return ("AirPlay", true) }
        if transport == kAudioDeviceTransportTypeVirtual { return ("виртуальное устройство", true) }
        if transport == kAudioDeviceTransportTypeAggregate { return ("агрегатное устройство", true) }
        if transport == kAudioDeviceTransportTypeHDMI { return ("HDMI", false) }
        if transport == kAudioDeviceTransportTypeDisplayPort { return ("DisplayPort", false) }
        if transport == kAudioDeviceTransportTypeUSB { return ("USB", false) }
        if transport == kAudioDeviceTransportTypeThunderbolt { return ("Thunderbolt", false) }
        return ("другое", false)
    }

    private static func currentDevice(of unit: AudioUnit) -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            &size
        )
        guard status == noErr, device != 0 else { return nil }
        return device
    }

    private static func getProperty<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope,
        _ value: inout T
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr
        }
    }

    private static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func firstOutputStreamLatency(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return 0 }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        let status = streams.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr, let stream = streams.first else { return 0 }
        var latency: UInt32 = 0
        _ = getProperty(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, &latency)
        return latency
    }
}

/// Fixed-capacity interleaved Float32 frame ring.
/// NSLock is held only for small memcpy-like loops; if the producer briefly
/// contends with CoreAudio, the ring remains bounded and never accumulates stale
/// seconds of audio.
private final class InterleavedPCMFrameRing {
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
    private var fadeInPending = false
    private var prerollFrames = 0
    // Set while the sender reports silence: running dry then is expected and must
    // not count as a Wi-Fi underrun (it would needlessly grow the cushion).
    private var silenceActive = false

    init(capacityFrames: Int, channels: Int) {
        self.capacityFrames = max(capacityFrames, 1)
        self.channels = max(channels, 1)
        self.storage = [Float](repeating: 0, count: max(capacityFrames, 1) * max(channels, 1))
    }

    var availableFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return frameCount
    }

    var underflowSnapshot: (events: UInt64, frames: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (underflowEvents, underflowFrames)
    }

    func setPrerollFrames(_ frames: Int) {
        lock.lock()
        prerollFrames = max(frames, 0)
        lock.unlock()
    }

    func noteSilence() {
        lock.lock()
        silenceActive = true
        lock.unlock()
    }

    func writeInterleaved(_ input: UnsafePointer<Float>, frames: Int, gain outputGain: Float = 1) {
        guard frames > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        silenceActive = false

        var sourceFrame = 0
        var framesToWrite = frames
        if framesToWrite > capacityFrames {
            sourceFrame = framesToWrite - capacityFrames
            framesToWrite = capacityFrames
            readFrame = 0
            writeFrame = 0
            frameCount = 0
        }

        let overflow = max(0, frameCount + framesToWrite - capacityFrames)
        if overflow > 0 {
            readFrame = (readFrame + overflow) % capacityFrames
            frameCount -= overflow
        }

        let fadeFrames = fadeInPending ? min(framesToWrite, 96) : 0
        for frame in 0..<framesToWrite {
            let dstFrame = (writeFrame + frame) % capacityFrames
            let srcFrame = sourceFrame + frame
            let dstBase = dstFrame * channels
            let srcBase = srcFrame * channels
            let fadeGain: Float = fadeFrames > 0 && frame < fadeFrames
                ? Float(frame + 1) / Float(fadeFrames)
                : 1
            let gain = fadeGain * outputGain
            for channel in 0..<channels {
                storage[dstBase + channel] = input[srcBase + channel] * gain
            }
        }
        if fadeFrames > 0 { fadeInPending = false }
        writeFrame = (writeFrame + framesToWrite) % capacityFrames
        frameCount += framesToWrite
    }

    @discardableResult
    func readInterleavedRealtime(
        into output: UnsafeMutablePointer<Float>,
        frames: Int
    ) -> Int {
        guard frames > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        // After a true underrun (or a sender silence), do not resume on the very next
        // tiny packet. Hold silence until the adaptive preroll is rebuilt, then
        // continue as a contiguous stream.
        if rebuffering {
            guard frameCount >= max(prerollFrames, frames) else { return 0 }
            rebuffering = false
        }

        guard frameCount >= frames else {
            if !silenceActive {
                underflowEvents &+= 1
                underflowFrames &+= UInt64(max(frames - frameCount, 0))
            }
            // Play out the last partial chunk with a fade instead of dropping it.
            let tail = frameCount
            for frame in 0..<tail {
                let srcFrame = (readFrame + frame) % capacityFrames
                let srcBase = srcFrame * channels
                let dstBase = frame * channels
                let gain = Float(tail - frame) / Float(max(tail, 1))
                for channel in 0..<channels {
                    output[dstBase + channel] = storage[srcBase + channel] * gain
                }
            }
            readFrame = (readFrame + tail) % capacityFrames
            frameCount = 0
            rebuffering = true
            fadeInPending = true
            return tail
        }

        for frame in 0..<frames {
            let srcFrame = (readFrame + frame) % capacityFrames
            let srcBase = srcFrame * channels
            let dstBase = frame * channels
            for channel in 0..<channels {
                output[dstBase + channel] = storage[srcBase + channel]
            }
        }
        readFrame = (readFrame + frames) % capacityFrames
        frameCount -= frames
        return frames
    }

    func writeConcealment(frames: Int) {
        guard frames > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        let framesToWrite = min(frames, capacityFrames)
        let overflow = max(0, frameCount + framesToWrite - capacityFrames)
        if overflow > 0 {
            readFrame = (readFrame + overflow) % capacityFrames
            frameCount -= overflow
        }

        let fadeFrames = min(framesToWrite, 96)
        var startSamples = [Float](repeating: 0, count: channels)
        if frameCount > 0 {
            let previousFrame = (writeFrame - 1 + capacityFrames) % capacityFrames
            let base = previousFrame * channels
            for channel in 0..<channels { startSamples[channel] = storage[base + channel] }
        }

        for frame in 0..<framesToWrite {
            let dstFrame = (writeFrame + frame) % capacityFrames
            let dstBase = dstFrame * channels
            let gain = fadeFrames > 0 && frame < fadeFrames
                ? Float(fadeFrames - frame - 1) / Float(fadeFrames)
                : 0
            for channel in 0..<channels {
                storage[dstBase + channel] = startSamples[channel] * gain
            }
        }
        writeFrame = (writeFrame + framesToWrite) % capacityFrames
        frameCount += framesToWrite
        fadeInPending = true
    }

    func discardOldest(frames: Int) {
        guard frames > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let count = min(frames, frameCount)
        readFrame = (readFrame + count) % capacityFrames
        frameCount -= count
    }

    func clear() {
        lock.lock()
        readFrame = 0
        writeFrame = 0
        frameCount = 0
        underflowEvents = 0
        underflowFrames = 0
        rebuffering = true
        fadeInPending = false
        silenceActive = false
        lock.unlock()
    }
}
