import SwiftUI
import AppKit

/// Shared visual language, mirroring the approved macOS-native mockup:
/// system materials, semantic status colours, 8pt rhythm.
enum Theme {
    static let corner: CGFloat = 11
    static let accent = Color.accentColor

    static func statusColor(_ rt: TargetRuntime) -> Color {
        switch rt.state {
        case .mounted:    return Color(nsColor: .systemGreen)
        case .connected:  return Color(nsColor: .systemGreen)
        case .connecting: return Color(nsColor: .systemOrange)
        case .failed:     return Color(nsColor: .systemRed)
        case .offline:    return Color(nsColor: .systemGray)
        }
    }

    static func statusText(_ rt: TargetRuntime) -> String {
        switch rt.state {
        case .mounted:    return L("status.connMounted")
        case .connected:  return L("status.connected")
        case .connecting: return L("status.connecting")
        case .failed:     return L("status.error")
        case .offline:    return L("status.saved")
        }
    }
}

/// A small filled status dot with a soft halo.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 9
    var halo: Bool = true
    var body: some View {
        ZStack {
            if halo {
                Circle().fill(color.opacity(0.18)).frame(width: size + 6, height: size + 6)
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size + (halo ? 6 : 0), height: size + (halo ? 6 : 0))
    }
}

/// Rounded card container with a hairline border.
struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder var content: () -> Content
    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            }
            content()
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(.separator.opacity(0.6), lineWidth: 1))
    }
}

/// A key/value line inside a Card.
struct InfoRow: View {
    let key: String
    let value: String
    var mono: Bool = false
    var valueColor: Color? = nil
    var body: some View {
        HStack(spacing: 14) {
            Text(key).foregroundStyle(.secondary).frame(width: 108, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .foregroundStyle(valueColor ?? .primary)
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(Divider(), alignment: .top)
    }
}

func humanBytes(_ b: Int64) -> String {
    guard b > 0 else { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(b); var i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return String(format: v >= 100 || i == 0 ? "%.0f %@" : "%.1f %@", v, units[i])
}
