import AppKit
import AVFoundation
import Combine
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

enum USBCapturePhase: String {
    case idle = "Остановлен"
    case discovering = "Поиск USB-экрана…"
    case requestingPermission = "Запрос разрешения…"
    case permissionDenied = "Требуется доступ"
    case configuring = "Подключение…"
    case running = "Идёт захват экрана"
    case failed = "Ошибка"
}

struct CaptureDeviceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
}

enum USBCaptureError: LocalizedError {
    case missingScreenDevice
    case cannotCreateInput(String)
    case cannotAddInput(String)
    case cannotAddVideoOutput

    var errorDescription: String? {
        switch self {
        case .missingScreenDevice:
            return "USB-экран iPhone/iPad не найден. Подключи кабель, разблокируй устройство, нажми «Доверять» и обнови список."
        case .cannotCreateInput(let name):
            return "Не удалось открыть USB-экран «\(name)». Закрой QuickTime и другие программы захвата."
        case .cannotAddInput(let name):
            return "USB-экран «\(name)» несовместим с текущей сессией захвата."
        case .cannotAddVideoOutput:
            return "Не удалось создать низколатентный видеовыход."
        }
    }
}

final class USBCaptureController: NSObject, ObservableObject {
    @Published private(set) var phase: USBCapturePhase = .idle
    @Published private(set) var screenDevices: [CaptureDeviceOption] = []
    @Published var selectedScreenDeviceID: String? {
        didSet {
            guard selectedScreenDeviceID != oldValue else { return }
            // When more than one wired iOS device is present, the picker is the only
            // manual step. Selecting one should immediately resume appliance-style
            // auto-connect without requiring a separate Start button.
            if automaticConnectionEnabled,
               !isManuallyPaused,
               !session.isRunning,
               phase == .idle,
               let selectedScreenDeviceID,
               screenDeviceByID[selectedScreenDeviceID] != nil {
                DispatchQueue.main.async { [weak self] in self?.start() }
            }
        }
    }
    @Published var playAudio = true
    @Published private(set) var activeFormatDescription = "—"
    @Published private(set) var audioPlaybackStatus = "—"
    @Published private(set) var audioQueueLeadMS: Double = 0
    @Published private(set) var audioFormatDescription = "—"
    @Published private(set) var actualVideoFormatDescription = "—"
    @Published private(set) var cmioSelectedFormatDescription = "—"
    @Published private(set) var cmioAvailableFormatDescriptions: [String] = []
    @Published private(set) var automaticConnectionEnabled = false
    @Published private(set) var isManuallyPaused = false
    @Published private(set) var cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var connectedDeviceName: String {
        optionName(for: selectedScreenDeviceID) ?? ""
    }

    /// Called when a running USB capture actually ends (explicit stop, cable/device
    /// disappearance, or AVFoundation runtime stop). The AppModel uses this only
    /// to retire a preview window that belongs to the finished USB transport.
    var onCaptureEnded: (() -> Void)?

