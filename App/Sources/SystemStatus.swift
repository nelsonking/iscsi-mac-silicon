import Foundation
import Combine

/// Tracks the one-time system prerequisites: SIP off, kext loaded, daemon up.
@MainActor
final class SystemStatus: ObservableObject {
    enum Check { case unknown, ok, bad }

    @Published var sip: Check = .unknown          // .ok == disabled (what we need)
    @Published var kext: Check = .unknown         // .ok == loaded
    @Published var daemon: Check = .unknown       // .ok == running
    @Published var lastRefresh: Date? = nil

    nonisolated static let kextBundleID = "com.github.iscsi-osx.iSCSIInitiator"
    nonisolated static let daemonLabel  = "com.github.iscsi-osx.iscsid"

    var allReady: Bool { sip == .ok && kext == .ok && daemon == .ok }
    var needsSetup: Bool { !allReady }

    func refresh() {
        Task.detached(priority: .userInitiated) {
            let sipOff = Self.checkSIPDisabled()
            let kextUp = Self.checkKextLoaded()
            let daemonUp = Self.checkDaemonRunning()
            await MainActor.run {
                self.sip = sipOff ? .ok : .bad
                self.kext = kextUp ? .ok : .bad
                self.daemon = daemonUp ? .ok : .bad
                self.lastRefresh = Date()
            }
        }
    }

    // csrutil status -> "System Integrity Protection status: disabled."
    nonisolated static func checkSIPDisabled() -> Bool {
        let r = Shell.run("/usr/bin/csrutil", ["status"], timeout: 8)
        return r.combined.lowercased().contains("disabled")
    }

    nonisolated static func checkKextLoaded() -> Bool {
        let r = Shell.run("/usr/bin/kmutil", ["showloaded", "--list-only"], timeout: 12)
        if r.combined.contains(kextBundleID) { return true }
        // Fallback for older tooling.
        let r2 = Shell.run("/usr/sbin/kextstat", [], timeout: 12)
        return r2.combined.contains(kextBundleID)
    }

    nonisolated static func checkDaemonRunning() -> Bool {
        let r = Shell.run("/usr/bin/pgrep", ["-f", "libexec/iscsid"], timeout: 6)
        return r.ok && !r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Load the staged kext (needs privileges). Returns nil on success or an error
    /// string. `nonisolated` so it can run off the main thread (it blocks on a
    /// privileged subprocess); it schedules a status refresh back on the main actor.
    nonisolated func loadKext() -> String? {
        let r = Shell.runPrivileged(["/usr/bin/kmutil", "load", "-p", "/Library/Extensions/iSCSIInitiator.kext"], timeout: 40)
        Task { await self.refresh() }
        return r.ok ? nil : r.combined
    }

    /// (Re)start the launchd daemon (needs privileges).
    nonisolated func startDaemon() -> String? {
        let plist = "/Library/LaunchDaemons/\(Self.daemonLabel).plist"
        _ = Shell.runPrivileged(["/bin/launchctl", "bootstrap", "system", plist], timeout: 15)
        let r = Shell.runPrivileged(["/bin/launchctl", "kickstart", "-k", "system/\(Self.daemonLabel)"], timeout: 15)
        Task { await self.refresh() }
        return r.ok ? nil : r.combined
    }
}
