import Combine
import CoreMedia
import Foundation

enum DiagnosticLevel: String, Codable {
    case info
    case warning
    case error
}

struct DiagnosticEvent: Identifiable, Codable {
    let id: UUID
    let date: Date
    let level: DiagnosticLevel
    let message: String

    init(message: String, level: DiagnosticLevel) {
        self.id = UUID()
        self.date = Date()
        self.level = level
        self.message = message
    }
}

struct DiagnosticsSnapshot: Codable {
    var receivedFPS: Double = 0
    var renderedFPS: Double = 0
    var upstreamReportedFPS: Double?
    var externalRenderedFPS: Double?
    var videoPTSAgeMS: Double?
    var audioVideoDeltaMS: Double?
    var sourceFrameJitterMS: Double?
    var presentationTargetLatencyMS: Double?
    var presentationLatenessMS: Double?
    var presentationQueueDepth: UInt64 = 0
    var presentationDroppedFrames: UInt64 = 0
    var receivedFrames: UInt64 = 0
    var renderedFrames: UInt64 = 0
    var captureDroppedFrames: UInt64 = 0
    var rendererSkippedFrames: UInt64 = 0
    var externalQueueDrops: UInt64 = 0
    var audioBuffers: UInt64 = 0
    var audioDroppedBuffers: UInt64 = 0
    var audioUnderflowEvents: UInt64 = 0
    var audioUnderflowFrames: UInt64 = 0
    var audioOverflowTrimEvents: UInt64 = 0
    var audioTrimmedFrames: UInt64 = 0
    var audioLateRecoveredPackets: UInt64 = 0
    var audioConcealedFrames: UInt64 = 0
    var audioResendRequests: UInt64 = 0
    var audioRetransmittedPackets: UInt64 = 0
    var audioConverterFailures: UInt64 = 0
}

final class DiagnosticsStore: ObservableObject {
    @Published private(set) var snapshot = DiagnosticsSnapshot()
    @Published private(set) var events: [DiagnosticEvent] = []

    private struct MutableState {
        var receivedTimes: [TimeInterval] = []
        var renderedTimes: [TimeInterval] = []
        var upstreamReportedFPS: Double?
        var externalRenderedFPS: Double?
        var videoPTSAgeMS: Double?
        var audioVideoDeltaMS: Double?
        var sourceFrameJitterMS: Double?
        var presentationTargetLatencyMS: Double?
        var presentationLatenessMS: Double?
        var presentationQueueDepth: UInt64 = 0
        var presentationDroppedFrames: UInt64 = 0
        var sourcePTSWindow: [Double] = []
        var sourceJitterSamplesMS: [Double] = []
        var lastSourcePTSSeconds: Double?
        var lastSourceArrivalHost: TimeInterval?
        var lastVideoPTS: CMTime = .invalid
        var lastAudioPTS: CMTime = .invalid
        var receivedFrames: UInt64 = 0
        var renderedFrames: UInt64 = 0
        var captureDroppedFrames: UInt64 = 0
        var rendererSkippedFrames: UInt64 = 0
        var externalQueueDrops: UInt64 = 0
        var audioBuffers: UInt64 = 0
        var audioDroppedBuffers: UInt64 = 0
        var audioUnderflowEvents: UInt64 = 0
        var audioUnderflowFrames: UInt64 = 0
        var audioOverflowTrimEvents: UInt64 = 0
        var audioTrimmedFrames: UInt64 = 0
        var audioLateRecoveredPackets: UInt64 = 0
        var audioConcealedFrames: UInt64 = 0
        var audioResendRequests: UInt64 = 0
        var audioRetransmittedPackets: UInt64 = 0
        var audioConverterFailures: UInt64 = 0
    }

    private let lock = NSLock()
    private var state = MutableState()
    private let publishQueue = DispatchQueue(label: "MirrorLab.Diagnostics.Publish", qos: .utility)
    private var timer: DispatchSourceTimer?

    init() {
        let timer = DispatchSource.makeTimerSource(queue: publishQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(250),
            repeating: .milliseconds(250),
            leeway: .milliseconds(40)
        )
        timer.setEventHandler { [weak self] in
            self?.publishSnapshot()
        }
        self.timer = timer
        timer.resume()
    }

    deinit {
        timer?.cancel()
    }