    private let frameStore: LatestVideoFrameStore
    private let diagnostics: DiagnosticsStore
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "MirrorLab.USBScreenCaptureSession", qos: .userInteractive)
    private let videoQueue = DispatchQueue(label: "MirrorLab.USBScreenVideo", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "MirrorLab.USBScreenAudio", qos: .userInteractive)
    private lazy var audioPlayer = SampleBufferAudioPlayer(diagnostics: diagnostics)
    private lazy var videoDecoder = USBVideoSampleDecoder(frameStore: frameStore, diagnostics: diagnostics)
    private var screenDeviceByID: [String: AVCaptureDevice] = [:]
    private var runtimeErrorObserver: NSObjectProtocol?
    private var didStopRunningObserver: NSObjectProtocol?
    private var discoveryGeneration: UInt64 = 0
    private var observedVideoWidth = 0
    private var observedVideoHeight = 0
    private var observedVideoPixelFormat: OSType = 0
    private var automaticDiscoveryTimer: Timer?
    private var lastDiscoverySignature = ""
    private var didLogWaitingForDevice = false
    private var pendingSelectedScreenDeviceID: String?

    init(frameStore: LatestVideoFrameStore, diagnostics: DiagnosticsStore) {
        self.frameStore = frameStore
        self.diagnostics = diagnostics
        super.init()
        audioPlayer.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.audioPlaybackStatus = status }
        }
        audioPlayer.onQueueLead = { [weak self] lead in
            DispatchQueue.main.async { self?.audioQueueLeadMS = lead }
        }
        audioPlayer.onFormat = { [weak self] format in
            DispatchQueue.main.async { self?.audioFormatDescription = format }
        }
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self.phase = .failed
            self.diagnostics.addEvent(
                "Ошибка USB screen-сессии: \(error?.localizedDescription ?? "неизвестная ошибка")",
                level: .error
            )
            self.onCaptureEnded?()
        }
        didStopRunningObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStopRunningNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // This also covers a physical USB/device disappearance. Keep the UI in
            // appliance mode: close the finished preview, then let the discovery loop
            // find the same or another iPhone/iPad when it becomes available again.
            if self.phase == .running || self.phase == .configuring {
                self.phase = .idle
            }
            self.onCaptureEnded?()
            if self.automaticConnectionEnabled && !self.isManuallyPaused {
                self.scheduleAutomaticRefresh(after: 0.8)
            }
        }
    }

    deinit {
        automaticDiscoveryTimer?.invalidate()
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
        if let didStopRunningObserver {
            NotificationCenter.default.removeObserver(didStopRunningObserver)
        }
        stop()
    }

    var isRunning: Bool {
        session.isRunning
    }

    var reportDictionary: [String: Any] {
        [
            "backend": "coremediaio-ios-screen",
            "phase": phase.rawValue,
            "automatic_connection": automaticConnectionEnabled,
            "manually_paused": isManuallyPaused,
            "camera_authorization": Self.authorizationLabel(cameraAuthorizationStatus),
            "screen_device": optionName(for: selectedScreenDeviceID) ?? "",
            "play_audio": playAudio,
            "capture_format_policy": "AVCaptureVideoDataOutput device-native samples; CMIO native/preferred probe; VideoToolbox for compressed native samples",
            "active_format": activeFormatDescription,
            "actual_stream_format": actualVideoFormatDescription,
            "cmio_selected_format": cmioSelectedFormatDescription,
            "cmio_available_formats": cmioAvailableFormatDescriptions,
            "available_formats": availableFormatInventory(),
            "video_output_policy": "videoSettings={} (device-native)",
            "camera_privacy_classification": "macOS Camera permission bucket; MirrorLab selects only iPhone/iPad muxed screen devices, never the built-in Mac camera",
            "video_output_pixel_formats": videoOutput.availableVideoPixelFormatTypes.map { Self.fourCCString($0) },
            "video_output_codecs": videoOutput.availableVideoCodecTypes.map(\.rawValue),
            "usb_audio_backend": "CoreAudio DefaultOutput • direct PCM ring",
            "usb_audio_status": audioPlaybackStatus,
            "usb_audio_format": audioFormatDescription,
            "usb_audio_queue_lead_ms": audioQueueLeadMS,
            "usb_audio_runtime": audioPlayer.reportDictionary,
            "discovered_devices": screenDevices.map { ["name": $0.name, "id": $0.id, "type": $0.type] }
        ]
    }

    func setAutomaticConnectionEnabled(_ enabled: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.setAutomaticConnectionEnabled(enabled) }
            return
        }
        guard automaticConnectionEnabled != enabled else { return }
        automaticConnectionEnabled = enabled
        automaticDiscoveryTimer?.invalidate()
        automaticDiscoveryTimer = nil

        if enabled {
            isManuallyPaused = false
            didLogWaitingForDevice = false
            refreshCameraAuthorizationStatus()
            refreshDevices()
            let timer = Timer(timeInterval: 1.6, repeats: true) { [weak self] _ in
                self?.automaticDiscoveryTick()
            }
            RunLoop.main.add(timer, forMode: .common)
            automaticDiscoveryTimer = timer
        } else {
            pendingSelectedScreenDeviceID = nil
            isManuallyPaused = false
        }
    }

    func refreshDevices() {
        guard !session.isRunning,
              phase != .requestingPermission,
              phase != .configuring,
              phase != .discovering
        else { return }

        phase = .discovering
        discoveryGeneration &+= 1
        let generation = discoveryGeneration

        let status = enableIOSScreenCaptureDevices()
        if status != noErr {
            diagnostics.addEvent(
                "CoreMediaIO не включил iOS screen-capture devices (OSStatus \(status))",
                level: .warning
            )
        }

        // CoreMediaIO publishes the muxed screen device asynchronously after the
        // opt-in property changes. A short delay is cheaper than keeping a capture
        // session alive while no wired device exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, generation == self.discoveryGeneration else { return }
            self.discoverMuxedScreenDevices()
        }
    }

    private func automaticDiscoveryTick() {
        guard automaticConnectionEnabled,
              phase != .requestingPermission,
              phase != .configuring,
              phase != .discovering
        else { return }

        if session.isRunning {
            detectDeviceSetChangeWhileRunning()
        } else {
            refreshDevices()
        }
    }

    private func scheduleAutomaticRefresh(after delay: TimeInterval) {
        guard automaticConnectionEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.automaticConnectionEnabled else { return }
            self.refreshDevices()
        }
    }

    func setOutputVolume(_ volume: Float) {
        audioPlayer.setOutputVolume(volume)
    }

    func start() {
        guard phase != .configuring, !session.isRunning else { return }
        guard let deviceID = selectedScreenDeviceID, let device = screenDeviceByID[deviceID] else {
            phase = .failed
            diagnostics.addEvent(USBCaptureError.missingScreenDevice.localizedDescription, level: .error)
            return
        }

        phase = .requestingPermission
        diagnostics.resetCounters()
        actualVideoFormatDescription = "—"
        cmioSelectedFormatDescription = "—"
        cmioAvailableFormatDescriptions = []
        observedVideoWidth = 0
        observedVideoHeight = 0
        observedVideoPixelFormat = 0
        videoDecoder.reset()
        let includeAudio = playAudio

        guard Self.isLikelyIOSScreenDevice(device) else {
            phase = .failed
            diagnostics.addEvent(
                "USB source отклонён: MirrorLab разрешает только iPhone/iPad muxed screen devices и никогда не выбирает встроенную камеру Mac.",
                level: .error
            )
            return
        }

        let currentAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAuthorizationStatus = currentAuthorization
        if currentAuthorization == .denied || currentAuthorization == .restricted {
            phase = .permissionDenied
            diagnostics.addEvent(
                "USB: доступ Camera запрещён. macOS использует эту privacy-category для проводного screen capture iPhone/iPad; открой Privacy & Security → Camera, чтобы разрешить MirrorLab.",
                level: .warning
            )
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let videoAllowed = await Self.requestCameraAccess()
            await MainActor.run {
                self.cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
                guard videoAllowed else {
                    self.phase = .permissionDenied
                    self.diagnostics.addEvent(
                        "USB: доступ Camera не разрешён. MirrorLab не использует встроенную камеру Mac; это системная privacy-category для USB screen capture.",
                        level: .warning
                    )
                    return
                }
                self.configureAndStart(device: device, includeAudio: includeAudio)
            }
        }
    }

    func stop() {
        pendingSelectedScreenDeviceID = nil
        stopCaptureSession()
    }

    func pauseCurrentCapture() {
        isManuallyPaused = true
        pendingSelectedScreenDeviceID = nil
        stopCaptureSession()
    }

    func resumeAutomaticCapture() {
        guard automaticConnectionEnabled else { return }
        isManuallyPaused = false
        phase = .idle
        refreshCameraAuthorizationStatus()
        refreshDevices()
    }

    func selectScreenDevice(_ id: String) {
        guard screenDeviceByID[id] != nil else { return }
        isManuallyPaused = false
        if session.isRunning || phase == .configuring {
            pendingSelectedScreenDeviceID = id
            stopCaptureSession()
        } else {
            selectedScreenDeviceID = id
        }
    }

    func refreshCameraAuthorizationStatus() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAuthorizationStatus = status
        if status == .authorized, phase == .permissionDenied {
            phase = .idle
            if automaticConnectionEnabled && !isManuallyPaused {
                refreshDevices()
            }
        } else if status == .denied || status == .restricted {
            if !session.isRunning { phase = .permissionDenied }
        }
    }

    func openCameraPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }

    var cameraPermissionNeedsSettings: Bool {
        cameraAuthorizationStatus == .denied || cameraAuthorizationStatus == .restricted
    }

    private func stopCaptureSession() {
        discoveryGeneration &+= 1
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.audioPlayer.stop()
            self.videoDecoder.reset()
            self.frameStore.clear()
            DispatchQueue.main.async {
                self.phase = self.cameraPermissionNeedsSettings ? .permissionDenied : .idle
                self.diagnostics.addEvent("USB-захват экрана остановлен")

                if let pending = self.pendingSelectedScreenDeviceID {
                    self.pendingSelectedScreenDeviceID = nil
                    self.selectedScreenDeviceID = pending
                }
            }
        }
    }

    private func discoverMuxedScreenDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        )
        let devices = discovery.devices
        let iosScreenDevices = devices.filter(Self.isLikelyIOSScreenDevice)
        let rejectedDevices = devices.filter { !Self.isLikelyIOSScreenDevice($0) }

        screenDeviceByID = Dictionary(uniqueKeysWithValues: iosScreenDevices.map { ($0.uniqueID, $0) })
        screenDevices = iosScreenDevices
            .map {
                CaptureDeviceOption(
                    id: $0.uniqueID,
                    name: $0.localizedName,
                    type: $0.deviceType.rawValue
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let signature = screenDevices.map { "\($0.id)|\($0.name)" }.joined(separator: ";")
        let deviceSetChanged = signature != lastDiscoverySignature
        if deviceSetChanged {
            lastDiscoverySignature = signature
            // Selection belongs only to the current physical set of devices. If the
            // set changes, ask again instead of silently remembering an old choice.
            selectedScreenDeviceID = screenDevices.count == 1 ? screenDevices[0].id : nil
        } else if selectedScreenDeviceID.flatMap({ screenDeviceByID[$0] }) == nil {
            selectedScreenDeviceID = screenDevices.count == 1 ? screenDevices[0].id : nil
        }

        if deviceSetChanged {
            if !rejectedDevices.isEmpty {
                diagnostics.addEvent(
                    "USB privacy guard: исключено внешних muxed devices не похожих на iPhone/iPad: \(rejectedDevices.map(\.localizedName).joined(separator: ", "))."
                )
            }
            if screenDevices.count == 1 {
                diagnostics.addEvent(
                    "USB auto-connect: найдено устройство \(screenDevices[0].name)."
                )
            } else if screenDevices.count > 1 {
                let selectedName = optionName(for: selectedScreenDeviceID) ?? "нужно выбрать источник"
                diagnostics.addEvent(
                    "USB auto-connect: найдено устройств: \(screenDevices.count); \(selectedName)."
                )
            }
        }

        if cameraPermissionNeedsSettings {
            phase = .permissionDenied
        } else {
            phase = .idle
        }
        if screenDevices.isEmpty {
            if !didLogWaitingForDevice {
                didLogWaitingForDevice = true
                diagnostics.addEvent(
                    "USB auto-connect: ожидаю iPhone/iPad по кабелю.",
                    level: .info
                )
            }
            return
        }

        didLogWaitingForDevice = false
        if automaticConnectionEnabled,
           !isManuallyPaused,
           !cameraPermissionNeedsSettings,
           !session.isRunning,
           selectedScreenDeviceID != nil {
            start()
        }
    }

    private func detectDeviceSetChangeWhileRunning() {
        _ = enableIOSScreenCaptureDevices()
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        )
        let devices = discovery.devices.filter(Self.isLikelyIOSScreenDevice)
        let options = devices
            .map { CaptureDeviceOption(id: $0.uniqueID, name: $0.localizedName, type: $0.deviceType.rawValue) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let signature = options.map { "\($0.id)|\($0.name)" }.joined(separator: ";")
        guard signature != lastDiscoverySignature else { return }

        screenDeviceByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.uniqueID, $0) })
        screenDevices = options
        lastDiscoverySignature = signature
        selectedScreenDeviceID = options.count == 1 ? options[0].id : nil
        diagnostics.addEvent("USB: набор подключённых устройств изменился; текущий источник остановлен и будет выбран заново.")
        stopCaptureSession()
    }

    private func configureAndStart(device: AVCaptureDevice, includeAudio: Bool) {
        phase = .configuring
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureSession(device: device, includeAudio: includeAudio)
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.phase = .running
                    self.diagnostics.addEvent("USB-экран запущен: \(device.localizedName)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.phase = .failed
                    self.diagnostics.addEvent(error.localizedDescription, level: .error)
                }
            }
        }
    }

    private func configureSession(
        device: AVCaptureDevice,
        includeAudio: Bool
    ) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        // The AVFoundation wrapper for Apple's muxed iOS screen device can expose
        // a synthetic 0×0 format. Ask the underlying CoreMediaIO input stream first:
        // enumerate its real CMFormatDescriptions and request the largest encoded
        // pixel dimensions directly. If the DAL stream rejects the write, fall back
        // to AVCaptureDevice.activeFormat below.
        let cmioSelection = configureNativeCMIOFormat(for: device)

        // On macOS AVCaptureSessionPreset.inputPriority is explicitly unavailable.
        // The macOS AVFoundation contract says that setting AVCaptureDevice.activeFormat
        // itself makes the selected input format authoritative for the session.
        // Therefore do not assign any session preset here.
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw USBCaptureError.cannotAddInput(device.localizedName)
            }
            session.addInput(input)
        } catch let error as USBCaptureError {
            throw error
        } catch {
            throw USBCaptureError.cannotCreateInput(device.localizedName)
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        // Apple documents an empty dictionary as the way to receive the capture
        // device's native sample format. 0.3.36 forced 420v here, which can make
        // AVFoundation insert a conversion/scaling stage for the muxed iOS screen
        // device. Device-native macOS output may be raw CVPixelBuffer or compressed
        // H.264/HEVC; the delegate handles both paths.
        videoOutput.videoSettings = [:]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        diagnostics.addEvent(
            "USB Original 0.3.48: AVCaptureVideoDataOutput запрошен в device-native режиме (videoSettings = {})."
        )
        guard session.canAddOutput(videoOutput) else {
            throw USBCaptureError.cannotAddVideoOutput
        }
        session.addOutput(videoOutput)

        // The CoreMediaIO iOS screen device is muxed: audio belongs to the same
        // AVCaptureDeviceInput. Do not discover/select a separate iPhone microphone.
        if includeAudio {
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            } else {
                diagnostics.addEvent(
                    "USB screen stream не предоставил отдельный системный аудиовыход",
                    level: .warning
                )
            }
        }

        let description = cmioSelection?.selectedDescription ?? configureFormat(on: device)
        DispatchQueue.main.async { [weak self] in
            self?.activeFormatDescription = description
            self?.cmioSelectedFormatDescription = cmioSelection?.selectedDescription ?? "CMIO native selection unavailable; AVFoundation fallback"
            self?.cmioAvailableFormatDescriptions = cmioSelection?.inventory ?? []
        }
    }

    private struct CMIONativeSelection {
        let selectedDescription: String
        let inventory: [String]
    }

    private func configureNativeCMIOFormat(for device: AVCaptureDevice) -> CMIONativeSelection? {
        guard let deviceID = cmioDeviceID(matchingUID: device.uniqueID) else {
            diagnostics.addEvent(
                "USB Original: CMIO device UID для \(device.uniqueID) не найден; используем AVFoundation fallback",
                level: .warning
            )
            return nil
        }

        let streams = cmioInputStreams(deviceID: deviceID)
        guard !streams.isEmpty else {
            diagnostics.addEvent("USB Original: CMIO input stream не найден; используем AVFoundation fallback", level: .warning)
            return nil
        }

        struct Candidate {
            let streamID: CMIOStreamID
            let format: CMFormatDescription
            let width: Int32
            let height: Int32
            let subtype: FourCharCode
            let origin: String
        }

        var candidates: [Candidate] = []
        var inventory: [String] = []

        func appendCandidate(
            _ format: CMFormatDescription,
            streamID: CMIOStreamID,
            origin: String,
            selectable: Bool = true
        ) {
            guard CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video else { return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            guard dimensions.width > 0, dimensions.height > 0 else { return }
            let subtype = CMFormatDescriptionGetMediaSubType(format)
            inventory.append(
                "stream \(streamID) \(origin): \(dimensions.width)×\(dimensions.height) \(Self.fourCCString(subtype))"
            )
            if selectable {
                candidates.append(
                    Candidate(
                        streamID: streamID,
                        format: format,
                        width: dimensions.width,
                        height: dimensions.height,
                        subtype: subtype,
                        origin: origin
                    )
                )
            }
        }

        for streamID in streams {
            // 0.3.36 only queried the array property. Apple's screen-capture DAL
            // may expose only current/preferred descriptions while leaving the
            // supported-format array empty, so probe all three surfaces.
            if let current = cmioSingleFormatDescription(
                streamID: streamID,
                selector: CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescription)
            ) {
                appendCandidate(current, streamID: streamID, origin: "current")
            }
            if let preferred = cmioSingleFormatDescription(
                streamID: streamID,
                selector: CMIOObjectPropertySelector(kCMIOStreamPropertyPreferredFormatDescription)
            ) {
                appendCandidate(preferred, streamID: streamID, origin: "preferred")
            }
            for format in cmioFormatDescriptions(streamID: streamID) {
                appendCandidate(format, streamID: streamID, origin: "available")
            }

            // Still-image descriptions are diagnostic only; they can expose the
            // physical/native raster but must not be written into the video stream.
            for format in cmioFormatDescriptions(
                streamID: streamID,
                selector: CMIOObjectPropertySelector(kCMIOStreamPropertyStillImageFormatDescriptions)
            ) {
                appendCandidate(format, streamID: streamID, origin: "still", selectable: false)
            }

            if let currentRate = cmioFloat64Property(
                streamID: streamID,
                selector: CMIOObjectPropertySelector(kCMIOStreamPropertyFrameRate)
            ) {
                inventory.append("stream \(streamID) current-rate: \(String(format: "%.3f", currentRate)) FPS")
            }
            if let preferredRate = cmioFloat64Property(
                streamID: streamID,
                selector: CMIOObjectPropertySelector(kCMIOStreamPropertyPreferredFrameRate)
            ) {
                inventory.append("stream \(streamID) preferred-rate: \(String(format: "%.3f", preferredRate)) FPS")
            }
        }

        guard let selected = candidates.max(by: { lhs, rhs in
            let lp = Int64(lhs.width) * Int64(lhs.height)
            let rp = Int64(rhs.width) * Int64(rhs.height)
            return lp == rp ? lhs.width < rhs.width : lp < rp
        }) else {
            diagnostics.addEvent(
                "USB Original: CMIO не опубликовал ни current/preferred, ни available video format description; device-native AVCapture output остаётся главным путём",
                level: .warning
            )
            DispatchQueue.main.async { [weak self] in
                self?.cmioAvailableFormatDescriptions = inventory.sorted()
            }
            return nil
        }

        let description = "\(selected.width)×\(selected.height) \(Self.fourCCString(selected.subtype))"
        let preferredSet = setCMIOFormatDescription(
            selected.format,
            on: selected.streamID,
            selector: CMIOObjectPropertySelector(kCMIOStreamPropertyPreferredFormatDescription)
        )
        let activeSet = setCMIOFormatDescription(selected.format, on: selected.streamID)

        // Ask both current and preferred rate surfaces. Either can be the one the
        // screen-capture DAL actually pays attention to.
        let activeRateSet = setCMIOFrameRate(60.0, on: selected.streamID)
        let preferredRateSet = setCMIOFrameRate(
            60.0,
            on: selected.streamID,
            selector: CMIOObjectPropertySelector(kCMIOStreamPropertyPreferredFrameRate)
        )

        if activeSet || preferredSet {
            diagnostics.addEvent(
                "USB Original CMIO candidate: \(description) [\(selected.origin)] • activeSet=\(activeSet) preferredSet=\(preferredSet) • rate60 active=\(activeRateSet) preferred=\(preferredRateSet)"
            )
            return CMIONativeSelection(
                selectedDescription: "\(description) • CMIO \(selected.origin)",
                inventory: inventory.sorted()
            )
        }

        diagnostics.addEvent(
            "USB Original: CMIO candidate \(description) [\(selected.origin)] виден, но active/preferred format не settable; используем device-native AVCapture output",
            level: .warning
        )
        DispatchQueue.main.async { [weak self] in
            self?.cmioAvailableFormatDescriptions = inventory.sorted()
        }
        return nil
    }

    private func cmioDeviceID(matchingUID uid: String) -> CMIODeviceID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize >= UInt32(MemoryLayout<CMIODeviceID>.size) else {
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var deviceIDs = [CMIODeviceID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        let status = deviceIDs.withUnsafeMutableBytes { rawBuffer in
            CMIOObjectGetPropertyData(
                CMIOObjectID(kCMIOObjectSystemObject),
                &address,
                0,
                nil,
                dataSize,
                &dataUsed,
                rawBuffer.baseAddress
            )
        }
        guard status == noErr else { return nil }

        return deviceIDs.first { cmioDeviceUID(deviceID: $0) == uid }
    }

    private func cmioDeviceUID(deviceID: CMIODeviceID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return nil
        }

        var value: CFString?
        var dataUsed: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            CMIOObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                dataSize,
                &dataUsed,
                pointer
            )
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private func cmioInputStreams(deviceID: CMIODeviceID) -> [CMIOStreamID] {
        func streams(scope: CMIOObjectPropertyScope) -> [CMIOStreamID] {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
                mScope: scope,
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var dataSize: UInt32 = 0
            guard CMIOObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
                  dataSize >= UInt32(MemoryLayout<CMIOStreamID>.size) else { return [] }

            let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
            var result = [CMIOStreamID](repeating: 0, count: count)
            var dataUsed: UInt32 = 0
            let status = result.withUnsafeMutableBytes { rawBuffer in
                CMIOObjectGetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    dataSize,
                    &dataUsed,
                    rawBuffer.baseAddress
                )
            }
            return status == noErr ? result : []
        }

        let input = streams(scope: CMIOObjectPropertyScope(kCMIODevicePropertyScopeInput))
        return input.isEmpty
            ? streams(scope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal))
            : input
    }

    private func cmioFormatDescriptions(
        streamID: CMIOStreamID,
        selector: CMIOObjectPropertySelector = CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescriptions)
    ) -> [CMFormatDescription] {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(streamID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        var array: CFArray?
        var dataUsed: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &array) { pointer in
            CMIOObjectGetPropertyData(
                streamID,
                &address,
                0,
                nil,
                dataSize,
                &dataUsed,
                pointer
            )
        }
        guard status == noErr, let array else { return [] }

        var result: [CMFormatDescription] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let raw = CFArrayGetValueAtIndex(array, index) else { continue }
            let format = Unmanaged<CMFormatDescription>
                .fromOpaque(UnsafeRawPointer(raw))
                .takeUnretainedValue()
            result.append(format)
        }
        return result
    }

    private func cmioSingleFormatDescription(
        streamID: CMIOStreamID,
        selector: CMIOObjectPropertySelector
    ) -> CMFormatDescription? {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(streamID, &address) else { return nil }
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(streamID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return nil }

        var value: CMFormatDescription?
        var dataUsed: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            CMIOObjectGetPropertyData(
                streamID,
                &address,
                0,
                nil,
                dataSize,
                &dataUsed,
                pointer
            )
        }
        return status == noErr ? value : nil
    }

    private func cmioFloat64Property(
        streamID: CMIOStreamID,
        selector: CMIOObjectPropertySelector
    ) -> Float64? {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(streamID, &address) else { return nil }
        var value: Float64 = 0
        var dataUsed: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            CMIOObjectGetPropertyData(
                streamID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float64>.size),
                &dataUsed,
                pointer
            )
        }
        return status == noErr ? value : nil
    }

    private func setCMIOFormatDescription(
        _ format: CMFormatDescription,
        on streamID: CMIOStreamID,
        selector: CMIOObjectPropertySelector = CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescription)
    ) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var settable = DarwinBoolean(false)
        guard CMIOObjectIsPropertySettable(streamID, &address, &settable) == noErr,
              settable.boolValue else { return false }

        var value: CMFormatDescription? = format
        let status = withUnsafePointer(to: &value) { pointer in
            CMIOObjectSetPropertyData(
                streamID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<CMFormatDescription?>.size),
                pointer
            )
        }
        return status == noErr
    }

    private func setCMIOFrameRate(
        _ frameRate: Float64,
        on streamID: CMIOStreamID,
        selector: CMIOObjectPropertySelector = CMIOObjectPropertySelector(kCMIOStreamPropertyFrameRate)
    ) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var settable = DarwinBoolean(false)
        guard CMIOObjectIsPropertySettable(streamID, &address, &settable) == noErr,
              settable.boolValue else { return false }

        var value = frameRate
        return withUnsafePointer(to: &value) { pointer in
            CMIOObjectSetPropertyData(
                streamID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float64>.size),
                pointer
            )
        } == noErr
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", code)
    }

    private func configureFormat(on device: AVCaptureDevice) -> String {
        let preferredFPS = 60.0
        let ranked = device.formats.compactMap { format -> (AVCaptureDevice.Format, Double, Int32, Int32)? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            guard maxFPS > 0 else { return nil }
            return (format, maxFPS, dimensions.width, dimensions.height)
        }
        .sorted { lhs, rhs in
            // "Original" over USB means maximum screen-device resolution first.
            // Only after resolution is equal do we prefer a format capable of 60 FPS.
            let lhsPixels = Int64(lhs.2) * Int64(lhs.3)
            let rhsPixels = Int64(rhs.2) * Int64(rhs.3)
            if lhsPixels != rhsPixels { return lhsPixels > rhsPixels }
            let lhsSupports60 = lhs.1 + 0.01 >= preferredFPS
            let rhsSupports60 = rhs.1 + 0.01 >= preferredFPS
            if lhsSupports60 != rhsSupports60 { return lhsSupports60 }
            return lhs.1 > rhs.1
        }

        guard let selected = ranked.first else { return "Формат определяется USB screen device" }
        let selectedFPS = min(preferredFPS, selected.1)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = selected.0
            if let range = selected.0.videoSupportedFrameRateRanges.first(where: {
                $0.minFrameRate <= selectedFPS && $0.maxFrameRate + 0.01 >= selectedFPS
            }) {
                let timescale = CMTimeScale(max(1, Int(selectedFPS.rounded())))
                let duration = CMTime(value: 1, timescale: timescale)
                if duration >= range.minFrameDuration && duration <= range.maxFrameDuration {
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
                }
            }
        } catch {
            diagnostics.addEvent("USB screen device сам выберет format/FPS: \(error.localizedDescription)", level: .warning)
        }

        let description = "\(selected.2)×\(selected.3), \(String(format: "%.1f", selectedFPS)) FPS (device max \(String(format: "%.1f", selected.1)))"
        diagnostics.addEvent("USB Original format выбран: \(description)")
        return description
    }

    private func availableFormatInventory() -> [[String: Any]] {
        guard let id = selectedScreenDeviceID, let device = screenDeviceByID[id] else { return [] }
        return device.formats.enumerated().map { index, format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let ranges = format.videoSupportedFrameRateRanges.map { range in
                [
                    "min_fps": range.minFrameRate,
                    "max_fps": range.maxFrameRate
                ]
            }
            return [
                "index": index,
                "width": Int(dimensions.width),
                "height": Int(dimensions.height),
                "frame_rate_ranges": ranges
            ]
        }
    }

    private func optionName(for id: String?) -> String? {
        guard let id else { return nil }
        return screenDevices.first(where: { $0.id == id })?.name
    }

    @discardableResult
    private func enableIOSScreenCaptureDevices() -> OSStatus {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        return CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
    }

    private static func authorizationLabel(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .notDetermined: return "not-determined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    private static func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func isLikelyIOSScreenDevice(_ device: AVCaptureDevice) -> Bool {
        guard device.deviceType == .external else { return false }
        let name = device.localizedName.lowercased()
        let manufacturer = device.manufacturer.lowercased()
        let model = device.modelID.lowercased()

        // Apple's wired iOS screen endpoint is published as an external muxed
        // capture device. The Camera privacy bucket is a macOS classification;
        // it does not mean the MacBook camera is our source. Never fall back to an
        // arbitrary external/muxed device if an iPhone/iPad screen endpoint is absent.
        return name.contains("iphone")
            || name.contains("ipad")
            || ((manufacturer.contains("apple") || model.contains("iphone") || model.contains("ipad"))
                && (name.contains("phone") || name.contains("pad")))
    }
}

