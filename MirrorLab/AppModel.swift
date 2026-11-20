import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import SwiftUI


private final class CapturePreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Invisible interaction surface above the video. It draws nothing, so Discord/OBS
/// only see video pixels when Preview controls are hidden. Left drag moves the borderless
/// window; edge/corner drag resizes it while preserving the current source aspect ratio;
/// right click opens the native Preview actions menu.
private final class PreviewInteractionView: NSView {
    private let edgeInset: CGFloat = 10

    var controlsVisibleProvider: (() -> Bool)?
    var activeStreamProvider: (() -> Bool)?
    var fullscreenProvider: (() -> Bool)?
    var onToggleControls: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onToggleFullscreen: (() -> Void)?
    var onStopStream: (() -> Void)?
    var onClosePreview: (() -> Void)?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        let b = bounds
        addCursorRect(NSRect(x: 0, y: edgeInset, width: edgeInset, height: max(0, b.height - edgeInset * 2)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: max(0, b.width - edgeInset), y: edgeInset, width: edgeInset, height: max(0, b.height - edgeInset * 2)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: edgeInset, y: 0, width: max(0, b.width - edgeInset * 2), height: edgeInset), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: edgeInset, y: max(0, b.height - edgeInset), width: max(0, b.width - edgeInset * 2), height: edgeInset), cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let point = convert(event.locationInWindow, from: nil)
        let edges = resizeEdges(at: point)
        if edges.isEmpty {
            window.performDrag(with: event)
        } else {
            resizeWindow(window, edges: edges)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let menu = NSMenu(title: "Preview")
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Показать настройки", action: #selector(showSettingsAction(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Свернуть", action: #selector(minimizeAction(_:)), keyEquivalent: "")
        menu.addItem(withTitle: (fullscreenProvider?() == true ? "Выйти из полноэкранного режима" : "Полный экран"), action: #selector(fullscreenAction(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: (controlsVisibleProvider?() == true ? "Скрыть элементы управления" : "Показать элементы управления"), action: #selector(toggleControlsAction(_:)), keyEquivalent: "")
        if activeStreamProvider?() == true {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Прекратить трансляцию", action: #selector(stopStreamAction(_:)), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Закрыть предпросмотр", action: #selector(closePreviewAction(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self; item.isEnabled = true }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func showSettingsAction(_ sender: Any?) { onShowSettings?() }
    @objc private func minimizeAction(_ sender: Any?) { onMinimize?() }
    @objc private func fullscreenAction(_ sender: Any?) { onToggleFullscreen?() }
    @objc private func toggleControlsAction(_ sender: Any?) { onToggleControls?() }
    @objc private func stopStreamAction(_ sender: Any?) { onStopStream?() }
    @objc private func closePreviewAction(_ sender: Any?) { onClosePreview?() }

    private struct ResizeEdges: OptionSet {
        let rawValue: Int
        static let left = ResizeEdges(rawValue: 1 << 0)
        static let right = ResizeEdges(rawValue: 1 << 1)
        static let bottom = ResizeEdges(rawValue: 1 << 2)
        static let top = ResizeEdges(rawValue: 1 << 3)
    }

    private func resizeEdges(at point: NSPoint) -> ResizeEdges {
        var result: ResizeEdges = []
        if point.x <= edgeInset { result.insert(.left) }
        if point.x >= bounds.width - edgeInset { result.insert(.right) }
        if point.y <= edgeInset { result.insert(.bottom) }
        if point.y >= bounds.height - edgeInset { result.insert(.top) }
        return result
    }

    private func resizeWindow(_ window: NSWindow, edges: ResizeEdges) {
        let startFrame = window.frame
        let startMouse = NSEvent.mouseLocation
        let configured = window.contentAspectRatio
        let ratio = configured.height > 0 ? configured.width / configured.height : startFrame.width / max(1, startFrame.height)
        let minBaseWidth = max(260, window.contentMinSize.width)
        let minBaseHeight = max(180, window.contentMinSize.height)
        let minWidth = max(minBaseWidth, minBaseHeight * ratio)

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x
            let dy = now.y - startMouse.y

            let horizontalWidth: CGFloat = {
                if edges.contains(.left) { return startFrame.width - dx }
                if edges.contains(.right) { return startFrame.width + dx }
                return startFrame.width
            }()
            let verticalHeight: CGFloat = {
                if edges.contains(.bottom) { return startFrame.height - dy }
                if edges.contains(.top) { return startFrame.height + dy }
                return startFrame.height
            }()

            let hasHorizontal = edges.contains(.left) || edges.contains(.right)
            let hasVertical = edges.contains(.bottom) || edges.contains(.top)
            let widthFromHorizontal = max(minWidth, horizontalWidth)
            let widthFromVertical = max(minWidth, verticalHeight * ratio)

            let width: CGFloat
            if hasHorizontal && hasVertical {
                let horizontalChange = abs(widthFromHorizontal - startFrame.width) / max(1, startFrame.width)
                let verticalChange = abs((widthFromVertical / ratio) - startFrame.height) / max(1, startFrame.height)
                width = horizontalChange >= verticalChange ? widthFromHorizontal : widthFromVertical
            } else if hasHorizontal {
                width = widthFromHorizontal
            } else {
                width = widthFromVertical
            }
            let height = width / ratio

            var frame = NSRect(origin: startFrame.origin, size: NSSize(width: width, height: height))
            if edges.contains(.left) {
                frame.origin.x = startFrame.maxX - width
            } else if !edges.contains(.right) {
                frame.origin.x = startFrame.midX - width / 2
            }
            if edges.contains(.bottom) {
                frame.origin.y = startFrame.maxY - height
            } else if !edges.contains(.top) {
                frame.origin.y = startFrame.midY - height / 2
            }

            // Borderless preview has no decoration, so frame ratio == content ratio.
            // Re-assert the exact ratio on every drag step to prevent cumulative drift.
            window.setFrame(frame, display: true, animate: false)
            window.contentAspectRatio = NSSize(width: ratio, height: 1)
        }
    }
}

enum TransportMode: String, CaseIterable, Identifiable {
    case airplay = "AirPlay"
    case usb = "USB"

    var id: String { rawValue }
}

final class AppModel: ObservableObject {
    @Published var selectedMode: TransportMode = .airplay {
        didSet {
            guard oldValue != selectedMode else { return }
            applySelectedMode()
        }
    }
    @Published private(set) var isPreviewVisible = false
    @Published private(set) var previewControlsVisible = true
    @Published var outputVolume: Double = AppModel.loadSavedOutputVolume() {
        didSet {
            let clamped = min(max(outputVolume, 0), 1)
            if clamped != outputVolume {
                outputVolume = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.outputVolumeDefaultsKey)
            airplay.setOutputVolume(Float(clamped))
            usb.setOutputVolume(Float(clamped))
        }
    }

    let diagnostics: DiagnosticsStore
    let frameStore: LatestVideoFrameStore
    let airplayPresentationStore: AirPlayPresentationStore
    let airplay: AirPlayController
    let usb: USBCaptureController

    private weak var settingsWindow: NSWindow?
    private var previewWindowController: NSWindowController?
    private var previewControlsHostingView: NSView?
    private var diagnosticsWindowController: NSWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var previewAspectTimer: Timer?
    private var previewWindowCloseObserver: NSObjectProtocol?
    private var previewFullscreenObservers: [NSObjectProtocol] = []
    private var lastPreviewDimensions: (width: Int, height: Int)?
    private var usbSelectionPromptVisible = false
    private var usbSelectionPromptSuppressedSignature: String?
    // Held only while a stream is live. Without it macOS may App-Nap / coalesce timers
    // of a background MirrorLab and dims or sleeps the display while the user only
    // interacts with the iPhone.
    private var streamingActivity: NSObjectProtocol?

    private static let outputVolumeDefaultsKey = "MirrorLab.OutputVolume"

    private static func loadSavedOutputVolume() -> Double {
        guard UserDefaults.standard.object(forKey: outputVolumeDefaultsKey) != nil else {
            return 0.65
        }
        return min(max(UserDefaults.standard.double(forKey: outputVolumeDefaultsKey), 0), 1)
    }

    init() {
        let diagnostics = DiagnosticsStore()
        let frameStore = LatestVideoFrameStore()
        let airplayPresentationStore = AirPlayPresentationStore()
        self.diagnostics = diagnostics
        self.frameStore = frameStore
        self.airplayPresentationStore = airplayPresentationStore
        self.airplay = AirPlayController(presentationStore: airplayPresentationStore, diagnostics: diagnostics)
        self.usb = USBCaptureController(frameStore: frameStore, diagnostics: diagnostics)

        // Apply the persisted app-local gain before either transport starts.
        self.airplay.setOutputVolume(Float(outputVolume))
        self.usb.setOutputVolume(Float(outputVolume))

        self.airplay.onFinalSessionEnded = { [weak self] in
            guard let self, self.selectedMode == .airplay else { return }
            self.closePreviewWindow()
        }
        self.usb.onCaptureEnded = { [weak self] in
            guard let self, self.selectedMode == .usb else { return }
            self.closePreviewWindow()
        }

        airplay.$hasLiveVideo
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] live in
                guard let self else { return }
                self.updateStreamingActivity(airplayLive: live)
                guard self.selectedMode == .airplay else { return }
                if live { self.showPreviewWindow() }
            }
            .store(in: &cancellables)

        usb.$phase
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                self.updateStreamingActivity(usbPhase: phase)
                guard self.selectedMode == .usb else { return }
                if phase == .running { self.showPreviewWindow() }
            }
            .store(in: &cancellables)

