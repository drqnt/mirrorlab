import Combine
import CoreMedia
import CryptoKit
import Foundation
import Network
import Security

// Native AirPlay receiver owned by MirrorLab. FairPlay is handled by the embedded
// provider; decrypted H.264/HEVC is decoded by VideoToolbox and rendered by Metal.


enum AirPlayVideoQuality: String, CaseIterable, Identifiable {
    case hd720 = "720p"
    case fullHD = "Full HD"
    case original = "Original"

    var id: String { rawValue }

    var requestedWidth: Int {
        switch self {
        case .hd720: return 1280
        case .fullHD: return 1920
        // Before initial SETUP tells us the source model, use a modest >1080p
        // bootstrap display so modern senders can negotiate HEVC without forcing 4K.
        case .original: return 2560
        }
    }

    var requestedHeight: Int {
        switch self {
        case .hd720: return 720
        case .fullHD: return 1080
        case .original: return 1440
        }
    }

    var prefersHEVC: Bool { self == .original }

    var codecPolicyLabel: String {
        prefersHEVC ? "HEVC preferred • H.264 fallback" : "H.264"
    }
}

enum AirPlayFrameRate: Int, CaseIterable, Identifiable {
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }
    var label: String { "\(rawValue) FPS" }
}

enum AirPlayPhase: String {
    case idle = "Остановлен"
    case starting = "Запуск…"
    case advertising = "Виден в Повторе экрана"
    case handshaking = "AirPlay handshake"
    case waitingForMedia = "FairPlay пройден / media setup"
    case receivingMedia = "Media transport подключён"
    case failed = "Ошибка"
}

final class AirPlayController: NSObject, ObservableObject {
    @Published private(set) var receiverName: String
    @Published var videoQuality: AirPlayVideoQuality = .fullHD {
        didSet {
            if oldValue != videoQuality { scheduleSettingsRestart() }
        }
    }
    @Published var preferredFrameRate: AirPlayFrameRate = .fps60 {
        didSet {
            if oldValue != preferredFrameRate { scheduleSettingsRestart() }
        }
    }
    /// Wi-Fi playout buffer policy. Purely receiver-side: changing it never restarts
    /// the AirPlay receiver or interrupts the current mirroring session.
    @Published var bufferMode: AirPlayBufferMode = AirPlayController.loadSavedBufferMode() {
        didSet {
            guard oldValue != bufferMode else { return }
            UserDefaults.standard.set(bufferMode.rawValue, forKey: Self.bufferModeDefaultsKey)
            presentationStore.setBufferMode(bufferMode)
            audioPlayer.setLatencyMode(bufferMode)
            diagnostics.addEvent("AirPlay буфер Wi-Fi: \(bufferMode.label)")
        }
    }
    @Published private(set) var phase: AirPlayPhase = .idle
    @Published private(set) var protocolLines: [String] = []
    @Published private(set) var connectedPeer = "—"
    @Published private(set) var lastRequest = "—"
    @Published private(set) var listeningPort: UInt16 = 0
    @Published private(set) var mirrorDataPort: UInt16 = 0
    @Published private(set) var mirrorBytesReceived: UInt64 = 0
    @Published private(set) var mirrorVideoPackets: UInt64 = 0
    @Published private(set) var mirrorCodecPackets: UInt64 = 0
    @Published private(set) var mirrorHeartbeatPackets: UInt64 = 0
    @Published private(set) var mirrorMalformedPackets: UInt64 = 0
    @Published private(set) var mirrorCodecSummary = "—"
    @Published private(set) var mirrorFirstVideoPrefix = "—"

    @Published private(set) var audioDataPort: UInt16 = 0
    @Published private(set) var audioControlPort: UInt16 = 0
    @Published private(set) var audioPacketsReceived: UInt64 = 0
    @Published private(set) var audioBytesReceived: UInt64 = 0
    @Published private(set) var audioDecryptedPackets: UInt64 = 0
    @Published private(set) var audioDecryptFailures: UInt64 = 0
    @Published private(set) var audioPlaybackStatus = "—"
    @Published private(set) var audioFormatSummary = "—"
    @Published private(set) var audioQueueLeadMS: Double = 0
    @Published private(set) var audioRTPSequenceGaps: UInt64 = 0
    @Published private(set) var audioRTPRedundantPackets: UInt64 = 0
    /// Mac output device MirrorLab plays AirPlay audio through, with its own latency.
    @Published private(set) var audioOutputSummary = "—"
    /// Non-nil when that device itself adds a lot of delay (Bluetooth, AirPlay, …).
    @Published private(set) var audioOutputWarning: String?

    @Published private(set) var streamConnectionID = "—"
    @Published private(set) var setupCryptoSummary = "—"
    @Published private(set) var fairPlayKeyMessageHex = "—"
    @Published private(set) var fairPlayBackend = "PlayFair provider: загрузка…"
    @Published private(set) var sessionKeyStatus = "—"
    @Published private(set) var videoCryptoStatus = "—"
    @Published private(set) var videoDecryptedPackets: UInt64 = 0
    @Published private(set) var videoDecryptFailures: UInt64 = 0
    @Published private(set) var videoDecodedFrames: UInt64 = 0
    @Published private(set) var hasLiveVideo = false
    @Published private(set) var feedbackHeartbeatCount: UInt64 = 0
    @Published private(set) var sourceModelIdentifier = "—"
    @Published private(set) var sourceNativeResolution = "—"

    /// Fired only for a final AirPlay session TEARDOWN, never for the temporary
    /// stream-110 TEARDOWN used during rotation/encoder reconfiguration.
    var onFinalSessionEnded: (() -> Void)?

    private let diagnostics: DiagnosticsStore
    private let presentationStore: AirPlayPresentationStore
    private let fairPlay = EmbeddedFairPlayProvider()
    private let videoDecoder: AirPlayVideoDecoder
    private let audioPlayer: AirPlayLowLatencyAudioPlayer
    private var sessionAudioKey: Data?
    private var sessionAudioIV: Data?
    private var activeStreamConnectionID: UInt64?
    // AES-CTR state is continuous for a mirror stream. AirPlay may retransmit
    // SETUP type=110, so never reinitialize the counter for the same stream ID
    // after encrypted video has already started.
    private var preparedVideoStreamID: UInt64?
    private var videoDecodeSequence: Int64 = 0
    private var videoTimestampOriginNanoseconds: UInt64?
    private let identity: AirPlayIdentity
    // Keep the RTSP/control socket serialized, but do not run realtime audio work
    // on the same CPU lane as mirror TCP parsing/AES-CTR. Audio decrypt/dispatch has
    // its own high-priority lane, AAC decode has another one inside audioPlayer,
    // VideoToolbox has its own decode lane, and Metal uses a dedicated render run loop.
    private let networkQueue = DispatchQueue(label: "MirrorLab.NativeAirPlay.ControlVideo", qos: .userInteractive)
    private let audioTransportQueue = DispatchQueue(label: "MirrorLab.NativeAirPlay.AudioTransport", qos: .userInteractive)
    private let telemetryQueue = DispatchQueue(label: "MirrorLab.NativeAirPlay.Telemetry", qos: .userInitiated)

    private struct HotTelemetry {
        var mirrorBytesReceived: UInt64 = 0
        var mirrorVideoPackets: UInt64 = 0
        var audioPacketsReceived: UInt64 = 0
        var audioBytesReceived: UInt64 = 0
        var audioDecryptedPackets: UInt64 = 0
        var audioDecryptFailures: UInt64 = 0
        var audioQueueLeadMS: Double = 0
        var audioRTPSequenceGaps: UInt64 = 0
        var audioRTPRedundantPackets: UInt64 = 0
        var videoDecryptedPackets: UInt64 = 0
        var videoDecryptFailures: UInt64 = 0
        var videoDecodedFrames: UInt64 = 0
        var hasLiveVideo = false

        // Lightweight 60-FPS cadence telemetry. These counters stay bounded and
        // let reports distinguish Wi-Fi/TCP arrival stalls from decoder stalls.
        var lastMirrorReceiveHostTime: TimeInterval = 0
        var mirrorReceiveCallbacks: UInt64 = 0
        var mirrorReceiveMaxChunkBytes: UInt64 = 0
        var mirrorReceiveMaxGapMS: Double = 0
        var mirrorReceiveGapsOver20MS: UInt64 = 0
        var mirrorReceiveGapsOver50MS: UInt64 = 0
        var mirrorReceiveGapsOver100MS: UInt64 = 0

        var lastVideoPacketArrivalHostTime: TimeInterval = 0
        var videoPacketMaxGapMS: Double = 0
        var videoPacketGapsOver25MS: UInt64 = 0
        var videoPacketGapsOver50MS: UInt64 = 0
        var videoPacketGapsOver100MS: UInt64 = 0

        var lastDecodedFrameHostTime: TimeInterval = 0
        var decodedFrameMaxGapMS: Double = 0
        var decodedFrameGapsOver25MS: UInt64 = 0
        var decodedFrameGapsOver50MS: UInt64 = 0
        var decodedFrameGapsOver100MS: UInt64 = 0

        // Sender-clock diagnostics (RTP sync packets vs. mirror video timestamps).
        var audioSyncPackets: UInt64 = 0
        var audioSenderLatencyMS: Double?
        var audioVideoArrivalSkewMS: Double?
    }

    private static let bufferModeDefaultsKey = "MirrorLab.AirPlay.BufferMode"

    private static func loadSavedBufferMode() -> AirPlayBufferMode {
        guard let raw = UserDefaults.standard.string(forKey: bufferModeDefaultsKey),
              let mode = AirPlayBufferMode(rawValue: raw) else {
            return .balanced
        }
        return mode
    }

    private let telemetryLock = NSLock()
    private var hotTelemetry = HotTelemetry()
    private var telemetryTimer: DispatchSourceTimer?
    private var settingsRestartWorkItem: DispatchWorkItem?
    private var automaticReceiverEnabled = false

    // Exactly one AirPlay sender owns the media pipeline at a time. A second
    // iPhone/iPad may begin FairPlay while the previous sender is still tearing
    // down. `sessionGeneration` makes late packets/TEARDOWNs from the old sender
    // harmless instead of letting them reset the new decoder/UI state.
    private var sessionGeneration: UInt64 = 0
    private var activeControlConnectionID: UUID?
    private var activeSessionPeer = "—"

    private var listener: NWListener?
    private var airPlayService: NetService?
    private var raopService: NetService?
    private var connections: [UUID: NWConnection] = [:]
    private var receiveBuffers: [UUID: Data] = [:]
    private var transientPairingKeys: [UUID: Data] = [:]
    private var fairPlayKeyMessages: [UUID: Data] = [:]
    private var initialSetupPlists: [UUID: [String: Any]] = [:]
    // Filled from the sender's initial SETUP metadata. A second GET /info normally
    // follows that SETUP, so Original can answer with a model-specific native size.
    private var activeSourceModelIdentifier: String?

    private final class MirrorReceiveState {
        var buffer = Data()
    }

    private var mirrorListener: NWListener?
    private var mirrorConnections: [UUID: NWConnection] = [:]
    // Reference-backed state avoids Data copy-on-write every time Network.framework
    // returns another TCP chunk. This is hot-path work at 1080p60 / high bitrate.
    private var mirrorReceiveStates: [UUID: MirrorReceiveState] = [:]
    private var mirrorConnectionGenerations: [UUID: UInt64] = [:]
    private var mirrorListenerGeneration: UInt64 = 0

    private var audioDataListener: NWListener?
    private var audioControlListener: NWListener?
    private var audioDataConnections: [UUID: NWConnection] = [:]
    private var audioControlConnections: [UUID: NWConnection] = [:]
    // Outbound UDP connection to the sender's controlPort. AirPlay uses it for
    // range-resend requests (PT 0xD5); retransmitted AAC-ELD comes back as PT 86.
    private var audioResendConnection: NWConnection?
    private var audioResendRequestSequence: UInt16 = 1
    private var audioResendGeneration: UInt64 = 0
    // The sender can repeat the same type-96 SETUP while UDP ports are coming up.
    // Keeping every copy creates an unnecessary reply storm, so only the newest
    // request is retained until both listeners are ready.
    private var pendingAudioSetupReply: (AirPlayRequest, NWConnection)?

    // Keep mirror parsing bounded: a bad framing assumption must never turn a
    // multi-megabyte AirPlay stream into millions of main-thread tasks or unbounded
    // memory growth. The cap must stay above the largest legal packet plus one receive
    // chunk; 0.3.48 allowed 32 MB payloads but flushed the buffer at 8 MB, and any flush
    // of video bytes desynchronises AES-CTR for the rest of the stream.
    private static let maximumMirrorPayloadBytes = 16 * 1024 * 1024
    private let maximumMirrorBufferedBytes = AirPlayController.maximumMirrorPayloadBytes + 512 * 1024
    private var mirrorDesyncReports: UInt64 = 0

    // Diagnostics only (networkQueue): where does audio latency come from? RTP sync
    // packets (PT 0x54) map audio RTP time to the sender clock; mirror video carries
    // the same sender clock. Comparing the arrival floors of both tells whether iOS
    // delivers audio later than the matching video.
    private struct AudioSyncPoint {
        let rtp: UInt32
        let ntpSeconds: Double
        let latencySamples: UInt32
    }
    private var audioSyncPoint: AudioSyncPoint?
    private var audioSyncSampleRate: Double = 44_100
    private var audioArrivalFloorNTPEpoch = ArrivalFloor(window: 3)
    private var audioArrivalFloorRaw = ArrivalFloor(window: 3)
    private var videoArrivalFloor = ArrivalFloor(window: 3)
    private var unusualMirrorVideoHeaders: UInt64 = 0

    // MirrorLab is intentionally a screen-mirroring receiver, not an AirPlay
    // direct-media/HLS player. The historical AppleTV-style mask also advertised
    // Video, VideoFairPlay, VideoHTTPLiveStreams, VideoPlayQueue and
    // AirPlayFromCloud. Apps such as YouTube can interpret those bits as permission
    // to stop mirroring and hand the receiver a URL/HLS playback session that
    // MirrorLab does not implement. Clear only the direct-video capabilities while
    // preserving Screen (bit 7), ScreenRotate, AirPlay audio and authentication.
    // Original may still add ScreenMultiCodec (bit 42) for HEVC mirroring.
    private let baseFeatureBits: UInt64 = 0x0000001E527FFFF7
    private let directVideoFeatureMask: UInt64 =
        (UInt64(1) << 0)  // Video
        | (UInt64(1) << 2)  // VideoFairPlay
        | (UInt64(1) << 4)  // VideoHTTPLiveStreams
        | (UInt64(1) << 33) // SupportsAirPlayVideoPlayQueue
        | (UInt64(1) << 34) // SupportsAirPlayFromCloud
    private let screenMultiCodecBit: UInt64 = 1 << 42

    private var mirrorOnlyFeatureBits: UInt64 {
        baseFeatureBits & ~directVideoFeatureMask
    }

    private var featureBits: UInt64 {
        videoQuality.prefersHEVC
            ? (mirrorOnlyFeatureBits | screenMultiCodecBit)
            : mirrorOnlyFeatureBits
    }

