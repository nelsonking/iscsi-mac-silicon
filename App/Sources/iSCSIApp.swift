import SwiftUI
import AppKit

@main
struct iSCSIApp: App {
    @StateObject private var controller = ISCSIController()
    @StateObject private var status = SystemStatus()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Menu-bar quick access (custom popover window).
        MenuBarExtra {
            MenuBarContent(controller: controller, status: status)
                .frame(width: 300)
        } label: {
            MenuBarLabel(controller: controller, status: status)
        }
        .menuBarExtraStyle(.window)

        // Main management window.
        Window(L("app.name"), id: "manager") {
            MainWindow(controller: controller, status: status)
                .frame(minWidth: 720, minHeight: 460)
                .onAppear { status.refresh(); controller.refreshAll() }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 520)
    }
}

/// The menu-bar status icon. Also surfaces the management window once at launch
/// when the user still has setup to do or hasn't added any targets, so a
/// first-run user isn't stranded looking for a hidden menu-bar item.
struct MenuBarLabel: View {
    @ObservedObject var controller: ISCSIController
    @ObservedObject var status: SystemStatus
    @Environment(\.openWindow) private var openWindow
    @State private var didAutoOpen = false

    var body: some View {
        Image(systemName: controller.connectedCount > 0 ? "externaldrive.fill.badge.wifi" : "externaldrive.badge.wifi")
            .task {
                guard !didAutoOpen else { return }
                didAutoOpen = true
                status.refresh()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if status.needsSetup || controller.targets.isEmpty {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "manager")
                }
            }
    }
}
