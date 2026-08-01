import SwiftUI
import AppKit

struct AddTargetSheet: View {
    @ObservedObject var controller: ISCSIController
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "3260"
    @State private var iqn = ""
    @State private var chapUser = ""
    @State private var chapSecret = ""
    @State private var autoConnect = false
    @State private var discovering = false
    @State private var discovered: [String] = []

    private var valid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !iqn.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text(L("add.title")).font(.system(size: 16, weight: .bold))
                Text(L("add.sub")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.top, 22).padding(.bottom, 18)

            VStack(spacing: 13) {
                field(L("add.name"), placeholder: L("add.name.ph"), text: $name, icon: "tag")
                HStack(alignment: .top, spacing: 11) {
                    field(L("add.portal"), placeholder: "192.168.1.100", text: $host, icon: "network")
                        .frame(maxWidth: .infinity)
                    field("Port", placeholder: "3260", text: $port, icon: nil)
                        .frame(width: 88)
                }
                hint(L("add.portal.hint"))

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        fieldLabel(L("add.iqn"))
                        Spacer()
                        Button(discovering ? L("common.working") : L("add.discover")) { discover() }
                            .buttonStyle(.link).font(.system(size: 11)).disabled(host.isEmpty || discovering)
                    }
                    inputBox(icon: "scope") {
                        TextField("iqn.2026-08.com.example:target0", text: $iqn)
                            .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    }
                    if !discovered.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(discovered, id: \.self) { d in
                                Button { iqn = d } label: {
                                    HStack { Image(systemName: "target").font(.system(size: 10)); Text(d).font(.system(size: 11, design: .monospaced)).lineLimit(1); Spacer() }
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                }
                                .buttonStyle(.plain).foregroundStyle(iqn == d ? Color.accentColor : .primary)
                            }
                        }
                        .padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                    }
                    hint(L("add.iqn.hint"))
                }

                HStack(spacing: 11) {
                    field(L("add.chapUser"), placeholder: L("common.optional"), text: $chapUser, icon: nil)
                    secureField(L("add.chapSecret"), placeholder: L("common.optional"), text: $chapSecret)
                }

                Toggle(isOn: $autoConnect) {
                    Text(L("detail.autoconnect")).font(.system(size: 13, weight: .medium))
                }
                .toggleStyle(.switch).tint(Color(nsColor: .systemGreen))
                .padding(.top, 2)
            }
            .padding(.horizontal, 24)

            HStack(spacing: 10) {
                Button(L("common.cancel")) { dismiss() }.controlSize(.large).keyboardShortcut(.cancelAction)
                Button {
                    save(connect: true)
                } label: { Text(L("add.connectNow")).frame(maxWidth: .infinity) }
                    .controlSize(.large).buttonStyle(.borderedProminent).disabled(!valid).keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(width: 440)
    }

    // MARK: components

    private func fieldLabel(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.2).foregroundStyle(.secondary)
    }
    private func hint(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func inputBox<C: View>(icon: String?, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.tertiary) }
            content()
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
    }
    private func field(_ label: String, placeholder: String, text: Binding<String>, icon: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            inputBox(icon: icon) {
                TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 13))
            }
        }
    }
    private func secureField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            inputBox(icon: "lock") {
                SecureField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 13))
            }
        }
    }

    private func discover() {
        discovering = true
        controller.discover(host: host, port: Int(port) ?? 3260) { list in
            discovered = list; discovering = false
            if iqn.isEmpty, let first = list.first { iqn = first }
        }
    }

    private func save(connect: Bool) {
        let t = Target(name: name.isEmpty ? host : name,
                       portalHost: host.trimmingCharacters(in: .whitespaces),
                       portalPort: Int(port) ?? 3260,
                       iqn: iqn.trimmingCharacters(in: .whitespaces),
                       chapUser: chapUser, chapSecret: chapSecret, autoConnect: autoConnect)
        controller.add(t, connect: connect)
        dismiss()
    }
}
