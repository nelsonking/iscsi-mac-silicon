import SwiftUI
import AppKit

struct DetailView: View {
    @ObservedObject var controller: ISCSIController
    @ObservedObject var status: SystemStatus
    let target: Target
    var onSetup: () -> Void
    @StateObject private var monitor = DiskMonitor()

    private var rt: TargetRuntime { controller.rt(target.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                connectionCard
                if rt.isMounted { diskCard }
                if case .failed(let msg) = rt.state { errorCard(msg) }
            }
            .padding(24)
        }
        .onAppear { syncMonitor() }
        .onChange(of: rt.bsdDisk) { _ in syncMonitor() }
        .onChange(of: rt.state) { _ in syncMonitor() }
        .onDisappear { monitor.stop() }
    }

    private func syncMonitor() {
        if rt.isMounted, let d = rt.bsdDisk { monitor.start(disk: d) } else { monitor.stop() }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 15) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.14)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 52, height: 52)
                    .overlay(Image(systemName: "externaldrive.fill").font(.system(size: 21)).foregroundStyle(.white.opacity(0.92)))
                if rt.isConnected {
                    Circle().fill(Color(nsColor: .systemGreen)).frame(width: 20, height: 20)
                        .overlay(Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2.5))
                        .offset(x: 4, y: 4)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(target.name).font(.system(size: 20, weight: .bold))
                HStack(spacing: 8) {
                    statusPill
                    if rt.isConnected, let since = rt.since {
                        Text("\(L("detail.sessionFor")) · \(relative(since))")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            actionButton
        }
    }

    private var statusPill: some View {
        let c = Theme.statusColor(rt)
        return HStack(spacing: 6) {
            StatusDot(color: c, size: 7, halo: false)
            Text(Theme.statusText(rt)).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(c)
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(c.opacity(0.15), in: Capsule())
    }

    @ViewBuilder private var actionButton: some View {
        if controller.isBusy(target.id) {
            ProgressView().controlSize(.small).padding(.trailing, 4)
        } else if rt.isConnected {
            Button(role: .destructive) { controller.disconnect(target.id) } label: {
                Label(L("common.disconnect"), systemImage: "eject").labelStyle(.titleAndIcon)
            }.controlSize(.large)
        } else {
            Button { status.needsSetup ? onSetup() : controller.connect(target.id) } label: {
                Label(L("common.connect"), systemImage: "bolt.fill").labelStyle(.titleAndIcon)
            }.controlSize(.large).buttonStyle(.borderedProminent)
        }
    }

    // MARK: cards

    private var connectionCard: some View {
        Card(L("detail.connInfo")) {
            InfoRow(key: L("detail.portal"), value: target.portal, mono: true)
            InfoRow(key: L("detail.iqn"), value: target.iqn, mono: true)
            InfoRow(key: L("detail.auth"), value: target.hasCHAP ? "CHAP · \(target.chapUser)" : L("common.none"))
            InfoRow(key: L("detail.autoconnect"),
                    value: target.autoConnect ? L("detail.on") : L("detail.off"),
                    valueColor: target.autoConnect ? Color(nsColor: .systemGreen) : .secondary)
        }
    }

    private var diskCard: some View {
        Card(L("detail.disk")) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(colors: [Color(red: 0, green: 0.48, blue: 1), Color(red: 0.42, green: 0.36, blue: 1)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "internaldrive").font(.system(size: 17)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(rt.volumeName ?? target.name)  ·  /dev/\(rt.bsdDisk ?? "—")  ·  \(rt.fsType ?? "")")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(humanBytes(rt.usedBytes)) / \(humanBytes(rt.totalBytes)) · \(L("detail.mountedAt")) \(rt.mountPoint ?? "")")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Text(L("detail.readWrite", humanBytes(rt.totalReadBytes), humanBytes(rt.totalWrittenBytes)))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    ProgressView(value: Double(rt.usedBytes), total: Double(max(rt.totalBytes, 1)))
                        .progressViewStyle(.linear).tint(.accentColor).frame(height: 6).padding(.top, 3)
                }
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(String(format: "%.2f", monitor.mbPerSec))
                            .font(.system(size: 17, weight: .bold)).monospacedDigit()
                        Text("MB/s").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Sparkline(values: monitor.history).frame(width: 84, height: 22)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .overlay(Divider(), alignment: .top)
        }
    }

    private func errorCard(_ msg: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("status.error"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.red)
                Text(msg).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button(L("common.retry")) { controller.connect(target.id) }.controlSize(.small)
            }
            .padding(16)
        }
    }

    private func relative(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s/60)m" }
        return "\(s/3600)h \((s%3600)/60)m"
    }
}

/// Minimal endpoint-emphasised sparkline.
struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 1)
            let n = max(values.count - 1, 1)
            let w = geo.size.width, h = geo.size.height
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i == values.count - 1 ? AnyShapeStyle(Color(nsColor: .systemGreen)) : AnyShapeStyle(Color(nsColor: .systemGreen).opacity(0.55)))
                        .frame(height: max(2, h * CGFloat(v / maxV)))
                }
            }
            .frame(width: w, height: h, alignment: .bottom)
        }
    }
}