    private var featureTXTValue: String {
        let value = featureBits
        let low = UInt32(truncatingIfNeeded: value)
        let high = UInt32(truncatingIfNeeded: value >> 32)
        return String(format: "0x%08X,0x%X", low, high)
    }

    var videoModeSummary: String {
        if videoQuality == .original {
            if sourceNativeResolution != "—" {
                return "Original • \(sourceNativeResolution) • \(preferredFrameRate.rawValue) FPS • HEVC preferred"
            }
            return "Original • авто по разрешению устройства • \(preferredFrameRate.rawValue) FPS • HEVC preferred"
        }
        return "\(videoQuality.rawValue) • \(videoQuality.requestedWidth)×\(videoQuality.requestedHeight) • \(preferredFrameRate.rawValue) FPS • H.264"
    }

    private struct NativeDisplayProfile {
        let width: Int
        let height: Int
        let label: String
    }

    private var currentVideoRequest: (width: Int, height: Int, strategy: String) {
        switch videoQuality {
        case .hd720:
            return (1280, 720, "fixed-720p")
        case .fullHD:
            return (1920, 1080, "fixed-full-hd")
        case .original:
            if let model = activeSourceModelIdentifier,
               let profile = Self.nativeDisplayProfile(for: model) {
                return (profile.width, profile.height, "device-native:\(model)")
            }
            // First /info arrives before SETUP exposes the sender model.
            // 2560×1440 is only a negotiation bootstrap: it stays >1080p so
            // ScreenMultiCodec/HEVC remains available without forcing a 4K encode.
            return (2560, 1440, "bootstrap-awaiting-device-model")
        }
    }

    private static func nativeDisplayProfile(for model: String) -> NativeDisplayProfile? {
        switch model {
        // iPhone 12 / 13 families
        case "iPhone13,1", "iPhone14,4":
            return .init(width: 2340, height: 1080, label: "2340×1080")
        case "iPhone13,2", "iPhone13,3", "iPhone14,2", "iPhone14,5":
            return .init(width: 2532, height: 1170, label: "2532×1170")
        case "iPhone13,4", "iPhone14,3", "iPhone14,8":
            return .init(width: 2778, height: 1284, label: "2778×1284")
        case "iPhone14,6":
            return .init(width: 1334, height: 750, label: "1334×750")

        // iPhone 14 Pro / 15 families
        case "iPhone14,7":
            return .init(width: 2532, height: 1170, label: "2532×1170")
        case "iPhone15,2", "iPhone15,4", "iPhone16,1":
            return .init(width: 2556, height: 1179, label: "2556×1179")
        case "iPhone15,3", "iPhone15,5", "iPhone16,2":
            return .init(width: 2796, height: 1290, label: "2796×1290")

        // iPhone 16 / 17 families
        case "iPhone17,1", "iPhone18,1", "iPhone18,3":
            return .init(width: 2622, height: 1206, label: "2622×1206")
        case "iPhone17,2", "iPhone18,2":
            return .init(width: 2868, height: 1320, label: "2868×1320")
        case "iPhone17,3":
            return .init(width: 2556, height: 1179, label: "2556×1179")
        case "iPhone17,4":
            return .init(width: 2796, height: 1290, label: "2796×1290")
        case "iPhone17,5", "iPhone18,5":
            return .init(width: 2532, height: 1170, label: "2532×1170")
        case "iPhone18,4":
            return .init(width: 2736, height: 1260, label: "2736×1260")

        // iPad / iPad Air
        case "iPad6,11", "iPad6,12", "iPad7,5", "iPad7,6":
            return .init(width: 2048, height: 1536, label: "2048×1536")
        case "iPad11,3", "iPad11,4":
            return .init(width: 2224, height: 1668, label: "2224×1668")
        case "iPad7,11", "iPad7,12", "iPad11,6", "iPad11,7", "iPad12,1", "iPad12,2":
            return .init(width: 2160, height: 1620, label: "2160×1620")
        case "iPad13,18", "iPad13,19", "iPad15,7", "iPad15,8",
             "iPad13,1", "iPad13,2", "iPad13,16", "iPad13,17",
             "iPad14,8", "iPad14,9", "iPad15,3", "iPad15,4",
             "iPad16,8", "iPad16,9":
            return .init(width: 2360, height: 1640, label: "2360×1640")
        case "iPad14,10", "iPad14,11", "iPad15,5", "iPad15,6",
             "iPad16,10", "iPad16,11":
            return .init(width: 2732, height: 2048, label: "2732×2048")

        // iPad mini
        case "iPad11,1", "iPad11,2":
            return .init(width: 2048, height: 1536, label: "2048×1536")
        case "iPad14,1", "iPad14,2", "iPad16,1", "iPad16,2":
            return .init(width: 2266, height: 1488, label: "2266×1488")

        // iPad Pro 9.7 / 10.5 / 11 / 12.9 / 13
        case "iPad6,3", "iPad6,4":
            return .init(width: 2048, height: 1536, label: "2048×1536")
        case "iPad7,3", "iPad7,4":
            return .init(width: 2224, height: 1668, label: "2224×1668")
        case "iPad8,1", "iPad8,2", "iPad8,3", "iPad8,4",
             "iPad8,9", "iPad8,10",
             "iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7",
             "iPad14,3", "iPad14,4":
            return .init(width: 2388, height: 1668, label: "2388×1668")
        case "iPad16,3", "iPad16,4", "iPad17,1", "iPad17,2":
            return .init(width: 2420, height: 1668, label: "2420×1668")
        case "iPad6,7", "iPad6,8", "iPad7,1", "iPad7,2",
             "iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8",
             "iPad8,11", "iPad8,12",
             "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11",
             "iPad14,5", "iPad14,6":
            return .init(width: 2732, height: 2048, label: "2732×2048")
        case "iPad16,5", "iPad16,6", "iPad17,3", "iPad17,4":
            return .init(width: 2752, height: 2064, label: "2752×2064")

        default:
            return nil
        }
    }

