import SwiftUI
import AppKit

struct MainWindow: View {
    @ObservedObject var controller: ISCSIController
    @ObservedObject var status: SystemStatus
    @State private var showAdd = false
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 260)
        } detail: {
            Group {
                if let sel = controller.selection, let t = controller.targets.first(where: { $0.id == sel }) {
                    DetailView(controller: controller, status: status, target: t, onSetup: { showOnboarding = true })
                } else {
                    emptyDetail
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { controller.refreshAll(); status.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("common.refresh"))
            }
        }
        .sheet(isPresented: $showAdd) {
            AddTargetSheet(controller: controller)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(status: status, isPresented: $showOnboarding)
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestAddTarget)) { _ in showAdd = true }
        .onAppear {
            status.refresh(); controller.refreshAll()
            if status.needsSetup { showOnboarding = true }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if status.needsSetup {
                Button { showOnboarding = true } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(L("err.needSetup")).font(.system(size: 11.5, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8).padding(.top, 8)
            }

            List(selection: $controller.selection) {
                Section(L("app.name") + " · Targets") {
                    ForEach(controller.targets) { t in
                        let rt = controller.rt(t.id)
                        HStack(spacing: 10) {
                            StatusDot(color: Theme.statusColor(rt), size: 9, halo: rt.isConnected)
                            Text(t.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer()
                            if controller.isBusy(t.id) { ProgressView().controlSize(.small) }
                        }
                        .tag(t.id)
                        .contextMenu {
                            if rt.isConnected {
                                Button(L("common.disconnect")) { controller.disconnect(t.id) }
                                if rt.isMounted { Button(L("common.reveal")) { controller.revealInFinder(t.id) } }
                            } else {
                                Button(L("common.connect")) { controller.connect(t.id) }.disabled(status.needsSetup)
                            }
                            Divider()
                            Button(L("common.remove"), role: .destructive) { controller.remove(t.id) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button { showAdd = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus"); Text(L("menu.addTarget")); Spacer()
                }
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .padding(.horizontal, 14).padding(.vertical, 9)
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.wifi")
                .font(.system(size: 46, weight: .thin)).foregroundStyle(.tertiary)
            Text(L("detail.empty.title")).font(.system(size: 17, weight: .semibold))
            Text(L("detail.empty.sub")).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L("menu.addTarget")) { showAdd = true }.controlSize(.large).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
