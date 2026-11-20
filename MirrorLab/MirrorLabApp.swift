import AppKit
import SwiftUI

@main
struct MirrorLabApp: App {
    @StateObject private var model = AppModel()

    init() {
        // MirrorLab owns one Settings window plus independent media/tool windows.
        // Finder-style automatic tabbing can merge those lifecycles and must never
        // be offered for this application.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 560, height: 430)
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Сохранить отчёт MirrorLab…") {
                    model.exportReport()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }

            CommandGroup(after: .windowArrangement) {
                Divider()
                Button("Показать настройки") {
                    model.showSettingsWindow()
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Показать предпросмотр") {
                    model.showPreviewWindow()
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("Полный экран предпросмотра") {
                    model.togglePreviewFullscreen()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                if model.hasActiveStream {
                    Button("Прекратить трансляцию") {
                        model.stopCurrentStream()
                    }
                }

                if model.selectedMode == .usb, !model.usb.screenDevices.isEmpty {
                    Divider()
                    Menu("USB-источник") {
                        ForEach(model.usb.screenDevices) { device in
                            Button {
                                model.selectUSBSource(device.id)
                            } label: {
                                if model.usb.selectedScreenDeviceID == device.id {
                                    Label(device.name, systemImage: "checkmark")
                                } else {
                                    Text(device.name)
                                }
                            }
                        }
                    }
                }
            }

            CommandMenu("Диагностика") {
                Button("Живая диагностика…") {
                    model.showDiagnosticsWindow()
                }
                Button("Сохранить отчёт…") {
                    model.exportReport()
                }
            }
        }
    }
}