    init(presentationStore: AirPlayPresentationStore, diagnostics: DiagnosticsStore) {
        let resolvedReceiverName = Self.makeDefaultReceiverName()
        self.receiverName = resolvedReceiverName
        self.identity = AirPlayIdentity.loadOrCreate(receiverName: resolvedReceiverName)
        self.presentationStore = presentationStore
        self.diagnostics = diagnostics
        self.videoDecoder = AirPlayVideoDecoder(presentationStore: presentationStore, diagnostics: diagnostics)
        self.audioPlayer = AirPlayLowLatencyAudioPlayer(diagnostics: diagnostics)
        super.init()
        self.presentationStore.setBufferMode(bufferMode)
        self.audioPlayer.setLatencyMode(bufferMode)
        self.videoDecoder.onDecodedFrame = { [weak self] generation in
            guard let self, generation == self.sessionGeneration else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.updateHotTelemetry { telemetry in
                telemetry.videoDecodedFrames &+= 1
                telemetry.hasLiveVideo = true
                if telemetry.lastDecodedFrameHostTime > 0 {
                    let gapMS = (now - telemetry.lastDecodedFrameHostTime) * 1_000
                    telemetry.decodedFrameMaxGapMS = max(telemetry.decodedFrameMaxGapMS, gapMS)
                    if gapMS > 25 { telemetry.decodedFrameGapsOver25MS &+= 1 }
                    if gapMS > 50 { telemetry.decodedFrameGapsOver50MS &+= 1 }
                    if gapMS > 100 { telemetry.decodedFrameGapsOver100MS &+= 1 }
                }
                telemetry.lastDecodedFrameHostTime = now
            }
        }
        self.audioPlayer.onOutputInfo = { [weak self] info in
            let summary = info?.summary ?? "—"
            var warning: String?
            if let info, info.isHighLatencyTransport {
                warning = "Звук идёт через \(info.transport) — это устройство само добавляет заметную задержку. Для игр лучше встроенные динамики или проводные наушники."
            }
            DispatchQueue.main.async {
                self?.audioOutputSummary = summary
                self?.audioOutputWarning = warning
            }
        }
        self.audioPlayer.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.audioPlaybackStatus = status }
        }
        self.audioPlayer.onQueueLead = { [weak self] leadMS in
            self?.updateHotTelemetry { $0.audioQueueLeadMS = leadMS }
        }
        self.audioPlayer.onSequenceGap = { [weak self] gaps in
            self?.updateHotTelemetry { $0.audioRTPSequenceGaps = gaps }
        }
        self.audioPlayer.onRedundantPackets = { [weak self] count in
            self?.updateHotTelemetry { $0.audioRTPRedundantPackets = count }
        }
        self.audioPlayer.onResendRequest = { [weak self] first, count in
            guard let self else { return }
            self.networkQueue.async { [weak self] in
                self?.sendAudioResendRequest(first: first, count: count)
            }
        }
        self.fairPlayBackend = fairPlay.versionDescription
        startTelemetryPublisher()
    }

    deinit {
        settingsRestartWorkItem?.cancel()
        telemetryTimer?.cancel()
        stop()
    }

    var isRunning: Bool {
        listener != nil
    }

    private static func makeDefaultReceiverName() -> String {
        let localized = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = ProcessInfo.processInfo.hostName
            .split(separator: ".")
            .first
            .map(String.init) ?? "Mac"
        let computerName = (localized?.isEmpty == false ? localized! : fallback)
        return "MirrorLab — \(computerName)"
    }

    var reportDictionary: [String: Any] {
        let hot = hotTelemetrySnapshot()
        let pacing = presentationStore.state()
        let audioLatency = audioPlayer.latencySnapshot()
        // Resolve optionals up front: keeps the large heterogeneous literal cheap to
        // type-check.
        let audioOutput = audioLatency.output
        let audioOutputDevice: String = audioOutput?.deviceName ?? "—"
        let audioOutputTransport: String = audioOutput?.transport ?? "—"
        let audioOutputLatencyMS: Double = audioOutput?.reportedLatencyMS ?? -1
        let audioOutputBufferFrames: UInt32 = audioOutput?.bufferFrames ?? 0
        let audioSenderLatencyMS: Double = hot.audioSenderLatencyMS ?? -1
        let audioVideoArrivalSkewMS: Double = hot.audioVideoArrivalSkewMS ?? -99_999
        return [
            "video_buffer_mode": pacing.bufferMode.rawValue,
            "video_playout_delay_ms": pacing.targetLatencyMS,
            "video_wifi_jitter_ms": pacing.jitterMS,
            "video_presentation_drops": pacing.droppedFrames,
            "video_late_frames": pacing.lateFrames,
            "video_timeline_resets": pacing.timelineResets,
            "audio_receiver_lead_ms": audioLatency.leadMS,
            "audio_receiver_floor_ms": audioLatency.floorMS,
            "audio_receiver_preroll_ms": audioLatency.prerollMS,
            "audio_adaptive_margin_ms": audioLatency.adaptiveMarginMS,
            "audio_drained_ms": audioLatency.drainedMS,
            "audio_silence_packets": audioLatency.silencePackets,
            "audio_underflow_events": audioLatency.underflowEvents,
            "audio_output_device": audioOutputDevice,
            "audio_output_transport": audioOutputTransport,
            "audio_output_latency_ms": audioOutputLatencyMS,
            "audio_output_io_buffer_frames": audioOutputBufferFrames,
            "audio_sync_packets": hot.audioSyncPackets,
            "audio_sender_latency_ms": audioSenderLatencyMS,
            "audio_video_arrival_skew_ms": audioVideoArrivalSkewMS,
            "backend": "native-airplay-core",
            "receiver_name": receiverName,
            "requested_video_quality": videoQuality.rawValue,
            "requested_video_width": currentVideoRequest.width,
            "requested_video_height": currentVideoRequest.height,
            "requested_video_fps": preferredFrameRate.rawValue,
            "requested_video_codec_policy": videoQuality.codecPolicyLabel,
            "requested_video_strategy": currentVideoRequest.strategy,
            "source_model_identifier": activeSourceModelIdentifier ?? "—",
            "phase": phase.rawValue,
            "connected_peer": connectedPeer,
            "last_request": lastRequest,
            "listen_port": listeningPort,
            "mirror_data_port": mirrorDataPort,
            "mirror_bytes_received": hot.mirrorBytesReceived,
            "mirror_video_packets": hot.mirrorVideoPackets,
            "mirror_codec_packets": mirrorCodecPackets,
            "mirror_heartbeat_packets": mirrorHeartbeatPackets,
            "mirror_malformed_packets": mirrorMalformedPackets,
            "mirror_codec_summary": mirrorCodecSummary,
            "mirror_first_video_prefix": mirrorFirstVideoPrefix,
            "audio_data_port": audioDataPort,
            "audio_control_port": audioControlPort,
            "audio_packets_received": hot.audioPacketsReceived,
            "audio_bytes_received": hot.audioBytesReceived,
            "audio_decrypted_packets": hot.audioDecryptedPackets,
            "audio_decrypt_failures": hot.audioDecryptFailures,
            "audio_playback_status": audioPlaybackStatus,
            "audio_format_summary": audioFormatSummary,
            "audio_queue_lead_ms": hot.audioQueueLeadMS,
            "audio_rtp_sequence_gaps": hot.audioRTPSequenceGaps,
            "audio_rtp_redundant_packets": hot.audioRTPRedundantPackets,
            "stream_connection_id": streamConnectionID,
            "setup_crypto_summary": setupCryptoSummary,
            "fairplay_key_message_hex": fairPlayKeyMessageHex,
            "fairplay_backend": fairPlayBackend,
            "session_key_status": sessionKeyStatus,
            "video_crypto_status": videoCryptoStatus,
            "video_decrypted_packets": hot.videoDecryptedPackets,
            "video_decrypt_failures": hot.videoDecryptFailures,
            "video_decoded_frames": hot.videoDecodedFrames,
            "has_live_video": hot.hasLiveVideo,
            "mirror_receive_callbacks": hot.mirrorReceiveCallbacks,
            "mirror_receive_max_chunk_bytes": hot.mirrorReceiveMaxChunkBytes,
            "mirror_receive_max_gap_ms": hot.mirrorReceiveMaxGapMS,
            "mirror_receive_gaps_over_20_ms": hot.mirrorReceiveGapsOver20MS,
            "mirror_receive_gaps_over_50_ms": hot.mirrorReceiveGapsOver50MS,
            "mirror_receive_gaps_over_100_ms": hot.mirrorReceiveGapsOver100MS,
            "video_packet_max_arrival_gap_ms": hot.videoPacketMaxGapMS,
            "video_packet_gaps_over_25_ms": hot.videoPacketGapsOver25MS,
            "video_packet_gaps_over_50_ms": hot.videoPacketGapsOver50MS,
            "video_packet_gaps_over_100_ms": hot.videoPacketGapsOver100MS,
            "decoded_frame_max_gap_ms": hot.decodedFrameMaxGapMS,
            "decoded_frame_gaps_over_25_ms": hot.decodedFrameGapsOver25MS,
            "decoded_frame_gaps_over_50_ms": hot.decodedFrameGapsOver50MS,
            "decoded_frame_gaps_over_100_ms": hot.decodedFrameGapsOver100MS,
            "feedback_heartbeats": feedbackHeartbeatCount,
            "session_generation": sessionGeneration,
            "active_session_peer": activeSessionPeer,
            "device_id": identity.deviceID,
            "public_identifier": identity.publicIdentifier,
            "features": String(format: "0x%016llX", featureBits),
            "video_advertisement_policy": "mirror-only; direct AirPlay Video/HLS disabled",
            "protocol_trace": Array(protocolLines.suffix(240))
        ]
    }

    func setOutputVolume(_ volume: Float) {
        audioPlayer.setOutputVolume(volume)
    }

    func enableAutomaticReceiver() {
        automaticReceiverEnabled = true
        start()
    }

    private func scheduleSettingsRestart() {
        guard automaticReceiverEnabled else { return }
        settingsRestartWorkItem?.cancel()

        let requestedQuality = videoQuality.rawValue
        let requestedFPS = preferredFrameRate.rawValue
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.diagnostics.addEvent(
                "AirPlay настройки изменены: \(requestedQuality) @ \(requestedFPS) FPS. Receiver переопубликуется автоматически."
            )
            self.stop(preserveAutomaticMode: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                guard let self, self.automaticReceiverEnabled else { return }
                self.start()
            }
        }
        settingsRestartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: work)
    }

    func start() {
        guard listener == nil else { return }
        diagnostics.resetCounters()
        let initialRequest = currentVideoRequest
        diagnostics.addEvent(
            "AirPlay video request: \(videoQuality.rawValue) \(initialRequest.width)×\(initialRequest.height) @ \(preferredFrameRate.rawValue) FPS • \(videoQuality.codecPolicyLabel) • \(initialRequest.strategy)"
        )
        diagnostics.addEvent(
            "AirPlay capabilities: mirror-only video; direct Video/HLS/play-queue отключены, Screen Mirroring сохранён."
        )
        resetHotTelemetry()
        protocolLines = []
        connectedPeer = "—"
        lastRequest = "—"
        mirrorDataPort = 0
        mirrorBytesReceived = 0
        mirrorVideoPackets = 0
        mirrorCodecPackets = 0
        mirrorHeartbeatPackets = 0
        mirrorMalformedPackets = 0
        mirrorCodecSummary = "—"
        mirrorFirstVideoPrefix = "—"
        audioDataPort = 0
        audioControlPort = 0
        audioPacketsReceived = 0
        audioBytesReceived = 0
        audioDecryptedPackets = 0
        audioDecryptFailures = 0
        audioPlaybackStatus = "—"
        audioFormatSummary = "—"
        audioQueueLeadMS = 0
        audioRTPSequenceGaps = 0
        audioRTPRedundantPackets = 0
        streamConnectionID = "—"
        setupCryptoSummary = "—"
        fairPlayKeyMessageHex = "—"
        fairPlayBackend = fairPlay.versionDescription
        sessionKeyStatus = "—"
        videoCryptoStatus = "—"
        videoDecryptedPackets = 0
        videoDecryptFailures = 0
        videoDecodedFrames = 0
        hasLiveVideo = false
        feedbackHeartbeatCount = 0
        activeSourceModelIdentifier = nil
        sourceModelIdentifier = "—"
        sourceNativeResolution = "—"
        sessionGeneration = 0
        activeControlConnectionID = nil
        activeSessionPeer = "—"
        sessionAudioKey = nil
        sessionAudioIV = nil
        audioPlayer.stop(resetCounters: true)
        activeStreamConnectionID = nil
        preparedVideoStreamID = nil
        videoDecodeSequence = 0
        videoTimestampOriginNanoseconds = nil
        fairPlay.reset()
        videoDecoder.reset()
        presentationStore.resetForNewSession()
        phase = .starting

        if !fairPlay.isAvailable {
            diagnostics.addEvent(
                fairPlay.loadError ?? "PlayFair provider не найден в MirrorLab.app",
                level: .error
            )
        }

        do {
            // Let Network.framework choose a free ephemeral port. The actual port is
            // published through Bonjour once the listener reaches .ready, so MirrorLab
            // can coexist with macOS' built-in AirPlay Receiver (which commonly owns 7000).
            let listener = try NWListener(using: .tcp)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            self.listener = listener
            listener.start(queue: networkQueue)
        } catch {
            phase = .failed
            diagnostics.addEvent("Не удалось запустить нативный AirPlay listener: \(error.localizedDescription)", level: .error)
        }
    }

    /// Ends only the active mirroring sender while keeping the AirPlay listener and
    /// Bonjour advertisement alive. This is the in-app equivalent of pressing
    /// "Stop Mirroring" on the sender: audio/video stop immediately, but MirrorLab
    /// remains available for a fresh connection.
    func stopCurrentSessionKeepingReceiver() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            let hadSession = self.activeControlConnectionID != nil
                || self.activeStreamConnectionID != nil
                || self.hotTelemetrySnapshot().hasLiveVideo
            guard hadSession else { return }

            self.sessionGeneration &+= 1
            self.teardownMirrorStreamForReconfiguration(
                expectedGeneration: nil,
                publishWaitingState: false
            )
            self.teardownAudioStreamForReconfiguration()

            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
            self.receiveBuffers.removeAll()
            self.transientPairingKeys.removeAll()
            self.fairPlayKeyMessages.removeAll()
            self.initialSetupPlists.removeAll()

            self.sessionAudioKey = nil
            self.sessionAudioIV = nil
            self.activeStreamConnectionID = nil
            self.preparedVideoStreamID = nil
            self.activeControlConnectionID = nil
            self.activeSessionPeer = "—"
            self.activeSourceModelIdentifier = nil
            self.videoDecodeSequence = 0
            self.videoTimestampOriginNanoseconds = nil
            self.fairPlay.reset()
            self.updateHotTelemetry { $0.hasLiveVideo = false }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sessionKeyStatus = "—"
                self.videoCryptoStatus = "—"
                self.connectedPeer = "—"
                self.sourceModelIdentifier = "—"
                self.sourceNativeResolution = "—"
                self.hasLiveVideo = false
                self.phase = self.listener == nil ? .idle : .advertising
                self.diagnostics.addEvent("AirPlay: трансляция остановлена из MirrorLab; приёмник остаётся доступен.")
                self.onFinalSessionEnded?()
            }
        }
    }

    func stop(preserveAutomaticMode: Bool = false) {
        if !preserveAutomaticMode {
            automaticReceiverEnabled = false
            settingsRestartWorkItem?.cancel()
            settingsRestartWorkItem = nil
        }
        let activeListener = listener
        listener = nil
        activeListener?.cancel()

        networkQueue.async { [weak self] in
            guard let self else { return }
            for connection in self.connections.values {
                connection.cancel()
            }
            self.connections.removeAll()
            self.receiveBuffers.removeAll()
            self.transientPairingKeys.removeAll()
            self.fairPlayKeyMessages.removeAll()
            self.initialSetupPlists.removeAll()

            self.mirrorListener?.cancel()
            self.mirrorListener = nil
            for connection in self.mirrorConnections.values {
                connection.cancel()
            }
            self.mirrorConnections.removeAll()
            self.mirrorReceiveStates.removeAll()
            self.mirrorConnectionGenerations.removeAll()
            self.mirrorListenerGeneration = 0

            self.audioDataListener?.cancel()
            self.audioControlListener?.cancel()
            self.audioDataListener = nil
            self.audioControlListener = nil
            for connection in self.audioDataConnections.values {
                connection.cancel()
            }
            for connection in self.audioControlConnections.values {
                connection.cancel()
            }
            self.audioDataConnections.removeAll()
            self.audioControlConnections.removeAll()
            self.pendingAudioSetupReply = nil
        }

        // Keep the last session counters after Stop so exported reports still
        // contain evidence of what actually happened. Ports are no longer live,
        // but packet/byte/decode statistics remain until the next Start.
        mirrorDataPort = 0
        audioDataPort = 0
        audioControlPort = 0
        sessionAudioKey = nil
        sessionAudioIV = nil
        audioPlayer.stop()
        activeStreamConnectionID = nil
        activeControlConnectionID = nil
        activeSessionPeer = "—"
        preparedVideoStreamID = nil
        videoDecodeSequence = 0
        videoTimestampOriginNanoseconds = nil
        updateHotTelemetry { $0.hasLiveVideo = false }
        hasLiveVideo = false
        fairPlay.reset()
        videoDecoder.reset()
        unpublishServices()
        phase = .idle
        connectedPeer = "—"
        listeningPort = 0
        diagnostics.addEvent("Нативный AirPlay-приёмник остановлен")
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let actualPort = listener?.port?.rawValue
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let actualPort {
                    self.listeningPort = actualPort
                }
                self.publishServices()
                self.phase = .advertising
                self.diagnostics.addEvent(
                    "Нативный AirPlay-приёмник опубликован как «\(self.receiverName)» на порту \(self.listeningPort)"
                )
            }
        case .failed(let error):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.phase = .failed
                self.diagnostics.addEvent(
                    "AirPlay listener завершился с ошибкой: \(error.localizedDescription)",
                    level: .error
                )
                self.listener = nil
                self.unpublishServices()
            }
        case .cancelled:
            break
        default:
            break
        }
    }

    private func publishServices() {
        unpublishServices()
        let airPlay = NetService(
            domain: "local.",
            type: "_airplay._tcp.",
            name: receiverName,
            port: Int32(listeningPort)
        )
        airPlay.setTXTRecord(NetService.data(fromTXTRecord: airPlayTXTRecord))
        airPlay.publish()
        airPlayService = airPlay

        let raopName = identity.deviceID.replacingOccurrences(of: ":", with: "").uppercased() + "@" + receiverName
        let raop = NetService(
            domain: "local.",
            type: "_raop._tcp.",
            name: raopName,
            port: Int32(listeningPort)
        )
        raop.setTXTRecord(NetService.data(fromTXTRecord: raopTXTRecord))
        raop.publish()
        raopService = raop
    }

    private func unpublishServices() {
        airPlayService?.stop()
        raopService?.stop()
        airPlayService = nil
        raopService = nil
    }

    private var airPlayTXTRecord: [String: Data] {
        makeTXT([
            "deviceid": identity.deviceID,
            "features": featureTXTValue,
            "flags": "0x4",
            "model": "AppleTV3,2",
            "pi": identity.publicIdentifier,
            "srcvers": "220.68",
            "vv": "2"
        ])
    }

    private var raopTXTRecord: [String: Data] {
        makeTXT([
            "txtvers": "1",
            "ch": "2",
            "cn": "0,1,2,3",
            "da": "true",
            "et": "0,3,5",
            "ft": featureTXTValue,
            "md": "0,1,2",
            "pw": "false",
            "sr": "44100",
            "ss": "16",
            "tp": "UDP",
            "vn": "65537",
            "vs": "220.68",
            "am": "AppleTV3,2",
            "sf": "0x4"
        ])
    }

    private func makeTXT(_ strings: [String: String]) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: strings.map { key, value in
            (key, Data(value.utf8))
        })
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        receiveBuffers[id] = Data()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let peer = String(describing: connection.endpoint)
                DispatchQueue.main.async {
                    self.connectedPeer = peer
                    self.phase = .handshaking
                    self.diagnostics.addEvent("AirPlay клиент подключён: \(peer)")
                }
            case .failed(let error):
                self.finishConnection(id: id, message: "AirPlay соединение: \(error.localizedDescription)")
            case .cancelled:
                self.finishConnection(id: id, message: nil)
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
        receiveNext(id: id, connection: connection)
    }

    private func receiveNext(id: UUID, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var buffer = self.receiveBuffers[id] ?? Data()
                buffer.append(data)
                while let request = AirPlayRequest.pop(from: &buffer) {
                    self.handle(request: request, connectionID: id, connection: connection)
                }
                self.receiveBuffers[id] = buffer
            }

            if let error {
                if self.connections[id] == nil { return }
                self.finishConnection(id: id, message: "AirPlay receive: \(error.localizedDescription)")
                return
            }
            if isComplete {
                self.finishConnection(id: id, message: nil)
                return
            }
            self.receiveNext(id: id, connection: connection)
        }
    }

    private func finishConnection(id: UUID, message: String?) {
        connections[id]?.cancel()
        connections.removeValue(forKey: id)
        receiveBuffers.removeValue(forKey: id)
        transientPairingKeys.removeValue(forKey: id)
        fairPlayKeyMessages.removeValue(forKey: id)
        initialSetupPlists.removeValue(forKey: id)
        if let message {
            DispatchQueue.main.async { [weak self] in
                self?.diagnostics.addEvent(message, level: .warning)
            }
        }
    }

    private func handle(request: AirPlayRequest, connectionID: UUID, connection: NWConnection) {
        let route = request.route

        // /feedback is a normal AirPlay keep-alive. Do not let it downgrade the
        // visible phase back to "handshake" or flood the event list every 2 s.
        if request.method == "POST" && route == "/feedback" {
            send(response: AirPlayResponse.ok(request: request), over: connection)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.feedbackHeartbeatCount &+= 1
                let n = self.feedbackHeartbeatCount
                if n <= 2 || (n & (n - 1)) == 0 {
                    self.protocolLines.append("POST /feedback heartbeat #\(n)")
                    if self.protocolLines.count > 400 {
                        self.protocolLines.removeFirst(self.protocolLines.count - 400)
                    }
                }
            }
            return
        }

        let bodyPrefix = request.body.prefix(16).map { String(format: "%02X", $0) }.joined()
        let trace = "\(request.method) \(route) len=\(request.body.count) ua=\(request.headers["user-agent"] ?? "—") body16=\(bodyPrefix)"
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastRequest = "\(request.method) \(route)"
            if self.phase != .receivingMedia && self.phase != .waitingForMedia {
                self.phase = .handshaking
            }
            self.protocolLines.append(trace)
            if self.protocolLines.count > 400 {
                self.protocolLines.removeFirst(self.protocolLines.count - 400)
            }
            self.diagnostics.addEvent("AirPlay: \(request.method) \(route) (\(request.body.count) B)")
        }

        switch (request.method, route) {
        case ("GET", "/info"):
            send(
                response: AirPlayResponse.ok(
                    request: request,
                    contentType: "application/x-apple-binary-plist",
                    body: makeInfoPlist()
                ),
                over: connection
            )

        case ("GET", "/server-info"):
            send(
                response: AirPlayResponse.ok(
                    request: request,
                    contentType: "text/x-apple-plist+xml",
                    body: makeServerInfoPlist()
                ),
                over: connection
            )

        case ("GET", "/stream.xml"):
            send(
                response: AirPlayResponse.ok(
                    request: request,
                    contentType: "text/x-apple-plist+xml",
                    body: makeStreamXML()
                ),
                over: connection
            )

        case ("POST", "/pair-setup"):
            if request.body.count == 32 {
                transientPairingKeys[connectionID] = request.body
                send(
                    response: AirPlayResponse.ok(
                        request: request,
                        contentType: "application/octet-stream",
                        body: identity.signingPublicKey
                    ),
                    over: connection
                )
            } else {
                send(response: AirPlayResponse.badRequest(request: request), over: connection)
            }

        case ("POST", "/pair-verify"):
            // Pair-verify will become a small native crypto layer. Keeping it explicit
            // here is useful: if a device still requests legacy pairing despite our
            // feature mask, the report shows the exact real-device payload.
            send(response: AirPlayResponse.notImplemented(request: request, stage: "pair-verify"), over: connection)

        case ("POST", "/fp-setup"):
            handleFairPlaySetup(
                request: request,
                connectionID: connectionID,
                connection: connection
            )

        case ("SETUP", _), ("POST", "/setup"):
            handleMediaSetup(
                request: request,
                connectionID: connectionID,
                connection: connection
            )

        case ("RECORD", _):
            send(
                response: AirPlayResponse.ok(
                    request: request,
                    additionalHeaders: ["Audio-Latency": "0"]
                ),
                over: connection
            )

        case ("GET_PARAMETER", _):
            let wantsVolume = String(data: request.body, encoding: .utf8)?
                .localizedCaseInsensitiveContains("volume") == true
            let body = wantsVolume ? Data("volume: 0.000000\r\n".utf8) : Data()
            send(
                response: AirPlayResponse.ok(
                    request: request,
                    contentType: wantsVolume ? "text/parameters" : nil,
                    body: body
                ),
                over: connection
            )

        case ("SET_PARAMETER", _), ("FLUSH", _), ("PAUSE", _):
            send(response: AirPlayResponse.ok(request: request), over: connection)

        case ("OPTIONS", _):
            send(
                response: AirPlayResponse.ok(
                    request: request,
                    additionalHeaders: [
                        "Public": "ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER"
                    ]
                ),
                over: connection
            )

        case ("TEARDOWN", _):
            handleTeardown(
                request: request,
                connectionID: connectionID,
                connection: connection
            )

        default:
            send(response: AirPlayResponse.notImplemented(request: request, stage: route), over: connection)
        }
    }

    private func handleTeardown(
        request: AirPlayRequest,
        connectionID: UUID,
        connection: NWConnection
    ) {
        let plist = decodeBinaryPlist(request.body)
        let streams = plist?["streams"] as? [[String: Any]] ?? []
        let streamTypes = streams.compactMap { Self.intValue($0["type"]) }

        guard isActiveSessionConnection(connectionID) else {
            appendProtocolLine(
                "STALE TEARDOWN ignored streams=" +
                (streamTypes.isEmpty ? "session" : streamTypes.map { String($0) }.joined(separator: ","))
            )
            send(response: AirPlayResponse.ok(request: request), over: connection)
            return
        }

        let teardownGeneration = sessionGeneration

        if streamTypes.isEmpty {
            appendProtocolLine("TEARDOWN session/end (no stream list)")
        } else {
            appendProtocolLine("TEARDOWN streams=\(streamTypes.map { String($0) }.joined(separator: ","))")
        }

        // A modern iPhone can TEARDOWN only stream type 110 while rotating or
        // rebuilding the mirroring encoder, then immediately issue a fresh SETUP.
        // Do not cancel the RTSP control connection here: doing that froze the
        // 0.3.4 session exactly when portrait -> landscape -> portrait occurred.
        send(response: AirPlayResponse.ok(request: request), over: connection)

        if streamTypes.contains(110) {
            teardownMirrorStreamForReconfiguration(
                expectedGeneration: teardownGeneration
            )
        }
        if streamTypes.contains(96) {
            teardownAudioStreamForReconfiguration()
        }

        if streamTypes.isEmpty {
            // Final session teardown. Keep the receiver listener/Bonjour service
            // alive so the same device (or a friend) can reconnect immediately.
            teardownMirrorStreamForReconfiguration(
                expectedGeneration: teardownGeneration
            )
            teardownAudioStreamForReconfiguration()
            sessionAudioKey = nil
            sessionAudioIV = nil
            activeStreamConnectionID = nil
            preparedVideoStreamID = nil
            videoDecodeSequence = 0
            videoTimestampOriginNanoseconds = nil
            fairPlay.reset()
            activeControlConnectionID = nil
            activeSessionPeer = "—"
            updateHotTelemetry { $0.hasLiveVideo = false }
            DispatchQueue.main.async { [weak self] in
                guard let self, teardownGeneration == self.sessionGeneration else { return }
                self.sessionKeyStatus = "—"
                self.videoCryptoStatus = "—"
                self.phase = .advertising
                self.connectedPeer = "—"
                self.hasLiveVideo = false
                self.diagnostics.addEvent("AirPlay session завершена; приёмник остаётся доступен для нового подключения")
                self.onFinalSessionEnded?()
            }
        }
    }

    private func teardownMirrorStreamForReconfiguration(
        expectedGeneration: UInt64? = nil,
        publishWaitingState: Bool = true
    ) {
        if let expectedGeneration, expectedGeneration != sessionGeneration {
            appendProtocolLine(
                "STALE mirror teardown ignored generation=\(expectedGeneration) current=\(sessionGeneration)"
            )
            return
        }

        let generation = sessionGeneration
        mirrorListener?.cancel()
        mirrorListener = nil
        mirrorListenerGeneration = 0
        for connection in mirrorConnections.values {
            connection.cancel()
        }
        mirrorConnections.removeAll()
        mirrorReceiveStates.removeAll()
        mirrorConnectionGenerations.removeAll()
        activeStreamConnectionID = nil
        preparedVideoStreamID = nil
        videoDecodeSequence = 0
        videoTimestampOriginNanoseconds = nil
        videoDecoder.reset()
        presentationStore.clear()
        videoArrivalFloor.reset()
        updateHotTelemetry { $0.hasLiveVideo = false }

        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.sessionGeneration else { return }
            self.mirrorDataPort = 0
            self.videoCryptoStatus = self.sessionAudioKey == nil ? "Ждёт session key" : "Ждёт новый video SETUP"
            self.hasLiveVideo = false
            if publishWaitingState, self.listener != nil {
                self.phase = .waitingForMedia
            }
            if publishWaitingState {
                self.diagnostics.addEvent("AirPlay video stream закрыт; RTSP session сохранена для re-SETUP")
            }
        }
    }

    private func teardownAudioStreamForReconfiguration() {
        audioDataListener?.cancel()
        audioControlListener?.cancel()
        audioDataListener = nil
        audioControlListener = nil
        for connection in audioDataConnections.values {
            connection.cancel()
        }
        for connection in audioControlConnections.values {
            connection.cancel()
        }
        audioDataConnections.removeAll()
        audioControlConnections.removeAll()
        audioResendConnection?.cancel()
        audioResendConnection = nil
        audioResendGeneration = 0
        audioResendRequestSequence = 1
        pendingAudioSetupReply = nil
        audioPlayer.stop()
        audioSyncPoint = nil
        audioArrivalFloorNTPEpoch.reset()
        audioArrivalFloorRaw.reset()
        updateHotTelemetry { $0.audioVideoArrivalSkewMS = nil }

        DispatchQueue.main.async { [weak self] in
            self?.audioDataPort = 0
            self?.audioControlPort = 0
            self?.audioPlaybackStatus = "Остановлен"
        }
    }

    private func beginSessionTakeoverIfNeeded(
        connectionID: UUID,
        connection: NWConnection
    ) {
        if activeControlConnectionID == connectionID { return }

        let previousOwner = activeControlConnectionID
        sessionGeneration &+= 1
        activeControlConnectionID = connectionID
        activeSessionPeer = String(describing: connection.endpoint)
        let generation = sessionGeneration

        // Stop the previous sender's media before resetting the shared FairPlay
        // state. Network.framework callbacks are serialized on networkQueue, and
        // mirror connections additionally carry their generation, so queued data
        // from the previous device cannot be decrypted with the new key.
        teardownMirrorStreamForReconfiguration(
            expectedGeneration: nil,
            publishWaitingState: false
        )
        teardownAudioStreamForReconfiguration()

        // Retire stale RTSP/control sockets. Keep the new phase-1 connection; any
        // auxiliary connection for the new sender is opened afterwards.
        let staleIDs = connections.keys.filter { $0 != connectionID }
        for staleID in staleIDs {
            connections[staleID]?.cancel()
            connections.removeValue(forKey: staleID)
            receiveBuffers.removeValue(forKey: staleID)
            transientPairingKeys.removeValue(forKey: staleID)
            fairPlayKeyMessages.removeValue(forKey: staleID)
            initialSetupPlists.removeValue(forKey: staleID)
        }

        fairPlay.reset()
        activeSourceModelIdentifier = nil
        DispatchQueue.main.async { [weak self] in
            self?.sourceModelIdentifier = "—"
            self?.sourceNativeResolution = "—"
        }
        sessionAudioKey = nil
        sessionAudioIV = nil
        audioPlayer.stop()
        activeStreamConnectionID = nil
        preparedVideoStreamID = nil
        videoDecodeSequence = 0
        videoTimestampOriginNanoseconds = nil
        presentationStore.resetForNewSession()
        updateHotTelemetry { $0.hasLiveVideo = false }

        appendProtocolLine(
            "SESSION generation=\(generation) owner=\(activeSessionPeer)" +
            (previousOwner == nil ? "" : " takeover=1")
        )
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.sessionGeneration else { return }
            self.hasLiveVideo = false
            self.sessionKeyStatus = "—"
            self.videoCryptoStatus = "—"
            self.connectedPeer = self.activeSessionPeer
            if previousOwner != nil {
                self.diagnostics.addEvent(
                    "AirPlay: новый источник стал активным; предыдущая сессия отключена."
                )
            }
        }
    }

    private func isActiveSessionConnection(_ connectionID: UUID) -> Bool {
        activeControlConnectionID == connectionID
    }

    private func handleFairPlaySetup(
        request: AirPlayRequest,
        connectionID: UUID,
        connection: NWConnection
    ) {
        guard request.body.count >= 7,
              request.body.prefix(4) == Data("FPLY".utf8),
              request.body[4] == 0x03 else {
            diagnostics.addEvent("FairPlay: неизвестный FPLY header", level: .error)
            send(response: AirPlayResponse.badRequest(request: request), over: connection)
            return
        }

        guard fairPlay.isAvailable else {
            diagnostics.addEvent(
                fairPlay.loadError ?? "FairPlay provider недоступен",
                level: .error
            )
            send(
                response: AirPlayResponse.serverError(request: request),
                over: connection
            )
            return
        }

        let phaseByte = request.body[6]
        switch phaseByte {
        case 0x01:
            guard request.body.count == 16 else {
                send(response: AirPlayResponse.badRequest(request: request), over: connection)
                return
            }

            let mode = request.body[14]
            // FPLY phase-1 is the ownership boundary. If another device starts
            // mirroring while the old one is still alive, atomically retire the
            // old media/control state before applying the new FairPlay session.
            beginSessionTakeoverIfNeeded(
                connectionID: connectionID,
                connection: connection
            )
            do {
                let responseBody = try fairPlay.setup(request.body)
                diagnostics.addEvent("FairPlay phase 1 принят: mode \(mode)")
                appendProtocolLine(
                    "FairPlay provider FPLY311 → FPLY312 mode=\(mode) response=\(responseBody.count)B"
                )
                send(
                    response: AirPlayResponse.ok(
                        request: request,
                        contentType: "application/octet-stream",
                        body: responseBody,
                        additionalHeaders: [
                            "X-Apple-ET": request.headers["x-apple-et"] ?? "32"
                        ]
                    ),
                    over: connection
                )
            } catch {
                diagnostics.addEvent(
                    "FairPlay provider setup: \(error.localizedDescription)",
                    level: .error
                )
                send(response: AirPlayResponse.badRequest(request: request), over: connection)
            }

        case 0x03:
            guard activeControlConnectionID == connectionID else {
                appendProtocolLine("STALE FairPlay phase-3 ignored")
                send(response: AirPlayResponse.badRequest(request: request), over: connection)
                return
            }
            do {
                let responseBody = try fairPlay.handshake(request.body)
                fairPlayKeyMessages[connectionID] = request.body
                let keyMessageHex = request.body.map { String(format: "%02X", $0) }.joined()
                appendProtocolLine(
                    "FairPlay provider FPLY313 → FPLY314 keyMessage=\(request.body.count)B"
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.fairPlayKeyMessageHex = keyMessageHex
                    self.fairPlayBackend = self.fairPlay.versionDescription
                    self.phase = .waitingForMedia
                    self.diagnostics.addEvent(
                        "FairPlay handshake пройден встроенным PlayFair provider."
                    )
                }

                send(
                    response: AirPlayResponse.ok(
                        request: request,
                        contentType: "application/octet-stream",
                        body: responseBody,
                        additionalHeaders: [
                            "X-Apple-ET": request.headers["x-apple-et"] ?? "32"
                        ]
                    ),
                    over: connection
                )
            } catch {
                diagnostics.addEvent(
                    "FairPlay provider handshake: \(error.localizedDescription)",
                    level: .error
                )
                send(response: AirPlayResponse.badRequest(request: request), over: connection)
            }

        default:
            diagnostics.addEvent(
                "FairPlay: неподдерживаемая FPLY phase \(phaseByte)",
                level: .error
            )
            send(
                response: AirPlayResponse.notImplemented(
                    request: request,
                    stage: "fp-phase-\(phaseByte)"
                ),
                over: connection
            )
        }
    }

    private func prepareVideoCryptoIfPossible() {
        guard let sessionAudioKey, let activeStreamConnectionID else {
            DispatchQueue.main.async { [weak self] in
                self?.videoCryptoStatus = "Ждёт session key/stream ID"
            }
            return
        }

        // CTR is stateful across encrypted video payloads. Repeated SETUP type=110
        // for an already-prepared stream must not rewind the counter to its IV.
        if preparedVideoStreamID == activeStreamConnectionID && fairPlay.isVideoCryptoReady {
            return
        }

        do {
            try fairPlay.prepareVideoCrypto(
                sessionKey: sessionAudioKey,
                streamConnectionID: activeStreamConnectionID
            )
            preparedVideoStreamID = activeStreamConnectionID
            appendProtocolLine(
                "Mirror AES-CTR ready for streamConnectionID=\(activeStreamConnectionID)"
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.videoCryptoStatus = "AES-CTR готов"
                self.diagnostics.addEvent(
                    "AirPlay video crypto готов: stream key/IV выведены из FairPlay session key."
                )
            }
        } catch {
            preparedVideoStreamID = nil
            appendProtocolLine(
                "Mirror AES-CTR init failed: \(error.localizedDescription)"
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.videoCryptoStatus = "Ошибка AES-CTR"
                self.diagnostics.addEvent(
                    "AirPlay video crypto: \(error.localizedDescription)",
                    level: .error
                )
            }
        }
    }

    private func handleMediaSetup(
        request: AirPlayRequest,
        connectionID: UUID,
        connection: NWConnection
    ) {
        guard isActiveSessionConnection(connectionID) else {
            appendProtocolLine("STALE SETUP ignored for inactive AirPlay source")
            send(response: AirPlayResponse.ok(request: request), over: connection)
            return
        }

        guard let root = decodeBinaryPlist(request.body) else {
            appendProtocolLine("SETUP: body не распознан как plist (\(request.body.count)B)")
            send(response: AirPlayResponse.badRequest(request: request), over: connection)
            return
        }

        let keys = root.keys.sorted().joined(separator: ",")
        let streamTypes = (root["streams"] as? [[String: Any]])?
            .compactMap { Self.intValue($0["type"]) } ?? []

        appendProtocolLine(
            "SETUP plist keys=[\(keys)] streams=\(streamTypes.map { String($0) }.joined(separator: ","))"
        )

        if streamTypes.isEmpty {
            initialSetupPlists[connectionID] = root

            if let model = root["model"] as? String, !model.isEmpty {
                activeSourceModelIdentifier = model
                let profile = Self.nativeDisplayProfile(for: model)
                let profileText = profile?.label ?? "fallback 2560×1440"
                appendProtocolLine("SOURCE model=\(model) originalProfile=\(profileText)")
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.sourceModelIdentifier = model
                    self.sourceNativeResolution = profile?.label ?? "fallback 2560×1440"
                    self.diagnostics.addEvent(
                        "AirPlay source: \(model) • Original profile \(profileText)"
                    )
                }
            }

            let cryptoParts = root.keys.sorted().compactMap { key -> String? in
                guard let value = root[key] else { return nil }
                if let bytes = value as? Data {
                    return "\(key)=\(bytes.count)B:\(Self.hexPrefix(bytes, bytes: bytes.count))"
                }
                if key == "timingPort" || key == "timingProtocol" || key == "isScreenMirroringSession" {
                    return "\(key)=\(value)"
                }
                return nil
            }
            if !cryptoParts.isEmpty {
                let summary = cryptoParts.joined(separator: " | ")
                appendProtocolLine("SETUP session crypto " + summary)
                DispatchQueue.main.async { [weak self] in
                    self?.setupCryptoSummary = summary
                }
            }

            if let audioIV = root["eiv"] as? Data, audioIV.count == 16 {
                sessionAudioIV = audioIV
                appendProtocolLine("AirPlay audio AES IV 16B: ready")
            } else {
                sessionAudioIV = nil
            }

            if let encryptedKey = root["ekey"] as? Data {
                do {
                    let unwrapped = try fairPlay.decryptSessionKey(encryptedKey)
                    sessionAudioKey = unwrapped
                    preparedVideoStreamID = nil
                    appendProtocolLine("FairPlay ekey 72B → session AES key 16B: OK")
                    prepareVideoCryptoIfPossible()
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.sessionKeyStatus = "AES-128 session key готов"
                        self.diagnostics.addEvent(
                            "AirPlay: FairPlay session key успешно извлечён из ekey."
                        )
                    }
                } catch {
                    sessionAudioKey = nil
                    sessionAudioIV = nil
                    appendProtocolLine("FairPlay ekey unwrap failed: \(error.localizedDescription)")
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.sessionKeyStatus = "Ошибка unwrap"
                        self.diagnostics.addEvent(
                            "AirPlay FairPlay key unwrap: \(error.localizedDescription)",
                            level: .error
                        )
                    }
                }
            }

            let responseObject: [String: Any] = [
                // The existing native control listener can also receive AirPlay
                // event/feedback RTSP connections. Timing is intentionally not
                // overridden yet; the sender keeps the timing endpoint it offered.
                "eventPort": Int(listeningPort)
            ]
            send(
                response: AirPlayResponse.ok(
                    request: request,
                    contentType: "application/x-apple-binary-plist",
                    body: makeBinaryPlist(responseObject)
                ),
                over: connection
            )
            diagnostics.addEvent("AirPlay SETUP session metadata принято")
            return
        }

        if streamTypes.contains(110) {
            let streams = root["streams"] as? [[String: Any]] ?? []
            if let screenStream = streams.first(where: { Self.intValue($0["type"]) == 110 }) {
                appendProtocolLine("SETUP type=110 request " + compactStreamDescription(screenStream))
                if let rawID = screenStream["streamConnectionID"] {
                    let idString = Self.unsignedIntegerString(rawID)
                    let numericID = Self.uint64Value(rawID)
                    activeStreamConnectionID = numericID
                    DispatchQueue.main.async { [weak self] in
                        self?.streamConnectionID = idString
                    }

                    prepareVideoCryptoIfPossible()
                }
            }
            startMirrorListenerAndReply(request: request, connection: connection)
            return
        }

        if streamTypes.contains(96) {
            let streams = root["streams"] as? [[String: Any]] ?? []
            if let realtimeAudio = streams.first(where: { Self.intValue($0["type"]) == 96 }) {
                appendProtocolLine("SETUP type=96 request " + compactStreamDescription(realtimeAudio))
                configureRealtimeAudio(from: realtimeAudio)
                configureAudioResendTransport(from: realtimeAudio, controlConnection: connection)
            }
            startAudioListenersAndReply(request: request, connection: connection)
            return
        }

        let responseObject: [String: Any] = ["streams": []]
        send(
            response: AirPlayResponse.ok(
                request: request,
                contentType: "application/x-apple-binary-plist",
                body: makeBinaryPlist(responseObject)
            ),
            over: connection
        )
        diagnostics.addEvent(
            "AirPlay SETUP stream types \(streamTypes) пока не реализованы",
            level: .warning
        )
    }

    private func startMirrorListenerAndReply(
        request: AirPlayRequest,
        connection: NWConnection
    ) {
        if let mirrorListener,
           let port = mirrorListener.port?.rawValue,
           port > 0 {
            sendMirrorSetupReply(request: request, port: port, connection: connection)
            return
        }

        do {
            let generation = sessionGeneration
            // Mark the mirror socket as interactive video. The Mac only sends TCP ACKs
            // on it, but on a busy Wi-Fi channel those ACKs pace the sender: with the
            // default best-effort class they queue behind bulk traffic, the iPhone's
            // congestion window stalls and frames arrive in bursts. .interactiveVideo
            // maps to the WMM video access category.
            let mirrorTCP = NWProtocolTCP.Options()
            mirrorTCP.noDelay = true
            let mirrorParameters = NWParameters(tls: nil, tcp: mirrorTCP)
            mirrorParameters.serviceClass = .interactiveVideo
            let listener = try NWListener(using: mirrorParameters)
            mirrorListenerGeneration = generation
            listener.newConnectionHandler = { [weak self] dataConnection in
                self?.acceptMirrorConnection(dataConnection, generation: generation)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener?.port?.rawValue else { return }
                    DispatchQueue.main.async {
                        guard generation == self.sessionGeneration else { return }
                        self.mirrorDataPort = port
                        self.phase = .waitingForMedia
                        self.diagnostics.addEvent(
                            "AirPlay mirror TCP listener готов на порту \(port)"
                        )
                    }
                    self.sendMirrorSetupReply(
                        request: request,
                        port: port,
                        connection: connection
                    )
                case .failed(let error):
                    DispatchQueue.main.async {
                        self.diagnostics.addEvent(
                            "Mirror data listener: \(error.localizedDescription)",
                            level: .error
                        )
                    }
                    self.send(
                        response: AirPlayResponse.serverError(request: request),
                        over: connection
                    )
                default:
                    break
                }
            }
            mirrorListener = listener
            listener.start(queue: networkQueue)
        } catch {
            diagnostics.addEvent(
                "Не удалось создать mirror data listener: \(error.localizedDescription)",
                level: .error
            )
            send(response: AirPlayResponse.serverError(request: request), over: connection)
        }
    }

    private func sendMirrorSetupReply(
        request: AirPlayRequest,
        port: UInt16,
        connection: NWConnection
    ) {
        let responseObject: [String: Any] = [
            "streams": [[
                "dataPort": Int(port),
                "type": 110
            ]]
        ]
        send(
            response: AirPlayResponse.ok(
                request: request,
                contentType: "application/x-apple-binary-plist",
                body: makeBinaryPlist(responseObject)
            ),
            over: connection
        )
        appendProtocolLine("SETUP type=110 → dataPort \(port)")
    }

    private func acceptMirrorConnection(_ connection: NWConnection, generation: UInt64) {
        guard generation == sessionGeneration else {
            connection.cancel()
            return
        }
        let id = UUID()
        mirrorConnections[id] = connection
        mirrorReceiveStates[id] = MirrorReceiveState()
        mirrorConnectionGenerations[id] = generation
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard generation == self.sessionGeneration else {
                    connection.cancel()
                    return
                }
                DispatchQueue.main.async {
                    guard generation == self.sessionGeneration else { return }
                    self.phase = .receivingMedia
                    self.diagnostics.addEvent(
                        "AirPlay mirror TCP transport подключён: \(connection.endpoint)"
                    )
                }
                self.receiveMirrorData(id: id, connection: connection, generation: generation)
            case .failed(let error):
                self.finishMirrorConnection(
                    id: id,
                    message: "Mirror TCP: \(error.localizedDescription)"
                )
            case .cancelled:
                self.finishMirrorConnection(id: id, message: nil)
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }

    private func receiveMirrorData(
        id: UUID,
        connection: NWConnection,
        generation: UInt64
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard generation == self.sessionGeneration,
                  self.mirrorConnectionGenerations[id] == generation else {
                self.finishMirrorConnection(id: id, message: nil)
                return
            }

            if let data, !data.isEmpty {
                let now = ProcessInfo.processInfo.systemUptime
                self.updateHotTelemetry { telemetry in
                    telemetry.mirrorBytesReceived &+= UInt64(data.count)
                    telemetry.mirrorReceiveCallbacks &+= 1
                    telemetry.mirrorReceiveMaxChunkBytes = max(
                        telemetry.mirrorReceiveMaxChunkBytes,
                        UInt64(data.count)
                    )
                    if telemetry.lastMirrorReceiveHostTime > 0 {
                        let gapMS = (now - telemetry.lastMirrorReceiveHostTime) * 1_000
                        telemetry.mirrorReceiveMaxGapMS = max(telemetry.mirrorReceiveMaxGapMS, gapMS)
                        if gapMS > 20 { telemetry.mirrorReceiveGapsOver20MS &+= 1 }
                        if gapMS > 50 { telemetry.mirrorReceiveGapsOver50MS &+= 1 }
                        if gapMS > 100 { telemetry.mirrorReceiveGapsOver100MS &+= 1 }
                    }
                    telemetry.lastMirrorReceiveHostTime = now
                }

                guard let state = self.mirrorReceiveStates[id] else {
                    self.finishMirrorConnection(id: id, message: "Mirror TCP state missing")
                    return
                }
                state.buffer.append(data)
                self.parseMirrorPackets(from: &state.buffer)
            }

            if let error {
                if self.mirrorConnections[id] == nil { return }
                self.finishMirrorConnection(
                    id: id,
                    message: "Mirror TCP receive: \(error.localizedDescription)"
                )
                return
            }
            if isComplete {
                self.finishMirrorConnection(id: id, message: nil)
                return
            }
            self.receiveMirrorData(id: id, connection: connection, generation: generation)
        }
    }

    private func finishMirrorConnection(id: UUID, message: String?) {
        mirrorConnections[id]?.cancel()
        mirrorConnections.removeValue(forKey: id)
        mirrorReceiveStates.removeValue(forKey: id)
        mirrorConnectionGenerations.removeValue(forKey: id)
        if let message {
            DispatchQueue.main.async { [weak self] in
                self?.diagnostics.addEvent(message, level: .warning)
            }
        }
    }

    private func configureRealtimeAudio(from stream: [String: Any]) {
        let audioFormat = Self.intValue(stream["audioFormat"]) ?? 0
        let compressionType = Self.intValue(stream["ct"]) ?? 0
        let framesPerPacket = UInt32(max(1, Self.intValue(stream["spf"]) ?? 480))

        let sampleRate: Double
        switch audioFormat {
        case 0x01000000:
            sampleRate = 44_100
            audioSyncSampleRate = sampleRate
        case 0x02000000:
            sampleRate = 48_000
            audioSyncSampleRate = sampleRate
        default:
            let summary = String(
                format: "unsupported audioFormat=0x%X ct=%d spf=%u",
                audioFormat,
                compressionType,
                framesPerPacket
            )
            appendProtocolLine("AirPlay audio: " + summary)
            DispatchQueue.main.async { [weak self] in
                self?.audioFormatSummary = summary
                self?.audioPlaybackStatus = "Неподдерживаемый формат"
            }
            audioPlayer.stop()
            return
        }

        guard compressionType == 8 else {
            let summary = String(
                format: "unsupported ct=%d audioFormat=0x%X",
                compressionType,
                audioFormat
            )
            appendProtocolLine("AirPlay audio: " + summary)
            DispatchQueue.main.async { [weak self] in
                self?.audioFormatSummary = summary
                self?.audioPlaybackStatus = "Неподдерживаемый codec"
            }
            audioPlayer.stop()
            return
        }

        do {
            try audioPlayer.configure(
                sampleRate: sampleRate,
                channels: 2,
                framesPerPacket: framesPerPacket
            )
            let summary = "AAC-ELD \(Int(sampleRate)) Hz / 2ch / \(framesPerPacket) spf → PCM realtime"
            appendProtocolLine("AirPlay audio format: " + summary)
            DispatchQueue.main.async { [weak self] in
                self?.audioFormatSummary = summary
                self?.audioPlaybackStatus = "AAC-ELD → PCM готов"
            }
        } catch {
            appendProtocolLine("AirPlay low-latency audio configure failed: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.audioFormatSummary = String(format: "AAC-ELD 0x%X", audioFormat)
                self.audioPlaybackStatus = "Ошибка PCM output"
                self.diagnostics.addEvent(
                    "AirPlay audio config: \(error.localizedDescription)",
                    level: .error
                )
            }
        }
    }

    private func startAudioListenersAndReply(
        request: AirPlayRequest,
        connection: NWConnection
    ) {
        // Deduplicate retransmitted SETUP requests while the ephemeral UDP ports
        // are transitioning to .ready. The latest request has the right CSeq.
        pendingAudioSetupReply = (request, connection)

        if audioDataListener == nil {
            do {
                let listener = try NWListener(using: .udp)
                listener.newConnectionHandler = { [weak self] dataConnection in
                    self?.acceptAudioUDPConnection(dataConnection, isControl: false)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue {
                            DispatchQueue.main.async {
                                self.audioDataPort = port
                                self.diagnostics.addEvent("AirPlay audio UDP data port готов: \(port)")
                            }
                        }
                        self.flushPendingAudioSetupRepliesIfReady()
                    case .failed(let error):
                        DispatchQueue.main.async {
                            self.diagnostics.addEvent(
                                "AirPlay audio data listener: \(error.localizedDescription)",
                                level: .error
                            )
                        }
                    default:
                        break
                    }
                }
                audioDataListener = listener
                listener.start(queue: networkQueue)
            } catch {
                diagnostics.addEvent(
                    "Не удалось открыть AirPlay audio data UDP: \(error.localizedDescription)",
                    level: .error
                )
            }
        }

        if audioControlListener == nil {
            do {
                let listener = try NWListener(using: .udp)
                listener.newConnectionHandler = { [weak self] controlConnection in
                    self?.acceptAudioUDPConnection(controlConnection, isControl: true)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue {
                            DispatchQueue.main.async {
                                self.audioControlPort = port
                                self.diagnostics.addEvent("AirPlay audio UDP control port готов: \(port)")
                            }
                        }
                        self.flushPendingAudioSetupRepliesIfReady()
                    case .failed(let error):
                        DispatchQueue.main.async {
                            self.diagnostics.addEvent(
                                "AirPlay audio control listener: \(error.localizedDescription)",
                                level: .error
                            )
                        }
                    default:
                        break
                    }
                }
                audioControlListener = listener
                listener.start(queue: networkQueue)
            } catch {
                diagnostics.addEvent(
                    "Не удалось открыть AirPlay audio control UDP: \(error.localizedDescription)",
                    level: .error
                )
            }
        }

        flushPendingAudioSetupRepliesIfReady()
    }

    private func flushPendingAudioSetupRepliesIfReady() {
        guard let dataPort = audioDataListener?.port?.rawValue,
              let controlPort = audioControlListener?.port?.rawValue,
              dataPort > 0,
              controlPort > 0,
              let (request, connection) = pendingAudioSetupReply else {
            return
        }

        pendingAudioSetupReply = nil

        var streamReply: [String: Any] = [
            "controlPort": Int(controlPort),
            "dataPort": Int(dataPort),
            "streamID": 1,
            "type": 96
        ]
        if let root = decodeBinaryPlist(request.body),
           let streams = root["streams"] as? [[String: Any]],
           let requestStream = streams.first(where: { Self.intValue($0["type"]) == 96 }),
           let connectionID = requestStream["streamConnectionID"] {
            streamReply["streamConnectionID"] = connectionID
        }

        let responseObject: [String: Any] = [
            "streams": [streamReply]
        ]
        send(
            response: AirPlayResponse.ok(
                request: request,
                contentType: "application/x-apple-binary-plist",
                body: makeBinaryPlist(responseObject)
            ),
            over: connection
        )

        appendProtocolLine("SETUP type=96 → dataPort \(dataPort) controlPort \(controlPort)")
        DispatchQueue.main.async { [weak self] in
            self?.diagnostics.addEvent(
                "AirPlay realtime audio transport согласован: UDP data \(dataPort), control \(controlPort)"
            )
        }
    }

    private func configureAudioResendTransport(
        from stream: [String: Any],
        controlConnection: NWConnection
    ) {
        audioResendConnection?.cancel()
        audioResendConnection = nil
        audioResendGeneration = 0
        audioResendRequestSequence = 1

        guard let remoteControlPortValue = Self.intValue(stream["controlPort"]),
              remoteControlPortValue > 0, remoteControlPortValue <= 65_535,
              let remoteControlPort = NWEndpoint.Port(rawValue: UInt16(remoteControlPortValue)),
              case let .hostPort(host, _) = controlConnection.endpoint else {
            appendProtocolLine("AirPlay audio resend: sender controlPort unavailable")
            return
        }

        let generation = sessionGeneration
        let resendConnection = NWConnection(host: host, port: remoteControlPort, using: .udp)
        audioResendConnection = resendConnection
        audioResendGeneration = generation
        resendConnection.stateUpdateHandler = { [weak self, weak resendConnection] state in
            guard let self, let resendConnection, generation == self.sessionGeneration else { return }
            switch state {
            case .ready:
                self.appendProtocolLine("AirPlay audio resend control → \(host):\(remoteControlPortValue)")
                self.receiveAudioResendDatagrams(on: resendConnection, generation: generation)
            case .failed(let error):
                DispatchQueue.main.async { [weak self] in
                    self?.diagnostics.addEvent(
                        "AirPlay audio resend control: \(error.localizedDescription)",
                        level: .warning
                    )
                }
            default:
                break
            }
        }
        resendConnection.start(queue: networkQueue)
    }

    private func sendAudioResendRequest(first: UInt16, count: UInt16) {
        guard count > 0,
              let connection = audioResendConnection,
              audioResendGeneration == sessionGeneration else { return }

        let requestSequence = audioResendRequestSequence
        audioResendRequestSequence &+= 1
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = 0x80
        bytes[1] = 0xD5 // Apple range-resend request (0x55 with marker bit).
        bytes[2] = UInt8(requestSequence >> 8)
        bytes[3] = UInt8(requestSequence & 0xFF)
        bytes[4] = UInt8(first >> 8)
        bytes[5] = UInt8(first & 0xFF)
        bytes[6] = UInt8(count >> 8)
        bytes[7] = UInt8(count & 0xFF)

        diagnostics.recordAirPlayAudioResendRequest()
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let error {
                DispatchQueue.main.async {
                    self?.diagnostics.addEvent(
                        "AirPlay audio resend request: \(error.localizedDescription)",
                        level: .warning
                    )
                }
            }
        })
    }

    private func receiveAudioResendDatagrams(on connection: NWConnection, generation: UInt64) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, generation == self.sessionGeneration else { return }

            if let data, !data.isEmpty, AirPlayRTPAudioPacket.isSyncDatagram(data) {
                self.recordAudioSync(data)
            }
            if let data, !data.isEmpty, AirPlayRTPAudioPacket.isAudioMediaDatagram(data) {
                self.updateHotTelemetry { telemetry in
                    telemetry.audioPacketsReceived &+= 1
                    telemetry.audioBytesReceived &+= UInt64(data.count)
                }
                if AirPlayRTPAudioPacket.isRetransmissionDatagram(data) {
                    self.diagnostics.recordAirPlayAudioRetransmittedPacket()
                }
                let key = self.sessionAudioKey
                let iv = self.sessionAudioIV
                self.audioTransportQueue.async { [weak self] in
                    self?.processRealtimeAudioDatagram(
                        data,
                        sessionKey: key,
                        iv: iv,
                        generation: generation
                    )
                }
            }

            if let error {
                DispatchQueue.main.async { [weak self] in
                    self?.diagnostics.addEvent(
                        "AirPlay audio resend receive: \(error.localizedDescription)",
                        level: .warning
                    )
                }
                return
            }
            self.receiveAudioResendDatagrams(on: connection, generation: generation)
        }
    }

    private func acceptAudioUDPConnection(_ connection: NWConnection, isControl: Bool) {
        let id = UUID()
        if isControl {
            audioControlConnections[id] = connection
        } else {
            audioDataConnections[id] = connection
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveAudioUDP(id: id, connection: connection, isControl: isControl)
            case .failed(let error):
                DispatchQueue.main.async {
                    self.diagnostics.addEvent(
                        "AirPlay audio UDP: \(error.localizedDescription)",
                        level: .warning
                    )
                }
                if isControl {
                    self.audioControlConnections.removeValue(forKey: id)
                } else {
                    self.audioDataConnections.removeValue(forKey: id)
                }
            case .cancelled:
                if isControl {
                    self.audioControlConnections.removeValue(forKey: id)
                } else {
                    self.audioDataConnections.removeValue(forKey: id)
                }
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }

    /// RTP sync (PT 0x54): bytes 4-7 RTP time that maps to the NTP time in bytes 8-15;
    /// bytes 16-19 are that RTP time plus the sender's intended latency.
    private func recordAudioSync(_ data: Data) {
        guard data.count >= 20 else { return }
        let syncRTP = AirPlayRTPAudioPacket.bigEndianUInt32(data, offset: 4)
        let ntpWhole = Double(AirPlayRTPAudioPacket.bigEndianUInt32(data, offset: 8))
        let ntpFraction = Double(AirPlayRTPAudioPacket.bigEndianUInt32(data, offset: 12)) / 4_294_967_296
        let nextRTP = AirPlayRTPAudioPacket.bigEndianUInt32(data, offset: 16)
        let point = AudioSyncPoint(
            rtp: syncRTP,
            ntpSeconds: ntpWhole + ntpFraction,
            latencySamples: nextRTP &- syncRTP
        )
        audioSyncPoint = point
        let latencyMS = Double(point.latencySamples) / audioSyncSampleRate * 1_000
        updateHotTelemetry { telemetry in
            telemetry.audioSyncPackets &+= 1
            telemetry.audioSenderLatencyMS = latencyMS < 10_000 ? latencyMS : nil
        }
    }

    private func recordAudioArrival(_ data: Data, at arrival: TimeInterval) {
        guard let sync = audioSyncPoint,
              let rtp = AirPlayRTPAudioPacket.mediaTimestamp(data) else { return }
        let delta = Double(Int32(bitPattern: rtp &- sync.rtp)) / audioSyncSampleRate
        // Audio sync uses the NTP epoch (1900); mirror video timestamps have been
        // observed without it. Track both and keep whichever matches video.
        audioArrivalFloorNTPEpoch.push(arrival - (sync.ntpSeconds - 2_208_988_800 + delta), at: arrival)
        audioArrivalFloorRaw.push(arrival - (sync.ntpSeconds + delta), at: arrival)
        guard let video = videoArrivalFloor.minimum else { return }
        let candidates = [audioArrivalFloorNTPEpoch.minimum, audioArrivalFloorRaw.minimum]
            .compactMap { $0 }
            .map { ($0 - video) * 1_000 }
            .filter { abs($0) < 10_000 }
        guard let skew = candidates.first else { return }
        updateHotTelemetry { $0.audioVideoArrivalSkewMS = skew }
    }

    private func processRealtimeAudioDatagram(
        _ datagram: Data,
        sessionKey key: Data?,
        iv: Data?,
        generation: UInt64
    ) {
        guard generation == sessionGeneration else { return }
        guard let packet = AirPlayRTPAudioPacket.parse(datagram) else { return }

        // Apple uses this four-byte AAC-ELD marker for silence/no-media. It is too
        // short to be encrypted and it carries a real RTP sequence number: dropping it
        // here (0.3.45–0.3.49) made every quiet moment look like a long packet loss.
        if packet.payload == Data([0x00, 0x68, 0x34, 0x00]) {
            audioPlayer.enqueueSilenceMarker(rtpTimestamp: packet.timestamp, sequence: packet.sequence)
            return
        }

        guard let key, key.count == 16, let iv, iv.count == 16 else {
            let failures = incrementAudioDecryptFailures()
            if failures == 1 {
                diagnostics.addEvent(
                    "AirPlay audio RTP пришёл раньше AES key/IV.",
                    level: .warning
                )
            }
            return
        }

        do {
            let clearPayload = try fairPlay.decryptAudioCBC(
                packet.payload,
                sessionKey: key,
                iv: iv
            )
            updateHotTelemetry { $0.audioDecryptedPackets &+= 1 }
            audioPlayer.enqueueAACELD(
                clearPayload,
                rtpTimestamp: packet.timestamp,
                sequence: packet.sequence
            )
        } catch {
            let failures = incrementAudioDecryptFailures()
            if failures <= 3 {
                diagnostics.addEvent(
                    "AirPlay audio AES-CBC: \(error.localizedDescription)",
                    level: .warning
                )
            }
        }
    }

    private func receiveAudioUDP(id: UUID, connection: NWConnection, isControl: Bool) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                let isAudioMedia = AirPlayRTPAudioPacket.isAudioMediaDatagram(data)
                if !isAudioMedia, AirPlayRTPAudioPacket.isSyncDatagram(data) {
                    self.recordAudioSync(data)
                }
                if isAudioMedia {
                    self.updateHotTelemetry { telemetry in
                        telemetry.audioPacketsReceived &+= 1
                        telemetry.audioBytesReceived &+= UInt64(data.count)
                    }
                    if !isControl {
                        self.recordAudioArrival(data, at: ProcessInfo.processInfo.systemUptime)
                    }
                    if isControl, AirPlayRTPAudioPacket.isRetransmissionDatagram(data) {
                        self.diagnostics.recordAirPlayAudioRetransmittedPacket()
                    }
                    let key = self.sessionAudioKey
                    let iv = self.sessionAudioIV
                    let generation = self.sessionGeneration
                    self.audioTransportQueue.async { [weak self] in
                        self?.processRealtimeAudioDatagram(
                            data,
                            sessionKey: key,
                            iv: iv,
                            generation: generation
                        )
                    }
                }
            }

            if let error {
                let stillTracked = isControl
                    ? self.audioControlConnections[id] != nil
                    : self.audioDataConnections[id] != nil
                if stillTracked {
                    DispatchQueue.main.async {
                        self.diagnostics.addEvent(
                            "AirPlay audio UDP receive: \(error.localizedDescription)",
                            level: .warning
                        )
                    }
                }
                if isControl {
                    self.audioControlConnections.removeValue(forKey: id)
                } else {
                    self.audioDataConnections.removeValue(forKey: id)
                }
                return
            }

            self.receiveAudioUDP(id: id, connection: connection, isControl: isControl)
        }
    }

    private func parseMirrorPackets(from buffer: inout Data) {
        let headerSize = 128
        let maximumPayload = Self.maximumMirrorPayloadBytes

        if buffer.count > maximumMirrorBufferedBytes {
            let dropped = buffer.count - headerSize
            let prefix = Self.hexPrefix(buffer, bytes: 64)
            buffer.removeSubrange(0..<dropped)
            reportMirrorDesync(discardedBytes: dropped, prefix: prefix, reason: "buffer cap")
        }

        // 0.3.32 removed bytes from the front of Data for every individual video
        // packet. At 1080p60 this repeatedly memmoves/allocates a hot TCP buffer.
        // Walk with a cursor and compact once after the whole receive callback.
        var cursor = 0

        while buffer.count - cursor >= headerSize {
            // In-sequence headers are trusted by their length (TCP keeps the framing);
            // only the resync scan below uses the strict subtype/option whitelist.
            guard let header = Self.mirrorHeader(in: buffer, at: cursor),
                  Self.isPlausibleMirrorHeader(header, maximumPayload: maximumPayload, strict: false) else {
                // Framing recovery is exceptional. Compact already-consumed bytes
                // first, then reuse the proven 0-offset resync path.
                if cursor > 0 {
                    buffer.removeSubrange(0..<cursor)
                    cursor = 0
                }

                if let offset = Self.findNextPlausibleMirrorHeader(
                    in: buffer,
                    headerSize: headerSize,
                    maximumPayload: maximumPayload,
                    scanLimit: min(buffer.count - headerSize + 1, 64 * 1024)
                ), offset > 0 {
                    let prefix = Self.hexPrefix(buffer, bytes: 64)
                    buffer.removeSubrange(0..<offset)
                    reportMirrorDesync(discardedBytes: offset, prefix: prefix, reason: "resync")
                    continue
                }

                let keep = min(headerSize - 1, buffer.count)
                let discard = buffer.count - keep
                guard discard > 0 else { break }
                let prefix = Self.hexPrefix(buffer, bytes: 64)
                buffer.removeSubrange(0..<discard)
                reportMirrorDesync(discardedBytes: discard, prefix: prefix, reason: "unknown framing")
                return
            }

            let packetSize = headerSize + header.payloadSize
            guard packetSize >= headerSize else {
                buffer.removeAll(keepingCapacity: true)
                reportMirrorDesync(
                    discardedBytes: headerSize,
                    prefix: "overflow",
                    reason: "size overflow"
                )
                return
            }
            guard buffer.count - cursor >= packetSize else { break }

            let payloadStart = cursor + headerSize
            let payloadEnd = cursor + packetSize
            let payload = header.payloadSize > 0
                ? buffer.subdata(in: payloadStart..<payloadEnd)
                : Data()
            cursor += packetSize

switch header.payloadType {
            case 0:
                // AirPlay mirror video payload. byte[5] is a subtype/IDR flag
                // (0x10 is commonly seen on the first IDR after avcC). The
                // payload itself is AES-CTR encrypted and remains AVCC-length-
                // prefixed after decryption.
                if !(header.payloadSubtype == 0x00 || header.payloadSubtype == 0x10)
                    || !(header.payloadOption == 0x0000 || header.payloadOption == 0x0006) {
                    unusualMirrorVideoHeaders &+= 1
                    let count = unusualMirrorVideoHeaders
                    if count <= 4 || (count & (count - 1)) == 0 {
                        appendProtocolLine(
                            "MIRROR video subtype=0x\(String(format: "%02X", header.payloadSubtype)) " +
                            "option=0x\(String(format: "%04X", header.payloadOption)) accepted by length (#\(count))"
                        )
                    }
                }
                let packetArrival = ProcessInfo.processInfo.systemUptime
                if header.timestampRaw != 0 {
                    let remoteSeconds = Double(Self.mirrorTimestampNanoseconds(header.timestampRaw)) / 1_000_000_000
                    videoArrivalFloor.push(packetArrival - remoteSeconds, at: packetArrival)
                }
                let previousVideoArrival = hotTelemetrySnapshot().lastVideoPacketArrivalHostTime
                let resumeGapMS = previousVideoArrival > 0
                    ? (packetArrival - previousVideoArrival) * 1_000
                    : 0
                updateHotTelemetry { telemetry in
                    telemetry.mirrorVideoPackets &+= 1
                    if telemetry.lastVideoPacketArrivalHostTime > 0 {
                        let gapMS = (packetArrival - telemetry.lastVideoPacketArrivalHostTime) * 1_000
                        telemetry.videoPacketMaxGapMS = max(telemetry.videoPacketMaxGapMS, gapMS)
                        if gapMS > 25 { telemetry.videoPacketGapsOver25MS &+= 1 }
                        if gapMS > 50 { telemetry.videoPacketGapsOver50MS &+= 1 }
                        if gapMS > 100 { telemetry.videoPacketGapsOver100MS &+= 1 }
                    }
                    telemetry.lastVideoPacketArrivalHostTime = packetArrival
                }

                // A real device lock/sleep normally pauses screen video for seconds,
                // not hundreds of milliseconds. Re-anchor only after a >=2 s silence;
                // short app/encoder gaps must never disturb the presentation clock.
                if resumeGapMS >= 2_000 {
                    videoTimestampOriginNanoseconds = nil
                    videoDecodeSequence = 0
                    presentationStore.clear()
                    DispatchQueue.main.async { [weak self] in
                        self?.diagnostics.addEvent(
                            "AirPlay video: после длинной паузы \(Int(resumeGapMS.rounded())) ms timeline переякорен после wake."
                        )
                    }
                }

                guard fairPlay.isVideoCryptoReady else {
                    let failures = incrementVideoDecryptFailures()
                    if failures == 1 {
                        diagnostics.addEvent(
                            "AirPlay video packet получен, но AES-CTR ещё не готов.",
                            level: .warning
                        )
                    }
                    continue
                }

                do {
                    let decrypted = try fairPlay.decryptVideo(payload)
                    let prefix = Self.hexPrefix(decrypted, bytes: 32)
                    updateHotTelemetry { $0.videoDecryptedPackets &+= 1 }
                    if mirrorFirstVideoPrefix == "—" {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.mirrorFirstVideoPrefix == "—" else { return }
                            self.mirrorFirstVideoPrefix = prefix
                            self.diagnostics.addEvent(
                                "AirPlay: первый расшифрованный video packet \(decrypted.count) B"
                            )
                        }
                    }

                    let pts: CMTime
                    if header.timestampRaw != 0 {
                        let remoteNanoseconds = Self.mirrorTimestampNanoseconds(header.timestampRaw)
                        if videoTimestampOriginNanoseconds == nil {
                            videoTimestampOriginNanoseconds = remoteNanoseconds
                        }
                        let origin = videoTimestampOriginNanoseconds ?? remoteNanoseconds
                        let relativeNanoseconds = remoteNanoseconds >= origin
                            ? remoteNanoseconds - origin
                            : 0
                        pts = CMTime(
                            value: Int64(clamping: relativeNanoseconds),
                            timescale: 1_000_000_000
                        )
                        diagnostics.recordAirPlaySourceFrame(
                            pts: pts,
                            arrivalHostTime: ProcessInfo.processInfo.systemUptime
                        )
                    } else {
                        // Defensive fallback for nonstandard clients without the
                        // documented NTP timestamp. Modern iOS/iPadOS uses NTP.
                        pts = CMTime(value: videoDecodeSequence, timescale: 60)
                    }
                    videoDecodeSequence &+= 1
                    videoDecoder.decode(
                        accessUnit: decrypted,
                        presentationTime: pts,
                        generation: sessionGeneration
                    )
                } catch {
                    let failures = incrementVideoDecryptFailures()
                    if failures <= 4 || (failures & (failures - 1)) == 0 {
                        diagnostics.addEvent(
                            "AirPlay video decrypt: \(error.localizedDescription)",
                            level: .warning
                        )
                    }
                }

            case 1:
                // SPS/PPS codec configuration is intentionally *not* encrypted.
                let summary = Self.describeVideoCodecConfiguration(payload)
                let prefix = Self.hexPrefix(payload, bytes: 48)
                appendProtocolLine(
                    "MIRROR codec type=1 option=0x\(String(format: "%04X", header.payloadOption)) " +
                    "payload=\(payload.count)B \(summary) prefix=\(prefix)"
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.mirrorCodecPackets &+= 1
                    self.mirrorCodecSummary = summary
                }

                videoDecoder.configure(codecConfig: payload, generation: sessionGeneration)
                DispatchQueue.main.async { [weak self] in
                    self?.diagnostics.addEvent(
                        "AirPlay mirror parser: codec config \(summary)"
                    )
                }

            case 2:
                DispatchQueue.main.async { [weak self] in
                    self?.mirrorHeartbeatPackets &+= 1
                }

            case 5:
                // Current senders periodically send an unencrypted streaming
                // performance report. It is control telemetry, not a video frame.
                break

            default:
                break
            }

        }

        if cursor > 0 {
            buffer.removeSubrange(0..<cursor)
        }
    }

    private func reportMirrorDesync(
        discardedBytes: Int,
        prefix: String,
        reason: String
    ) {
        mirrorDesyncReports &+= 1
        let reportNumber = mirrorDesyncReports
        let shouldLog = reportNumber <= 4 || (reportNumber & (reportNumber - 1)) == 0
        if shouldLog {
            appendProtocolLine(
                "MIRROR framing \(reason): discarded=\(discardedBytes)B prefix64=\(prefix)"
            )
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mirrorMalformedPackets &+= 1
            if shouldLog {
                self.diagnostics.addEvent(
                    "AirPlay mirror framing: отброшено \(discardedBytes) B",
                    level: .warning
                )
            }
        }
    }

    private struct MirrorHeader {
        let payloadSize: Int
        let payloadType: UInt8
        let payloadSubtype: UInt8
        let payloadOption: UInt16
        let timestampRaw: UInt64
    }

    private static func mirrorTimestampNanoseconds(_ raw: UInt64) -> UInt64 {
        let seconds = raw >> 32
        let fraction = raw & 0xFFFF_FFFF
        let fractionalNanoseconds = (fraction * 1_000_000_000) >> 32
        return seconds &* 1_000_000_000 &+ fractionalNanoseconds
    }

    private static func mirrorHeader(in data: Data, at offset: Int) -> MirrorHeader? {
        guard offset >= 0, data.count >= offset + 16 else { return nil }
        return data.withUnsafeBytes { raw -> MirrorHeader? in
            guard raw.count >= offset + 16 else { return nil }
            let b = raw.bindMemory(to: UInt8.self)
            let payloadSize = Int(
                UInt32(b[offset])
                | (UInt32(b[offset + 1]) << 8)
                | (UInt32(b[offset + 2]) << 16)
                | (UInt32(b[offset + 3]) << 24)
            )
            let payloadType = b[offset + 4]
            let payloadSubtype = b[offset + 5]
            let payloadOption = UInt16(b[offset + 6]) | (UInt16(b[offset + 7]) << 8)

            var timestamp: UInt64 = 0
            for index in 0..<8 {
                timestamp |= UInt64(b[offset + 8 + index]) << UInt64(index * 8)
            }

            return MirrorHeader(
                payloadSize: payloadSize,
                payloadType: payloadType,
                payloadSubtype: payloadSubtype,
                payloadOption: payloadOption,
                timestampRaw: timestamp
            )
        }
    }

    /// `strict == false` is used for headers that follow a complete packet in the TCP
    /// stream. There the length field is authoritative, so every known packet type is
    /// accepted with any subtype/option: rejecting an unfamiliar video subtype would
    /// discard an encrypted payload, and skipping even one video payload shifts the
    /// AES-CTR keystream for every following frame (permanent garbage until re-SETUP).
    /// `strict == true` keeps the whitelist for the byte-by-byte resync scan, where a
    /// random match inside encrypted data must stay unlikely.
    private static func isPlausibleMirrorHeader(
        _ header: MirrorHeader,
        maximumPayload: Int,
        strict: Bool = true
    ) -> Bool {
        guard header.payloadSize >= 0, header.payloadSize <= maximumPayload else {
            return false
        }

        if !strict {
            switch header.payloadType {
            case 0, 1:
                return header.payloadSize > 0
            case 2, 5:
                return true
            default:
                return false
            }
        }

        switch header.payloadType {
        case 0:
            // encrypted H.264/HEVC video packet
            return (header.payloadSubtype == 0x00 || header.payloadSubtype == 0x10)
                && (header.payloadOption == 0x0000 || header.payloadOption == 0x0006)
                && header.payloadSize > 0

        case 1:
            // unencrypted codec/configuration packet.
            let option = header.payloadOption
            let knownOption = option == 0x0116
                || option == 0x0156
                || option == 0x011E
                || option == 0x015E
                || option == 0x0006
            return header.payloadSubtype == 0x00
                && knownOption
                && header.payloadSize > 0

        case 2:
            // old-protocol once-per-second heartbeat.
            return header.payloadSubtype == 0x00
                && (header.payloadOption == 0x001E || header.payloadOption == 0x0000)

        case 5:
            // streaming performance report.
            return header.payloadSubtype == 0x00
                && header.payloadOption == 0x0000

        default:
            return false
        }
    }

    private static func findNextPlausibleMirrorHeader(
        in data: Data,
        headerSize: Int,
        maximumPayload: Int,
        scanLimit: Int
    ) -> Int? {
        guard scanLimit > 1 else { return nil }
        let upper = min(scanLimit, data.count - headerSize + 1)
        guard upper > 1 else { return nil }

        for offset in 1..<upper {
            guard let header = mirrorHeader(in: data, at: offset) else { break }
            if isPlausibleMirrorHeader(header, maximumPayload: maximumPayload) {
                return offset
            }
        }
        return nil
    }

    private func compactStreamDescription(_ stream: [String: Any]) -> String {
        let keys = [
            "type", "audioFormat", "audioMode", "ct", "spf",
            "latencyMin", "latencyMax", "redundantAudio", "controlPort", "streamConnectionID"
        ]
        return keys.compactMap { key in
            guard let value = stream[key] else { return nil }
            return "\(key)=\(value)"
        }.joined(separator: " ")
    }

    private static func littleEndianUInt16(_ data: Data, offset: Int) -> UInt16 {
        guard data.count >= offset + 2 else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func hexPrefix(_ data: Data, bytes: Int) -> String {
        data.prefix(bytes).map { String(format: "%02X", $0) }.joined()
    }

    private static func extractHVCCFromSampleEntry(_ data: Data) -> Data? {
        guard data.count >= 16 else { return nil }

        func be32(_ offset: Int) -> Int? {
            guard data.count >= offset + 4 else { return nil }
            return (Int(data[offset]) << 24)
                | (Int(data[offset + 1]) << 16)
                | (Int(data[offset + 2]) << 8)
                | Int(data[offset + 3])
        }

        let topSize = be32(0) ?? 0
        let type = String(bytes: data[4..<8], encoding: .ascii)
        guard (type == "hvc1" || type == "hev1"),
              topSize >= 8,
              topSize <= data.count else { return nil }

        let marker = Array("hvcC".utf8)
        guard data.count >= 12 else { return nil }
        for typeOffset in 8...(data.count - 4) {
            guard data[typeOffset] == marker[0],
                  data[typeOffset + 1] == marker[1],
                  data[typeOffset + 2] == marker[2],
                  data[typeOffset + 3] == marker[3],
                  typeOffset >= 4 else { continue }

            let boxStart = typeOffset - 4
            guard let boxSize = be32(boxStart),
                  boxSize >= 8,
                  boxStart + boxSize <= min(topSize, data.count) else { continue }
            return data.subdata(in: (typeOffset + 4)..<(boxStart + boxSize))
        }
        return nil
    }

    private static func describeVideoCodecConfiguration(_ data: Data) -> String {
        let normalized: Data
        let wrapper: String?
        if let extracted = extractHVCCFromSampleEntry(data) {
            normalized = extracted
            wrapper = "hvc1"
        } else {
            normalized = data
            wrapper = nil
        }

        if normalized.count >= 23, normalized.first == 1 {
            let numArrays = Int(normalized[22])
            var offset = 23
            var hasVPS = false
            var hasSPS = false
            var hasPPS = false
            var valid = numArrays > 0
            for _ in 0..<numArrays {
                guard normalized.count >= offset + 3 else { valid = false; break }
                let nalType = Int(normalized[offset] & 0x3F)
                let count = (Int(normalized[offset + 1]) << 8) | Int(normalized[offset + 2])
                offset += 3
                for _ in 0..<count {
                    guard normalized.count >= offset + 2 else { valid = false; break }
                    let length = (Int(normalized[offset]) << 8) | Int(normalized[offset + 1])
                    offset += 2
                    guard length > 0, normalized.count >= offset + length else { valid = false; break }
                    offset += length
                }
                if !valid { break }
                if nalType == 32 { hasVPS = true }
                if nalType == 33 { hasSPS = true }
                if nalType == 34 { hasPPS = true }
            }
            if valid && hasSPS && hasPPS {
                let nalLengthBytes = Int(normalized[21] & 0x03) + 1
                return "\(wrapper == nil ? "hvcC" : "hvc1→hvcC") HEVC nalLen=\(nalLengthBytes) arrays=\(numArrays) VPS=\(hasVPS ? 1 : 0) SPS=1 PPS=1"
            }
        }
        return describeAVCConfiguration(data)
    }

    private static func describeAVCConfiguration(_ data: Data) -> String {
        guard data.count >= 7, data[0] == 1 else {
            return "avcC? \(data.count)B"
        }

        let profile = data[1]
        let compatibility = data[2]
        let level = data[3]
        let nalLengthBytes = Int(data[4] & 0x03) + 1
        let spsCount = Int(data[5] & 0x1F)

        return "avcC profile=\(profile) compat=\(compatibility) level=\(level) nalLen=\(nalLengthBytes) sps=\(spsCount)"
    }

    private func decodeBinaryPlist(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private func makeBinaryPlist(_ object: [String: Any]) -> Data {
        (try? PropertyListSerialization.data(
            fromPropertyList: object,
            format: .binary,
            options: 0
        )) ?? Data()
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func uint64Value(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? Int, value >= 0 {
            return UInt64(value)
        }
        if let value = value as? String {
            return UInt64(value)
        }
        return nil
    }

    private func updateHotTelemetry(_ body: (inout HotTelemetry) -> Void) {
        telemetryLock.lock()
        body(&hotTelemetry)
        telemetryLock.unlock()
    }

    private func hotTelemetrySnapshot() -> HotTelemetry {
        telemetryLock.lock()
        let snapshot = hotTelemetry
        telemetryLock.unlock()
        return snapshot
    }

    private func resetHotTelemetry() {
        telemetryLock.lock()
        hotTelemetry = HotTelemetry()
        telemetryLock.unlock()
    }

    @discardableResult
    private func incrementAudioDecryptFailures() -> UInt64 {
        telemetryLock.lock()
        hotTelemetry.audioDecryptFailures &+= 1
        let result = hotTelemetry.audioDecryptFailures
        telemetryLock.unlock()
        return result
    }

    @discardableResult
    private func incrementVideoDecryptFailures() -> UInt64 {
        telemetryLock.lock()
        hotTelemetry.videoDecryptFailures &+= 1
        let result = hotTelemetry.videoDecryptFailures
        telemetryLock.unlock()
        return result
    }

    private func startTelemetryPublisher() {
        let timer = DispatchSource.makeTimerSource(queue: telemetryQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(100),
            repeating: .milliseconds(250),
            leeway: .milliseconds(40)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let hot = self.hotTelemetrySnapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.mirrorBytesReceived = hot.mirrorBytesReceived
                self.mirrorVideoPackets = hot.mirrorVideoPackets
                self.audioPacketsReceived = hot.audioPacketsReceived
                self.audioBytesReceived = hot.audioBytesReceived
                self.audioDecryptedPackets = hot.audioDecryptedPackets
                self.audioDecryptFailures = hot.audioDecryptFailures
                self.audioQueueLeadMS = hot.audioQueueLeadMS
                self.audioRTPSequenceGaps = hot.audioRTPSequenceGaps
                self.audioRTPRedundantPackets = hot.audioRTPRedundantPackets
                self.videoDecryptedPackets = hot.videoDecryptedPackets
                self.videoDecryptFailures = hot.videoDecryptFailures
                self.videoDecodedFrames = hot.videoDecodedFrames
                self.hasLiveVideo = hot.hasLiveVideo
            }
        }
        telemetryTimer = timer
        timer.resume()
    }

    private static func unsignedIntegerString(_ value: Any) -> String {
        if let number = value as? NSNumber {
            return String(number.uint64Value)
        }
        if let value = value as? UInt64 {
            return String(value)
        }
        if let value = value as? Int {
            return String(UInt64(bitPattern: Int64(value)))
        }
        return String(describing: value)
    }

    private func appendProtocolLine(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.protocolLines.append(line)
            if self.protocolLines.count > 400 {
                self.protocolLines.removeFirst(self.protocolLines.count - 400)
            }
        }
    }

    private func send(response: Data, over connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            if let error {
                DispatchQueue.main.async {
                    self?.diagnostics.addEvent("AirPlay send: \(error.localizedDescription)", level: .warning)
                }
            }
        })
    }

    private func makeInfoPlist() -> Data {
        let displayUUID = UUID().uuidString
        let request = currentVideoRequest
        let requestedWidth = request.width
        let requestedHeight = request.height
        let requestedFPS = preferredFrameRate.rawValue
        let object: [String: Any] = [
            "sourceVersion": "220.68",
            "statusFlags": 4,
            "macAddress": identity.deviceID,
            "deviceID": identity.deviceID,
            "name": receiverName,
            "vv": 2,
            "keepAliveLowPower": 1,
            "keepAliveSendStatsAsBody": 1,
            "pi": identity.publicIdentifier,
            "model": "AppleTV3,2",
            "features": NSNumber(value: featureBits),
            "displays": [[
                "height": requestedHeight,
                "width": requestedWidth,
                "rotation": false,
                "widthPixels": requestedWidth,
                "heightPixels": requestedHeight,
                "refreshRate": requestedFPS,
                "features": 14,
                "maxFPS": requestedFPS,
                "overscanned": false,
                "uuid": displayUUID
            ]],
            "audioFormats": [[
                "audioOutputFormats": 33_554_428,
                "type": 100,
                "audioInputFormats": 33_554_428
            ], [
                "audioOutputFormats": 33_554_428,
                "type": 101,
                "audioInputFormats": 33_554_428
            ]],
            "audioLatencies": [[
                "audioType": "default",
                "inputLatencyMicros": 0,
                "outputLatencyMicros": 0,
                "type": 100
            ], [
                "audioType": "default",
                "inputLatencyMicros": 0,
                "outputLatencyMicros": 0,
                "type": 101
            ]]
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)) ?? Data()
    }

    private func makeServerInfoPlist() -> Data {
        let object: [String: Any] = [
            "deviceid": identity.deviceID,
            "features": NSNumber(value: featureBits),
            "model": "AppleTV3,2",
            "protovers": "1.0",
            "srcvers": "220.68"
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)) ?? Data()
    }

    private func makeStreamXML() -> Data {
        let requestedFPS = Double(preferredFrameRate.rawValue)
        let request = currentVideoRequest
        let object: [String: Any] = [
            "height": request.height,
            "overscanned": false,
            "refreshRate": 1.0 / requestedFPS,
            "version": "220.68",
            "width": request.width
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)) ?? Data()
    }
}