        usb.$screenDevices
            .combineLatest(usb.$selectedScreenDeviceID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices, selectedID in
                guard let self, self.selectedMode == .usb, devices.count > 1, selectedID == nil else { return }
                self.presentUSBDeviceSelectionIfNeeded()
            }
            .store(in: &cancellables)

        // AirPlay behaves like a receiver appliance: launching MirrorLab is enough.
        DispatchQueue.main.async { [weak airplay = self.airplay] in
            airplay?.enableAutomaticReceiver()
        }
    }

    func registerSettingsWindow(_ window: NSWindow) {
        guard settingsWindow !== window else { return }
        settingsWindow = window
        window.title = "MirrorLab"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        DispatchQueue.main.async { [weak self] in
            self?.removeSystemTabCommands()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.removeSystemTabCommands()
        }
    }

    func showSettingsWindow() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showSettingsWindow() }
            return
        }
        guard let window = settingsWindow else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applySelectedMode() {
        closePreviewWindow()

        switch selectedMode {
        case .airplay:
            usb.setAutomaticConnectionEnabled(false)
            usb.stop()
            airplay.enableAutomaticReceiver()
            if airplay.hasLiveVideo { showPreviewWindow() }
        case .usb:
            // A selected transport owns the media lifecycle. Do not leave an
            // invisible AirPlay audio/video session alive behind the USB tab.
            airplay.stop()
            usb.setAutomaticConnectionEnabled(true)
        }
        updateStreamingActivity()
    }

    func showPreviewWindow() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showPreviewWindow() }
            return
        }

        if let window = previewWindowController?.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            if window.isVisible {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                isPreviewVisible = true
                startPreviewAspectTracking()
                applyCurrentPreviewAspectIfAvailable(force: false)
                return
            }

            // Recreate a manually closed preview instead of reviving its old Metal
            // surface. A closed Metal display link can otherwise reopen frozen.
            window.contentView = nil
            previewWindowController = nil
            diagnostics.setExternalRenderedFPS(nil)
        }

        let rootView = ExternalPreviewView().environmentObject(self)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 0
        hostingView.layer?.masksToBounds = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: content.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let interaction = PreviewInteractionView(frame: content.bounds)
        interaction.autoresizingMask = [.width, .height]
        interaction.wantsLayer = true
        interaction.layer?.backgroundColor = NSColor.clear.cgColor
        interaction.controlsVisibleProvider = { [weak self] in self?.previewControlsVisible ?? false }
        interaction.activeStreamProvider = { [weak self] in self?.hasActiveStream ?? false }
        interaction.fullscreenProvider = { [weak self] in self?.previewWindowController?.window?.styleMask.contains(.fullScreen) ?? false }
        interaction.onToggleControls = { [weak self] in self?.togglePreviewControls() }
        interaction.onShowSettings = { [weak self] in self?.showSettingsWindow() }
        interaction.onMinimize = { [weak self] in self?.minimizePreviewWindow() }
        interaction.onToggleFullscreen = { [weak self] in self?.togglePreviewFullscreen() }
        interaction.onStopStream = { [weak self] in self?.stopCurrentStream() }
        interaction.onClosePreview = { [weak self] in self?.closePreviewWindow() }
        content.addSubview(interaction, positioned: .above, relativeTo: hostingView)

        let controlsView = PreviewControlsView().environmentObject(self)
        let controlsHosting = NSHostingView(rootView: controlsView)
        controlsHosting.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controlsHosting, positioned: .above, relativeTo: interaction)
        NSLayoutConstraint.activate([
            controlsHosting.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            controlsHosting.topAnchor.constraint(equalTo: content.topAnchor, constant: 12)
        ])
        previewControlsHostingView = controlsHosting
        previewControlsVisible = true
        controlsHosting.isHidden = false

        // The capture target itself contains pixels only: no titlebar, traffic lights,
        // rounded WindowServer chrome, shadow or visible controls. `title` remains
        // metadata so window pickers can still show a useful MirrorLab name.
        let window = CapturePreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = previewWindowTitle
        window.contentView = content
        window.contentMinSize = NSSize(width: 260, height: 180)
        window.contentAspectRatio = NSSize(width: 3, height: 2)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.sharingType = .readOnly
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.acceptsMouseMovedEvents = true
        window.center()

        let controller = NSWindowController(window: window)
        previewWindowController = controller
        installPreviewWindowObservers(window)

        lastPreviewDimensions = nil
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isPreviewVisible = true

        startPreviewAspectTracking()
        applyCurrentPreviewAspectIfAvailable(force: true)
    }

    func closePreviewWindow() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.closePreviewWindow() }
            return
        }

        previewAspectTimer?.invalidate()
        previewAspectTimer = nil
        lastPreviewDimensions = nil
        isPreviewVisible = false
        removePreviewWindowObservers()

        guard let controller = previewWindowController else { return }
        controller.window?.contentView = nil
        controller.close()
        previewWindowController = nil
        previewControlsHostingView = nil
        diagnostics.setExternalRenderedFPS(nil)
    }

    func togglePreviewControls() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.togglePreviewControls() }
            return
        }

        previewControlsVisible.toggle()
        // SwiftUI observes previewControlsVisible and removes/recreates the chrome.
        // Keep the AppKit flags in sync as a belt-and-suspenders fallback for
        // window capture implementations that snapshot the hosting view directly.
        previewControlsHostingView?.isHidden = !previewControlsVisible
        previewControlsHostingView?.alphaValue = previewControlsVisible ? 1 : 0
        previewControlsHostingView?.layer?.isHidden = !previewControlsVisible
    }

    func minimizePreviewWindow() {
        guard let window = previewWindowController?.window else { return }
        if window.isMiniaturized { return }

        // A borderless Preview still needs the miniaturizable capability for
        // AppKit's standard miniaturize path. 0.3.42 omitted it, so both the
        // minus button and the context-menu command were no-ops.
        window.styleMask.insert(.miniaturizable)
        window.miniaturize(nil)

        // Give AppKit/WindowServer time to finish the normal Dock "genie/scale"
        // animation. The old immediate fallback ran on the next main-loop turn and
        // hid the window before that animation could complete, so Preview appeared
        // to vanish abruptly even when miniaturize() itself was working.
        // Keep orderOut only as a late beta-macOS safety fallback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self, weak window] in
            guard let self, let window else { return }
            if !window.isMiniaturized && window.isVisible {
                window.orderOut(nil)
                self.isPreviewVisible = false
            }
        }
    }

    func togglePreviewFullscreen() {
        guard let window = previewWindowController?.window else { return }
        window.toggleFullScreen(nil)
    }

    private var previewWindowTitle: String {
        switch selectedMode {
        case .airplay:
            return "MirrorLab Preview — AirPlay"
        case .usb:
            let device = usb.connectedDeviceName
            return device.isEmpty ? "MirrorLab Preview — USB" : "MirrorLab Preview — \(device)"
        }
    }

    private func installPreviewWindowObservers(_ window: NSWindow) {
        removePreviewWindowObservers()
        let center = NotificationCenter.default
        previewWindowCloseObserver = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window,
                  self.previewWindowController?.window === window else { return }
            self.previewAspectTimer?.invalidate()
            self.previewAspectTimer = nil
            self.lastPreviewDimensions = nil
            self.isPreviewVisible = false
            window.contentView = nil
            self.previewWindowController = nil
            self.previewControlsHostingView = nil
            self.diagnostics.setExternalRenderedFPS(nil)
            self.removePreviewWindowObservers()
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            previewFullscreenObservers.append(center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.applyCurrentPreviewAspectIfAvailable(force: false)
            })
        }
    }

    private func removePreviewWindowObservers() {
        let center = NotificationCenter.default
        if let previewWindowCloseObserver { center.removeObserver(previewWindowCloseObserver) }
        previewFullscreenObservers.forEach { center.removeObserver($0) }
        previewWindowCloseObserver = nil
        previewFullscreenObservers.removeAll()
    }

    private func startPreviewAspectTracking() {
        previewAspectTimer?.invalidate()
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.applyCurrentPreviewAspectIfAvailable(force: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        previewAspectTimer = timer
    }

    private func currentPreviewDimensions() -> (width: Int, height: Int)? {
        switch selectedMode {
        case .airplay: return airplayPresentationStore.currentDimensions()
        case .usb: return frameStore.currentDimensions()
        }
    }

    private func applyCurrentPreviewAspectIfAvailable(force: Bool) {
        guard let dimensions = currentPreviewDimensions() else { return }
        applyPreviewAspect(width: dimensions.width, height: dimensions.height, force: force)
    }

    private func applyPreviewAspect(width: Int, height: Int, force: Bool) {
        guard width > 0, height > 0,
              let window = previewWindowController?.window,
              !window.styleMask.contains(.fullScreen)
        else { return }

        if !force,
           let previous = lastPreviewDimensions,
           previous.width == width,
           previous.height == height {
            return
        }
        lastPreviewDimensions = (width, height)
        window.title = previewWindowTitle
        window.contentAspectRatio = NSSize(width: CGFloat(width), height: CGFloat(height))

        let aspect = CGFloat(width) / CGFloat(height)
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxWidth = min(1_080.0, visibleFrame.width * 0.78)
        let maxHeight = min(820.0, visibleFrame.height * 0.78)

        var contentWidth: CGFloat
        var contentHeight: CGFloat
        if aspect >= 1 {
            contentWidth = maxWidth
            contentHeight = contentWidth / aspect
            if contentHeight > maxHeight {
                contentHeight = maxHeight
                contentWidth = contentHeight * aspect
            }
        } else {
            contentHeight = maxHeight
            contentWidth = contentHeight * aspect
            if contentWidth > maxWidth {
                contentWidth = maxWidth
                contentHeight = contentWidth / aspect
            }
        }

        contentWidth = max(contentWidth, 280)
        contentHeight = max(contentHeight, 220)

        let oldFrame = window.frame
        let oldCenter = NSPoint(x: oldFrame.midX, y: oldFrame.midY)
        window.setContentSize(NSSize(width: contentWidth, height: contentHeight))
        var newFrame = window.frame
        newFrame.origin.x = oldCenter.x - newFrame.width / 2
        newFrame.origin.y = oldCenter.y - newFrame.height / 2

        if !visibleFrame.intersects(newFrame) || force {
            newFrame.origin.x = visibleFrame.midX - newFrame.width / 2
            newFrame.origin.y = visibleFrame.midY - newFrame.height / 2
        }
        window.setFrame(newFrame, display: true, animate: false)
    }

    var hasActiveStream: Bool {
        switch selectedMode {
        case .airplay: return airplay.hasLiveVideo
        case .usb: return usb.phase == .running
        }
    }

    /// Keeps macOS from App-Napping MirrorLab or sleeping the display while a stream is
    /// live; released as soon as it ends. `.latencyCritical` also stops timer coalescing
    /// for network/decoder/render work while the app is not frontmost.
    private func updateStreamingActivity(airplayLive: Bool? = nil, usbPhase: USBCapturePhase? = nil) {
        let live: Bool
        switch selectedMode {
        case .airplay: live = airplayLive ?? airplay.hasLiveVideo
        case .usb: live = (usbPhase ?? usb.phase) == .running
        }

        if live, streamingActivity == nil {
            streamingActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
                reason: "MirrorLab: идёт трансляция экрана iPhone/iPad"
            )
        } else if !live, let activity = streamingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamingActivity = nil
        }
    }

    func stopCurrentStream() {
        closePreviewWindow()
        switch selectedMode {
        case .airplay:
            airplay.stopCurrentSessionKeepingReceiver()
        case .usb:
            usb.pauseCurrentCapture()
        }
    }

    func resumeUSBIfPaused() {
        guard selectedMode == .usb else { return }
        usb.resumeAutomaticCapture()
    }

    func selectUSBSource(_ id: String) {
        guard selectedMode == .usb else { return }
        usb.selectScreenDevice(id)
    }

    func applicationDidBecomeActive() {
        usb.refreshCameraAuthorizationStatus()
    }

    private func presentUSBDeviceSelectionIfNeeded() {
        let signature = usb.screenDevices.map { "\($0.id)|\($0.name)" }.joined(separator: ";")
        guard !usbSelectionPromptVisible,
              selectedMode == .usb,
              usb.screenDevices.count > 1,
              usb.selectedScreenDeviceID == nil,
              usbSelectionPromptSuppressedSignature != signature
        else { return }

        usbSelectionPromptVisible = true
        let devices = usb.screenDevices
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28), pullsDown: false)
        devices.forEach { popup.addItem(withTitle: $0.name) }

        let alert = NSAlert()
        alert.messageText = "Выбери USB-источник"
        alert.informativeText = "К Mac подключено несколько iPhone/iPad. Выбор действует только пока этот набор устройств остаётся подключённым."
        alert.alertStyle = .informational
        alert.accessoryView = popup
        alert.addButton(withTitle: "Использовать")
        alert.addButton(withTitle: "Позже")

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak popup] response in
            guard let self else { return }
            self.usbSelectionPromptVisible = false
            guard response == .alertFirstButtonReturn,
                  let popup,
                  popup.indexOfSelectedItem >= 0,
                  popup.indexOfSelectedItem < devices.count
            else {
                self.usbSelectionPromptSuppressedSignature = signature
                return
            }
            self.usbSelectionPromptSuppressedSignature = nil
            self.usb.selectScreenDevice(devices[popup.indexOfSelectedItem].id)
        }

        if let settingsWindow {
            alert.beginSheetModal(for: settingsWindow, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    func showDiagnosticsWindow() {
        if let window = diagnosticsWindowController?.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: DiagnosticsPanelView(store: diagnostics))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 390),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MirrorLab Diagnostics"
        window.contentView = hostingView
        window.minSize = NSSize(width: 900, height: 320)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()

        let controller = NSWindowController(window: window)
        diagnosticsWindowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func stopEverything() {
        usb.setAutomaticConnectionEnabled(false)
        closePreviewWindow()
        diagnosticsWindowController?.close()
        diagnosticsWindowController = nil
        airplay.stop()
        usb.stop()
        if let activity = streamingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamingActivity = nil
        }
    }

    func exportReport() {
        let panel = NSSavePanel()
        panel.title = "Сохранить отчёт MirrorLab"
        panel.nameFieldStringValue = "MirrorLab-report-\(Self.fileTimestamp()).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let extra: [String: Any] = [
            "selected_mode": selectedMode.rawValue,
            "airplay": airplay.reportDictionary,
            "usb": usb.reportDictionary
        ]

        do {
            let data = try diagnostics.makeReportData(extra: extra)
            try data.write(to: url, options: .atomic)
            diagnostics.addEvent("Отчёт сохранён: \(url.lastPathComponent)", level: .info)
        } catch {
            diagnostics.addEvent("Не удалось сохранить отчёт: \(error.localizedDescription)", level: .error)
            NSAlert(error: error).runModal()
        }
    }

    func removeSystemTabCommands() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let bannedSelectors: Set<String> = [
            "toggleTabBar:",
            "showAllTabs:",
            "mergeAllWindows:",
            "moveTabToNewWindow:",
            "selectNextTab:",
            "selectPreviousTab:"
        ]
        scrubTabCommands(in: mainMenu, selectors: bannedSelectors)
    }

    private func scrubTabCommands(in menu: NSMenu, selectors: Set<String>) {
        for index in menu.items.indices.reversed() {
            let item = menu.items[index]
            if let action = item.action, selectors.contains(NSStringFromSelector(action)) {
                menu.removeItem(at: index)
                continue
            }
            if let submenu = item.submenu {
                scrubTabCommands(in: submenu, selectors: selectors)
            }
        }
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
