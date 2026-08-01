import SwiftUI
import AppKit

/// The baked-in setup tutorial: checks SIP, guides through disabling it,
/// approving & loading the kext, and starting the daemon — with live status.
struct OnboardingView: View {
    @ObservedObject var status: SystemStatus
    @Binding var isPresented: Bool
    @State private var step = 0
    @State private var kextError: String?
    @State private var loadingKext = false

    private let total = 3

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(width: 560)
        .onAppear { status.refresh(); jumpToFirstUnmet() }
    }

    private func jumpToFirstUnmet() {
        if status.sip != .ok { step = 0 }
        else if status.kext != .ok || status.daemon != .ok { step = 1 }
        else { step = 2 }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("onb.step", step + 1, total)).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                progressDots
            }
            .padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 6)

            switch step {
            case 0: sipStep
            case 1: kextStep
            default: readyStep
            }
        }
        .frame(height: 430)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Circle().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }

    // MARK: Step 0 — SIP

    private var sipStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                stepHeader(icon: "lock.shield", title: L("onb.sip.title"), subtitle: L("onb.sip.why"))
                statusChip(ok: status.sip == .ok,
                           okText: L("onb.sip.disabled"), badText: L("onb.sip.enabled"))
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("onb.sip.steps").uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    numbered(1, L("onb.sip.s1"))
                    numbered(2, L("onb.sip.s2"))
                    numbered(3, L("onb.sip.s3"))
                    commandBox("csrutil disable")
                    numbered(4, L("onb.sip.s4"))
                    numbered(5, L("onb.sip.s5"))
                }
                .padding(16)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 26).padding(.vertical, 14)
        }
    }

    // MARK: Step 1 — kext + daemon

    private var kextStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                stepHeader(icon: "puzzlepiece.extension", title: L("onb.kext.title"), subtitle: L("onb.kext.why"))

                VStack(spacing: 10) {
                    checkRow(ok: status.kext == .ok, okText: L("onb.kext.loaded"), badText: L("onb.kext.notLoaded"))
                    checkRow(ok: status.daemon == .ok, okText: L("onb.daemon.running"), badText: L("onb.daemon.notRunning"))
                }

                HStack(spacing: 10) {
                    Button {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    } label: { Label(L("onb.kext.openSettings"), systemImage: "gearshape") }
                    Button {
                        loadingKext = true
                        DispatchQueue.global().async {
                            let err = status.loadKext()
                            _ = status.startDaemon()
                            DispatchQueue.main.async { kextError = err; loadingKext = false; status.refresh() }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if loadingKext { ProgressView().controlSize(.small) }
                            Text(L("onb.kext.load"))
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(loadingKext)
                }

                if let kextError {
                    Text(kextError).font(.system(size: 11, design: .monospaced)).foregroundStyle(.red)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .padding(10).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 26).padding(.vertical, 14)
        }
    }

    // MARK: Step 2 — ready

    private var readyStep: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().fill(Color(nsColor: .systemGreen).opacity(0.15)).frame(width: 96, height: 96)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundStyle(Color(nsColor: .systemGreen))
            }
            Text(L("onb.ready.title")).font(.system(size: 20, weight: .bold))
            Text(L("onb.ready.sub")).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            VStack(spacing: 8) {
                miniStatus(L("onb.sip.disabled"), status.sip == .ok)
                miniStatus(L("onb.kext.loaded"), status.kext == .ok)
                miniStatus(L("onb.daemon.running"), status.daemon == .ok)
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button(L("common.refresh")) { status.refresh() }
            Spacer()
            if step > 0 { Button("←") { step -= 1 } }
            if step == 0 {
                Button(status.sip == .ok ? L("common.continue") : L("onb.sip.recheck")) {
                    status.refresh()
                    if status.sip == .ok { step = 1 }
                }
                .buttonStyle(.borderedProminent)
            } else if step == 1 {
                Button(L("common.continue")) { status.refresh(); step = 2 }
                    .buttonStyle(.borderedProminent)
                    .disabled(status.kext != .ok || status.daemon != .ok)
            } else {
                Button(L("onb.ready.go")) { isPresented = false }.buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: bits

    private func stepHeader(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 11)
                .fill(LinearGradient(colors: [Color(red: 0, green: 0.48, blue: 1), Color(red: 0.42, green: 0.36, blue: 1)], startPoint: .top, endPoint: .bottom))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: icon).font(.system(size: 19)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusChip(ok: Bool, okText: String, badText: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color(nsColor: .systemGreen) : .orange)
            Text(ok ? okText : badText).font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background((ok ? Color.green : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }

    private func checkRow(ok: Bool, okText: String, badText: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color(nsColor: .systemGreen) : .secondary)
            Text(ok ? okText : badText).font(.system(size: 13, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
    }

    private func miniStatus(_ text: String, _ ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? Color(nsColor: .systemGreen) : .secondary)
            Text(text).font(.system(size: 12))
        }
    }

    private func numbered(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(Color.accentColor))
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func commandBox(_ cmd: String) -> some View {
        HStack {
            Text(cmd).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
            } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(L("onb.copy"))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator, lineWidth: 1))
    }
}