private struct AirPlayRTPAudioPacket {
    let sequence: UInt16
    let timestamp: UInt32
    let payloadType: UInt8
    let payload: Data

    static func isRetransmissionDatagram(_ data: Data) -> Bool {
        data.count >= 2 && (data[0] >> 6) == 2 && (data[1] & 0x7F) == 86
    }

    static func isSyncDatagram(_ data: Data) -> Bool {
        data.count >= 20 && (data[0] >> 6) == 2 && (data[1] & 0x7F) == 0x54
    }

    /// RTP timestamp of an original (PT 96) media datagram; resends are ignored.
    static func mediaTimestamp(_ data: Data) -> UInt32? {
        guard data.count >= 12, (data[0] >> 6) == 2, (data[1] & 0x7F) == 96 else { return nil }
        return bigEndianUInt32(data, offset: 4)
    }

    static func isAudioMediaDatagram(_ data: Data) -> Bool {
        guard data.count >= 2, (data[0] >> 6) == 2 else { return false }
        let outerType = data[1] & 0x7F
        return outerType == 96 || outerType == 86
    }

    static func parse(_ data: Data) -> AirPlayRTPAudioPacket? {
        guard data.count >= 12 else { return nil }
        let outerType = data[1] & 0x7F

        // Normal mirror AAC-ELD is PT 96. A requested retransmission arrives on
        // the RTP control channel as PT 86 and prepends four bytes before the
        // original RTP packet. Parsing PT 86 from offset zero (the old behavior)
        // corrupts sequence/timestamp/payload boundaries.
        if outerType == 86 {
            guard data.count >= 16 else { return nil }
            return parseRTP(data, base: 4)
        }
        guard outerType == 96 else { return nil }
        return parseRTP(data, base: 0)
    }