    func resetCounters() {
        lock.lock()
        state = MutableState()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.snapshot = DiagnosticsSnapshot()
            self?.events = []
        }
    }

    func recordVideoReceived(pts: CMTime) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        state.receivedFrames += 1
        state.receivedTimes.append(now)
        state.lastVideoPTS = pts

        if pts.isNumeric {
            let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
            let age = CMTimeGetSeconds(CMTimeSubtract(hostTime, pts)) * 1_000
            state.videoPTSAgeMS = age.isFinite && abs(age) < 10_000 ? age : nil
        }
        updateAVDeltaLocked()
        lock.unlock()
    }

    /// Record the cadence stamped by the AirPlay sender and compare it with
    /// local TCP arrival cadence. The former is the real source FPS; the latter
    /// exposes burstiness/jitter that a simple "frames received this second"
    /// counter hides.
    func recordAirPlaySourceFrame(pts: CMTime, arrivalHostTime: TimeInterval) {
        guard pts.isNumeric else { return }
        let sourceSeconds = CMTimeGetSeconds(pts)
        guard sourceSeconds.isFinite else { return }

        lock.lock()

        if let previousPTS = state.lastSourcePTSSeconds,
           sourceSeconds + 0.5 < previousPTS {
            state.sourcePTSWindow.removeAll(keepingCapacity: true)
            state.sourceJitterSamplesMS.removeAll(keepingCapacity: true)
            state.lastSourcePTSSeconds = nil
            state.lastSourceArrivalHost = nil
        }

        if let previousPTS = state.lastSourcePTSSeconds,
           let previousArrival = state.lastSourceArrivalHost {
            let sourceDelta = sourceSeconds - previousPTS
            let arrivalDelta = arrivalHostTime - previousArrival
            if sourceDelta > 0.001, sourceDelta < 0.250,
               arrivalDelta >= 0, arrivalDelta < 0.500 {
                let jitterMS = abs(arrivalDelta - sourceDelta) * 1_000
                state.sourceJitterSamplesMS.append(jitterMS)
                if state.sourceJitterSamplesMS.count > 240 {
                    state.sourceJitterSamplesMS.removeFirst(state.sourceJitterSamplesMS.count - 240)
                }
            }
        }

        state.sourcePTSWindow.append(sourceSeconds)
        let cutoff = sourceSeconds - 1.0
        state.sourcePTSWindow.removeAll { $0 < cutoff }
        if state.sourcePTSWindow.count >= 2,
           let first = state.sourcePTSWindow.first,
           let last = state.sourcePTSWindow.last,
           last > first {
            state.upstreamReportedFPS = Double(state.sourcePTSWindow.count - 1) / (last - first)
        }

        state.lastSourcePTSSeconds = sourceSeconds
        state.lastSourceArrivalHost = arrivalHostTime
        lock.unlock()
    }

    func setPresentationState(
        queueDepth: Int,
        targetLatencyMS: Double,
        droppedFrames: UInt64,
        latenessMS: Double?
    ) {
        lock.lock()
        state.presentationQueueDepth = UInt64(max(queueDepth, 0))
        state.presentationTargetLatencyMS = targetLatencyMS
        state.presentationDroppedFrames = droppedFrames
        state.presentationLatenessMS = latenessMS
        lock.unlock()
    }

    func recordVideoRendered(skipped: UInt64 = 0) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        state.renderedFrames += 1
        state.rendererSkippedFrames += skipped
        state.renderedTimes.append(now)
        lock.unlock()
    }

    func recordCaptureDrop() {
        lock.lock()
        state.captureDroppedFrames += 1
        lock.unlock()
    }

    func recordAudio(pts: CMTime) {
        lock.lock()
        state.audioBuffers += 1
        state.lastAudioPTS = pts
        updateAVDeltaLocked()
        lock.unlock()
    }

    func recordAudioDrop() {
        lock.lock()
        state.audioDroppedBuffers += 1
        lock.unlock()
    }

    func recordAirPlayAudioConverterFailure() {
        lock.lock()
        state.audioConverterFailures += 1
        state.audioDroppedBuffers += 1
        lock.unlock()
    }

    func recordAirPlayAudioOverflowTrim(frames: Int) {
        guard frames > 0 else { return }
        lock.lock()
        state.audioOverflowTrimEvents += 1
        state.audioTrimmedFrames += UInt64(frames)
        state.audioDroppedBuffers += 1
        lock.unlock()
    }

    func setAirPlayAudioUnderflow(events: UInt64, frames: UInt64) {
        lock.lock()
        state.audioUnderflowEvents = events
        state.audioUnderflowFrames = frames
        lock.unlock()
    }

    func recordAirPlayAudioLateRecovery() {
        lock.lock()
        state.audioLateRecoveredPackets += 1
        lock.unlock()
    }

    func recordAirPlayAudioConcealment(frames: Int) {
        guard frames > 0 else { return }
        lock.lock()
        state.audioConcealedFrames += UInt64(frames)
        lock.unlock()
    }

    func recordAirPlayAudioResendRequest() {
        lock.lock()
        state.audioResendRequests += 1
        lock.unlock()
    }

    func recordAirPlayAudioRetransmittedPacket() {
        lock.lock()
        state.audioRetransmittedPackets += 1
        lock.unlock()
    }

    func setUpstreamReportedFPS(_ fps: Double?) {
        lock.lock()
        state.upstreamReportedFPS = fps
        lock.unlock()
    }

    func setExternalRenderedFPS(_ fps: Double?) {
        lock.lock()
        state.externalRenderedFPS = fps
        lock.unlock()
    }

    func setExternalQueueDrops(_ drops: UInt64) {
        lock.lock()
        state.externalQueueDrops = drops
        lock.unlock()
    }

    func addEvent(_ message: String, level: DiagnosticLevel = .info) {
        let event = DiagnosticEvent(message: message, level: level)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.events.append(event)
            if self.events.count > 500 {
                self.events.removeFirst(self.events.count - 500)
            }
        }
    }

    func makeReportData(extra: [String: Any]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        let snapshotData = try encoder.encode(currentSnapshot())
        let eventsData = try encoder.encode(currentEvents())
        let snapshotObject = try JSONSerialization.jsonObject(with: snapshotData)
        let eventsObject = try JSONSerialization.jsonObject(with: eventsData)

        let report: [String: Any] = [
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "host": [
                "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
                "processor_count": ProcessInfo.processInfo.processorCount
            ],
            "metrics": snapshotObject,
            "events": eventsObject,
            "session": extra
        ]
        return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func currentSnapshot() -> DiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshotLocked(now: ProcessInfo.processInfo.systemUptime, pruning: false)
    }

    private func currentEvents() -> [DiagnosticEvent] {
        if Thread.isMainThread { return events }
        return DispatchQueue.main.sync { self.events }
    }

    private func updateAVDeltaLocked() {
        guard state.lastVideoPTS.isNumeric, state.lastAudioPTS.isNumeric else {
            state.audioVideoDeltaMS = nil
            return
        }
        let delta = CMTimeGetSeconds(CMTimeSubtract(state.lastAudioPTS, state.lastVideoPTS)) * 1_000
        state.audioVideoDeltaMS = delta.isFinite && abs(delta) < 10_000 ? delta : nil
    }

    private func publishSnapshot() {
        let next: DiagnosticsSnapshot
        lock.lock()
        next = makeSnapshotLocked(now: ProcessInfo.processInfo.systemUptime, pruning: true)
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.snapshot = next
        }
    }

    private func makeSnapshotLocked(now: TimeInterval, pruning: Bool) -> DiagnosticsSnapshot {
        if pruning {
            state.receivedTimes.removeAll { $0 < now - 1.0 }
            state.renderedTimes.removeAll { $0 < now - 1.0 }
        }
        if !state.sourceJitterSamplesMS.isEmpty {
            let sorted = state.sourceJitterSamplesMS.sorted()
            let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
            state.sourceFrameJitterMS = sorted[index]
        }
        return DiagnosticsSnapshot(
            receivedFPS: Double(state.receivedTimes.filter { $0 >= now - 1.0 }.count),
            renderedFPS: Double(state.renderedTimes.filter { $0 >= now - 1.0 }.count),
            upstreamReportedFPS: state.upstreamReportedFPS,
            externalRenderedFPS: state.externalRenderedFPS,
            videoPTSAgeMS: state.videoPTSAgeMS,
            audioVideoDeltaMS: state.audioVideoDeltaMS,
            sourceFrameJitterMS: state.sourceFrameJitterMS,
            presentationTargetLatencyMS: state.presentationTargetLatencyMS,
            presentationLatenessMS: state.presentationLatenessMS,
            presentationQueueDepth: state.presentationQueueDepth,
            presentationDroppedFrames: state.presentationDroppedFrames,
            receivedFrames: state.receivedFrames,
            renderedFrames: state.renderedFrames,
            captureDroppedFrames: state.captureDroppedFrames,
            rendererSkippedFrames: state.rendererSkippedFrames,
            externalQueueDrops: state.externalQueueDrops,
            audioBuffers: state.audioBuffers,
            audioDroppedBuffers: state.audioDroppedBuffers,
            audioUnderflowEvents: state.audioUnderflowEvents,
            audioUnderflowFrames: state.audioUnderflowFrames,
            audioOverflowTrimEvents: state.audioOverflowTrimEvents,
            audioTrimmedFrames: state.audioTrimmedFrames,
            audioLateRecoveredPackets: state.audioLateRecoveredPackets,
            audioConcealedFrames: state.audioConcealedFrames,
            audioResendRequests: state.audioResendRequests,
            audioRetransmittedPackets: state.audioRetransmittedPackets,
            audioConverterFailures: state.audioConverterFailures
        )
    }
}
