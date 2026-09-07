import SwiftUI
import AppKit

struct MenuBarContent: View {
    @ObservedObject var controller: ISCSIController
    @ObservedObject var status: SystemStatus
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if status.needsSetup {
                setupBanner
            }

            if controller.targets.isEmpty {
                Text(L("detail.empty.sub"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20).padding(.vertical, 16)
            } else {
                VStack(spacing: 2) {
                    ForEach(controller.targets) { t in row(t) }
                }
                .padding(6)
            }

            Divider()
            VStack(spacing: 2) {
                menuButton("macwindow", L("menu.openManager"), shortcut: "⌘,") { openManager() }
                menuButton("power", L("common.quit"), tint: .secondary) { NSApplication.shared.terminate(nil) }
            }
            .padding(6)
        }
        .onAppear { status.refresh(); controller.refreshAll(); controller.startPeriodicRefresh() }
        .onDisappear { controller.stopPeriodicRefresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [Color(red: 0, green: 0.48, blue: 1), Color(red: 0.42, green: 0.36, blue: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "externaldrive.badge.wifi").font(.system(size: 14, weight: .medium)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 1) {
                Text(L("app.name")).font(.system(size: 13, weight: .semibold))
                Text(controller.connectedCount > 0 ? L("menu.connected.n", controller.connectedCount) : L("menu.none"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var setupBanner: some View {
        Button { openManager() } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(status.sip != .ok ? L("banner.sipOn") : L("banner.kextOff"))
                    .font(.system(size: 11.5)).foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.orange.opacity(0.12))
        }
        .buttonStyle(.plain)
    }

    private func row(_ t: Target) -> some View {
        let rt = controller.rt(t.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 11) {
                StatusDot(color: Theme.statusColor(rt), size: 9, halo: rt.isConnected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.name).font(.system(size: 13, weight: .medium))
                    Text(subtitle(t, rt)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.isBusy(t.id) {
                    ProgressView().controlSize(.small)
                } else if rt.isMounted {
                    Text(String(format: "%.2f MB/s", controller.rates[t.id] ?? 0))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                } else if !rt.isConnected {
                    Button(L("common.connect")) { controller.connect(t.id) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(.blue)
                        .disabled(status.needsSetup)
                }
            }
            if rt.isMounted {
                Button(L("common.reveal")) { controller.revealInFinder(t.id) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
    }

    private func subtitle(_ t: Target, _ rt: TargetRuntime) -> String {
        if rt.isMounted {
            return "\(L("status.mounted")) · \(humanBytes(rt.totalBytes))"
        } else if rt.isConnected {
            return L("status.connected")
        } else if case .failed(let msg) = rt.state {
            return msg.isEmpty ? L("status.error") : String(msg.prefix(60))
        }
        return "\(L("status.disconnected")) · \(t.portalHost)"
    }

    private func menuButton(_ icon: String, _ title: String, shortcut: String? = nil, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint == .primary ? Color.accentColor : tint).frame(width: 18)
                Text(title).font(.system(size: 13)).foregroundStyle(tint)
                Spacer()
                if let shortcut { Text(shortcut).font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
        .buttonStyle(HoverRowStyle())
    }

    private func openManager() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "manager")
    }
}

/// Row button that highlights on hover, like a native menu item.
struct HoverRowStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 7).fill(hover ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
            .onHover { hover = $0 }
    }
}

extension Notification.Name {
    static let requestAddTarget = Notification.Name("requestAddTarget")
}