    private static func parseRTP(_ data: Data, base: Int) -> AirPlayRTPAudioPacket? {
        guard data.count >= base + 12 else { return nil }
        let first = data[base]
        guard (first >> 6) == 2 else { return nil }

        let hasPadding = (first & 0x20) != 0
        let hasExtension = (first & 0x10) != 0
        let csrcCount = Int(first & 0x0F)
        var payloadOffset = base + 12 + csrcCount * 4
        guard payloadOffset <= data.count else { return nil }

        if hasExtension {
            guard payloadOffset + 4 <= data.count else { return nil }
            let extensionWords = Int(bigEndianUInt16(data, offset: payloadOffset + 2))
            payloadOffset += 4 + extensionWords * 4
            guard payloadOffset <= data.count else { return nil }
        }

        var payloadEnd = data.count
        if hasPadding {
            guard let paddingByte = data.last else { return nil }
            let paddingCount = Int(paddingByte)
            guard paddingCount > 0, paddingCount <= payloadEnd - payloadOffset else { return nil }
            payloadEnd -= paddingCount
        }
        guard payloadEnd > payloadOffset else { return nil }

        return AirPlayRTPAudioPacket(
            sequence: bigEndianUInt16(data, offset: base + 2),
            timestamp: bigEndianUInt32(data, offset: base + 4),
            payloadType: data[base + 1] & 0x7F,
            payload: data.subdata(in: payloadOffset..<payloadEnd)
        )
    }

