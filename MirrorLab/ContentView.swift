import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionSummary

                    switch model.selectedMode {
                    case .airplay:
                        AirPlayControls(controller: model.airplay)
                    case .usb:
                        USBControls(controller: model.usb)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 350, idealHeight: 430)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(SettingsWindowAccessor { window in
            model.registerSettingsWindow(window)
        })
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.applicationDidBecomeActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.stopEverything()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MirrorLab")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("iPhone / iPad → Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                PhaseBadge(text: activeStatusText, active: activeStatus)
            }

            Picker("Режим", selection: $model.selectedMode) {
                ForEach(TransportMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var connectionSummary: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: model.selectedMode == .airplay ? "airplayvideo" : "cable.connector")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 28)
                    .foregroundStyle(activeStatus ? Color.green : Color.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(summaryTitle)
                        .font(.headline)
                    Text(summaryDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 7) {
                    Button(model.isPreviewVisible ? "К предпросмотру" : "Показать предпросмотр") {
                        model.showPreviewWindow()
                    }
                    .buttonStyle(.bordered)

                    if model.hasActiveStream {
                        Button(role: .destructive) {
                            model.stopCurrentStream()
                        } label: {
                            Label("Прекратить", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                    } else if model.selectedMode == .usb, model.usb.isManuallyPaused {
                        Button {
                            model.resumeUSBIfPaused()
                        } label: {
                            Label("Возобновить USB", systemImage: "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var activeStatus: Bool {
        switch model.selectedMode {
        case .airplay:
            return model.airplay.hasLiveVideo
        case .usb:
            return model.usb.phase == .running
        }
    }

    private var activeStatusText: String {
        switch model.selectedMode {
        case .airplay:
            if model.airplay.hasLiveVideo { return "Трансляция" }
            switch model.airplay.phase {
            case .handshaking, .waitingForMedia, .receivingMedia: return "Подключение"
            case .failed: return "Ошибка"
            default: return "Ожидание"
            }
        case .usb:
            switch model.usb.phase {
            case .running: return "Трансляция"
            case .discovering: return "Поиск"
            case .requestingPermission, .configuring: return "Подключение"
            case .permissionDenied: return "Нужен доступ"
            case .failed: return "Ошибка"
            case .idle:
                if model.usb.screenDevices.count > 1, model.usb.selectedScreenDeviceID == nil {
                    return "Выбор устройства"
                }
                return "Ожидание"
            }
        }
    }

    private var summaryTitle: String {
        switch model.selectedMode {
        case .airplay:
            if model.airplay.hasLiveVideo { return "AirPlay подключён" }
            switch model.airplay.phase {
            case .handshaking, .waitingForMedia, .receivingMedia:
                return "AirPlay подключается"
            case .failed:
                return "Ошибка AirPlay"
            default:
                return "Готов к Повтору экрана"
            }
        case .usb:
            if model.usb.phase == .running {
                return model.usb.connectedDeviceName.isEmpty ? "USB подключён" : model.usb.connectedDeviceName
            }
            if model.usb.cameraPermissionNeedsSettings {
                return "Нужен доступ к USB screen capture"
            }
            if model.usb.isManuallyPaused {
                return "USB-трансляция остановлена"
            }
            if model.usb.screenDevices.count > 1, model.usb.selectedScreenDeviceID == nil {
                return "Подключено несколько устройств"
            }
            return "Ожидаю iPhone или iPad по USB"
        }
    }

    private var summaryDetail: String {
        switch model.selectedMode {
        case .airplay:
            if model.airplay.hasLiveVideo {
                return model.isPreviewVisible
                    ? "Видео принимается. Предпросмотр открыт отдельным чистым окном."
                    : "Видео принимается. Предпросмотр закрыт — открой его кнопкой справа."
            }
            return "На iPhone/iPad открой Пункт управления → Повтор экрана → «\(model.airplay.receiverName)»."
        case .usb:
            if model.usb.phase == .running {
                return model.isPreviewVisible
                    ? "USB screen stream активен."
                    : "USB screen stream активен, но окно предпросмотра закрыто."
            }
            if model.usb.cameraPermissionNeedsSettings {
                return "Разреши MirrorLab доступ в Privacy & Security → Camera. Встроенная камера Mac не используется."
            }
            if model.usb.isManuallyPaused {
                return "Автозапуск приостановлен кнопкой «Прекратить трансляцию»."
            }
            if model.usb.screenDevices.count > 1, model.usb.selectedScreenDeviceID == nil {
                return "Выбери источник в появившемся окне или через Window → USB-источник."
            }
            return "Подключи устройство кабелем, разблокируй его и при необходимости нажми «Доверять»."
        }
    }
}

private struct AirPlayControls: View {
    @ObservedObject var controller: AirPlayController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Видео") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Качество", selection: $controller.videoQuality) {
                        ForEach(AirPlayVideoQuality.allCases) { quality in
                            Text(quality.rawValue).tag(quality)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Частота кадров", selection: $controller.preferredFrameRate) {
                        ForEach(AirPlayFrameRate.allCases) { rate in
                            Text(rate.label).tag(rate)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(controller.videoModeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Буфер Wi-Fi", selection: $controller.bufferMode) {
                        ForEach(AirPlayBufferMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(controller.bufferMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if controller.audioOutputSummary != "—" {
                        Label("Звук: \(controller.audioOutputSummary)", systemImage: "speaker.wave.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let warning = controller.audioOutputWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("AirPlay") {
                LabeledContent("Имя в «Повторе экрана»") {
                    Text(controller.receiverName)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct USBControls: View {
    @ObservedObject var controller: USBCaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("USB") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Воспроизводить системный звук", isOn: $controller.playAudio)

                    if controller.phase == .running {
                        LabeledContent("Устройство", value: controller.connectedDeviceName.isEmpty ? "iPhone / iPad" : controller.connectedDeviceName)
                    } else if controller.cameraPermissionNeedsSettings {
                        HStack {
                            Text("Доступ к USB screen capture запрещён")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Открыть настройки") {
                                controller.openCameraPrivacySettings()
                            }
                        }
                    } else if controller.screenDevices.count > 1 {
                        LabeledContent("Устройства", value: "\(controller.screenDevices.count) подключено")
                    } else if let device = controller.screenDevices.first {
                        LabeledContent("Найдено", value: device.name)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

struct ExternalPreviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.selectedMode {
            case .usb:
                if model.usb.phase == .running {
                    MetalVideoView(
                        frameStore: model.frameStore,
                        diagnostics: model.diagnostics,
                        recordsDiagnostics: true
                    )
                } else {
                    PreviewPlaceholder(text: "Ожидаю USB-поток")
                }
            case .airplay:
                ZStack {
                    AirPlayMetalVideoView(
                        presentationStore: model.airplayPresentationStore,
                        diagnostics: model.diagnostics,
                        recordsDiagnostics: true
                    )
                    if !model.airplay.hasLiveVideo {
                        PreviewPlaceholder(text: "Ожидаю AirPlay-поток")
                    }
                }
            }
        }
        .frame(minWidth: 260, minHeight: 180)
    }
}

struct PreviewControlsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var volumePopoverVisible = false

    private var volumeSymbol: String {
        switch model.outputVolume {
        case ...0.001: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    @ViewBuilder
    var body: some View {
        if model.previewControlsVisible {
            HStack(spacing: 5) {
                PreviewControlButton(systemName: "gearshape", help: "Настройки") {
                    model.showSettingsWindow()
                }
                PreviewControlButton(systemName: "minus", help: "Свернуть") {
                    model.minimizePreviewWindow()
                }
                PreviewControlButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Полный экран") {
                    model.togglePreviewFullscreen()
                }
                PreviewControlButton(systemName: "xmark", help: "Закрыть предпросмотр") {
                    model.closePreviewWindow()
                }
                PreviewControlButton(systemName: volumeSymbol, help: "Громкость") {
                    volumePopoverVisible.toggle()
                }
                .popover(isPresented: $volumePopoverVisible, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: volumeSymbol)
                                .frame(width: 18)
                            Text("Громкость")
                                .font(.headline)
                            Spacer(minLength: 12)
                            Text("\(Int((model.outputVolume * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $model.outputVolume, in: 0...1)
                            .frame(width: 210)
                    }
                    .padding(14)
                }
            }
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(2)
        }
    }
}

private struct PreviewControlButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct PreviewPlaceholder: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 44, weight: .light))
            Text(text)
                .font(.headline)
        }
        .foregroundStyle(.secondary)
    }
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    let resolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowAccessView()
        view.resolve = resolve
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowAccessView: NSView {
        var resolve: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { resolve?(window) }
        }
    }
}

struct DiagnosticsPanelView: View {
    @ObservedObject var store: DiagnosticsStore

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Живая диагностика")
                    .font(.headline)
                HStack(spacing: 8) {
                    MetricCard(title: "Получено", value: fps(store.snapshot.receivedFPS), detail: "FPS")
                    MetricCard(
                        title: "Показано",
                        value: fps(store.snapshot.externalRenderedFPS ?? store.snapshot.renderedFPS),
                        detail: "render FPS"
                    )
                    MetricCard(
                        title: "Источник",
                        value: store.snapshot.upstreamReportedFPS.map { fps($0) } ?? "—",
                        detail: "NTP cadence"
                    )
                    MetricCard(
                        title: "Буфер",
                        value: millisecondsUnsigned(store.snapshot.presentationTargetLatencyMS),
                        detail: "queue \(store.snapshot.presentationQueueDepth)f"
                    )
                    MetricCard(
                        title: "A/V Δ",
                        value: milliseconds(store.snapshot.audioVideoDeltaMS),
                        detail: "+ = звук позже"
                    )
                    MetricCard(
                        title: "Пропуски",
                        value: "\(store.snapshot.captureDroppedFrames + store.snapshot.rendererSkippedFrames + store.snapshot.externalQueueDrops + store.snapshot.presentationDroppedFrames)",
                        detail: "capture + render"
                    )
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("События")
                    .font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(store.events.suffix(40).reversed()) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Circle()
                                    .fill(color(for: event.level))
                                    .frame(width: 6, height: 6)
                                Text(event.message)
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity)
        }
        .padding(14)
    }

    private func fps(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private func milliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.1f ms", value)
    }

    private func millisecondsUnsigned(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f ms", value)
    }

    private func color(for level: DiagnosticLevel) -> Color {
        switch level {
        case .info: return .green
        case .warning: return .yellow
        case .error: return .red
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 100, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct PhaseBadge: View {
    let text: String
    let active: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(active ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }
}