extension USBCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === videoOutput {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
                if width != observedVideoWidth
                    || height != observedVideoHeight
                    || pixelFormat != observedVideoPixelFormat {
                    observedVideoWidth = width
                    observedVideoHeight = height
                    observedVideoPixelFormat = pixelFormat
                    let description = "\(width)×\(height) \(Self.fourCCString(pixelFormat)) • native CVPixelBuffer"
                    DispatchQueue.main.async { [weak self] in
                        self?.actualVideoFormatDescription = description
                        self?.diagnostics.addEvent("USB actual stream: \(description)")
                    }
                }

                frameStore.push(pixelBuffer: pixelBuffer, presentationTime: pts)
                diagnostics.recordVideoReceived(pts: pts)
            } else if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                let subtype = CMFormatDescriptionGetMediaSubType(format)
                if Int(dimensions.width) != observedVideoWidth
                    || Int(dimensions.height) != observedVideoHeight
                    || subtype != observedVideoPixelFormat {
                    observedVideoWidth = Int(dimensions.width)
                    observedVideoHeight = Int(dimensions.height)
                    observedVideoPixelFormat = subtype
                    let description = "\(dimensions.width)×\(dimensions.height) \(Self.fourCCString(subtype)) • native compressed"
                    DispatchQueue.main.async { [weak self] in
                        self?.actualVideoFormatDescription = description
                        self?.diagnostics.addEvent("USB actual stream: \(description)")
                    }
                }
                videoDecoder.decode(sampleBuffer: sampleBuffer)
            }
        } else if output === audioOutput {
            audioPlayer.enqueue(sampleBuffer)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === videoOutput {
            diagnostics.recordCaptureDrop()
        }
    }
}