    private static func bigEndianUInt16(_ data: Data, offset: Int) -> UInt16 {
        guard data.count >= offset + 2 else { return 0 }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    static func bigEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}

private struct AirPlayIdentity {
    let deviceID: String
    let publicIdentifier: String
    let signingPublicKey: Data

    static func loadOrCreate(receiverName: String) -> AirPlayIdentity {
        let defaults = UserDefaults.standard
        let identityNamingVersionKey = "MirrorLab.AirPlay.IdentityNamingVersion"
        let lastReceiverNameKey = "MirrorLab.AirPlay.LastReceiverName"
        let currentNamingVersion = 2

        // Older builds advertised a development-friendly name. iOS/iPadOS can cache
        // the friendly name by AirPlay identity even after Bonjour is republished.
        // Rotate the public receiver identity once on migration (and again only when
        // the Mac's Computer Name actually changes) so the sender sees the new name.
        let previousName = defaults.string(forKey: lastReceiverNameKey)
        let needsIdentityRefresh = defaults.integer(forKey: identityNamingVersionKey) < currentNamingVersion
            || (previousName != nil && previousName != receiverName)
        if needsIdentityRefresh {
            defaults.removeObject(forKey: "MirrorLab.AirPlay.DeviceID")
            defaults.removeObject(forKey: "MirrorLab.AirPlay.PublicIdentifier")
        }
        defaults.set(currentNamingVersion, forKey: identityNamingVersionKey)
        defaults.set(receiverName, forKey: lastReceiverNameKey)

        let deviceID: String
        if let stored = defaults.string(forKey: "MirrorLab.AirPlay.DeviceID") {
            deviceID = stored
        } else {
            var bytes = [UInt8](repeating: 0, count: 6)
            let byteCount = bytes.count
            let randomStatus = bytes.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return errSecParam }
                return SecRandomCopyBytes(kSecRandomDefault, byteCount, baseAddress)
            }
            if randomStatus != errSecSuccess {
                bytes = Array(UUID().uuidString.utf8.prefix(6))
            }
            bytes[0] = (bytes[0] & 0xFE) | 0x02
            deviceID = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
            defaults.set(deviceID, forKey: "MirrorLab.AirPlay.DeviceID")
        }

