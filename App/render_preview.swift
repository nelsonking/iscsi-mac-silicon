// Offscreen renderer: snapshots the real SwiftUI views (with sample data) to
// PNGs via ImageRenderer, so we can eyeball the actual app UI without a display.
//   Compiled together with Sources/*.swift (except iSCSIApp.swift).
import SwiftUI
import AppKit

@MainActor
func snapshot<V: View>(_ view: V, _ path: String, scale: CGFloat = 2) {
    let r = ImageRenderer(content: view)
    r.scale = scale
    guard let img = r.nsImage,
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("FAILED \(path)"); return
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

@main
struct PreviewMain {
    static func main() { MainActor.assumeIsolated { renderAll() } }
}

@MainActor
func renderAll() {
    let c = ISCSIController()
    let s = SystemStatus()
    s.sip = .ok; s.kext = .ok; s.daemon = .ok

    var t = Target(name: "My NAS", portalHost: "192.168.1.100", portalPort: 3260,
                   iqn: "iqn.2010-01.com.example:target0")
    t.autoConnect = true
    var t2 = Target(name: "backup-2", portalHost: "192.168.1.100", iqn: "iqn.2010-01.com.example:backup")
    c.targets = [t, t2]
    c.selection = t.id
    var rt = TargetRuntime()
    rt.state = .mounted; rt.bsdDisk = "disk4"; rt.mountPoint = "/Volumes/MyNAS"
    rt.volumeName = "My NAS"; rt.fsType = "APFS"
    rt.totalBytes = 429_000_000_000; rt.usedBytes = 1_048_576
    rt.since = Date().addingTimeInterval(-725)
    c.runtime[t.id] = rt

    let bg = Color(nsColor: .windowBackgroundColor)

    snapshot(DetailView(controller: c, status: s, target: t, onSetup: {})
                .frame(width: 560, height: 470).background(bg),
             "/tmp/prev_detail.png")

    snapshot(MenuBarContent(controller: c, status: s)
                .frame(width: 300).background(.regularMaterial).environment(\.colorScheme, .dark),
             "/tmp/prev_menu.png")

    snapshot(AddTargetSheet(controller: c)
                .background(bg),
             "/tmp/prev_add.png")

    var s2 = SystemStatus(); s2.sip = .bad; s2.kext = .bad; s2.daemon = .bad
    snapshot(OnboardingView(status: s2, isPresented: .constant(true))
                .frame(width: 560, height: 500).background(bg),
             "/tmp/prev_onboard.png")
}