        let publicIdentifier: String
        if let stored = defaults.string(forKey: "MirrorLab.AirPlay.PublicIdentifier") {
            publicIdentifier = stored
        } else {
            publicIdentifier = UUID().uuidString.lowercased()
            defaults.set(publicIdentifier, forKey: "MirrorLab.AirPlay.PublicIdentifier")
        }

        let privateKey: Curve25519.Signing.PrivateKey
        if let raw = defaults.data(forKey: "MirrorLab.AirPlay.SigningPrivateKey"),
           let loaded = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            privateKey = loaded
        } else {
            let created = Curve25519.Signing.PrivateKey()
            defaults.set(created.rawRepresentation, forKey: "MirrorLab.AirPlay.SigningPrivateKey")
            privateKey = created
        }

        return AirPlayIdentity(
            deviceID: deviceID,
            publicIdentifier: publicIdentifier,
            signingPublicKey: privateKey.publicKey.rawRepresentation
        )
    }
}

private struct AirPlayRequest {
    let method: String
    let target: String
    let version: String
    let headers: [String: String]
    let body: Data

    var route: String {
        if let components = URLComponents(string: target), !components.path.isEmpty {
            return components.path
        }
        if let schemeRange = target.range(of: "://"),
           let slash = target[schemeRange.upperBound...].firstIndex(of: "/") {
            return String(target[slash...].split(separator: "?", maxSplits: 1).first ?? Substring("/"))
        }
        return target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    }

    static func pop(from buffer: inout Data) -> AirPlayRequest? {
        let marker = Data([13, 10, 13, 10])
        guard let headerRange = buffer.range(of: marker) else { return nil }
        let headerEnd = headerRange.upperBound
        guard let headerText = String(data: buffer.subdata(in: 0..<headerRange.lowerBound), encoding: .utf8) else {
            buffer.removeSubrange(0..<headerEnd)
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let firstParts = first.split(separator: " ", maxSplits: 2).map(String.init)
        guard firstParts.count >= 3 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let totalLength = headerEnd + contentLength
        guard buffer.count >= totalLength else { return nil }
        let body = contentLength > 0
            ? buffer.subdata(in: headerEnd..<totalLength)
            : Data()
        buffer.removeSubrange(0..<totalLength)

        return AirPlayRequest(
            method: firstParts[0].uppercased(),
            target: firstParts[1],
            version: firstParts[2],
            headers: headers,
            body: body
        )
    }
}

private enum AirPlayResponse {
    static func ok(
        request: AirPlayRequest,
        contentType: String? = nil,
        body: Data = Data(),
        additionalHeaders: [String: String] = [:]
    ) -> Data {
        make(
            request: request,
            status: 200,
            reason: "OK",
            contentType: contentType,
            body: body,
            additionalHeaders: additionalHeaders
        )
    }

    static func badRequest(request: AirPlayRequest) -> Data {
        make(request: request, status: 400, reason: "Bad Request")
    }

    static func notImplemented(request: AirPlayRequest, stage: String) -> Data {
        make(
            request: request,
            status: 501,
            reason: "Not Implemented",
            additionalHeaders: ["X-MirrorLab-Stage": stage]
        )
    }

    static func serverError(request: AirPlayRequest) -> Data {
        make(request: request, status: 500, reason: "Internal Server Error")
    }

    private static func make(
        request: AirPlayRequest,
        status: Int,
        reason: String,
        contentType: String? = nil,
        body: Data = Data(),
        additionalHeaders: [String: String] = [:]
    ) -> Data {
        let protocolVersion = request.version.contains("/") ? request.version : "RTSP/1.0"
        var lines = [
            "\(protocolVersion) \(status) \(reason)",
            "CSeq: \(request.headers["cseq"] ?? "0")",
            "Server: AirTunes/220.68",
            "Date: \(Self.httpDate())",
            "Connection: keep-alive",
            "Audio-Jack-Status: Connected; type=digital",
            "Content-Length: \(body.count)"
        ]
        if let contentType {
            lines.append("Content-Type: \(contentType)")
        }
        for key in additionalHeaders.keys.sorted() {
            lines.append("\(key): \(additionalHeaders[key]!)")
        }
        lines.append("")
        lines.append("")
        var result = Data(lines.joined(separator: "\r\n").utf8)
        result.append(body)
        return result
    }

    private static func httpDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date())
    }
}

/// Sliding time-window minimum (monotonic deque) used for arrival-offset floors.
private struct ArrivalFloor {
    private var values: [(time: TimeInterval, value: Double)] = []
    private var head = 0
    let window: TimeInterval

    init(window: TimeInterval) {
        self.window = window
    }

    var minimum: Double? {
        head < values.count ? values[head].value : nil
    }

    mutating func push(_ value: Double, at time: TimeInterval) {
        while values.count > head, let last = values.last, last.value >= value {
            values.removeLast()
        }
        values.append((time: time, value: value))
        while head < values.count - 1 && values[head].time < time - window {
            head += 1
        }
        if head > 512 {
            values.removeFirst(head)
            head = 0
        }
    }

    mutating func reset() {
        values.removeAll(keepingCapacity: true)
        head = 0
    }
}
