import Foundation
import Combine
import AppKit

/// Orchestrates iscsictl / diskutil to connect, disconnect and inspect targets.
@MainActor
final class ISCSIController: ObservableObject {
    @Published var targets: [Target] = []
    @Published var runtime: [UUID: TargetRuntime] = [:]
    @Published var selection: UUID? = nil
    @Published var busy: Set<UUID> = []
    @Published var lastError: String? = nil

    nonisolated static let iscsictl = "/usr/local/bin/iscsictl"

    private var refreshTimer: Timer?
    private var rateTimer: Timer?
    private var refreshUsers = 0
    @Published var rates: [UUID: Double] = [:]

    init() {
        targets = TargetStorage.load()
        selection = targets.first?.id
        scheduleAutoConnect()
    }

    /// Starts the periodic re-probe timer. Runs only while the management
    /// window is on screen (started from the window's onAppear); stopped from
    /// its onDisappear so no timer spins when the app is backgrounded.
    func startPeriodicRefresh() {
        refreshUsers += 1
        guard refreshUsers == 1 else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.targets.isEmpty else { return }
                self.refreshAll()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t

        // Real-time throughput via iostat (same source as the detail view),
        // on its own cadence so the ~1s iostat run doesn't back up.
        let rt = Timer(timeInterval: 1.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.targets.isEmpty else { return }
                self.sampleRates()
            }
        }
        RunLoop.main.add(rt, forMode: .common)
        rateTimer = rt
    }

    func stopPeriodicRefresh() {
        guard refreshUsers > 0 else { return }
        refreshUsers -= 1
        guard refreshUsers == 0 else { return }
        refreshTimer?.invalidate(); refreshTimer = nil
        rateTimer?.invalidate(); rateTimer = nil
    }

    /// Samples each mounted target's throughput via iostat and stores MB/s in
    /// `rates`. Runs off the main thread (iostat blocks ~1s); results are
    /// published back on the main actor.
    private func sampleRates() {
        for t in targets {
            guard rt(t.id).isMounted, let disk = rt(t.id).bsdDisk else { continue }
            Task.detached(priority: .utility) {
                let r = Shell.run("/usr/sbin/iostat", ["-d", "-w", "1", "-c", "2", disk], timeout: 6)
                let mb = DiskMonitor.parseMBs(r.out)
                await MainActor.run { self.rates[t.id] = mb }
            }
        }
    }

    /// On launch, connect any targets flagged "connect at login". Deferred so the
    /// kext/daemon have a moment to come up; failures surface quietly in the row.
    private func scheduleAutoConnect() {
        let autos = targets.filter { $0.autoConnect }
        guard !autos.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            for t in autos where !self.rt(t.id).isConnected { self.connect(t.id) }
        }
    }

    var connectedCount: Int { runtime.values.filter { $0.isConnected }.count }

    func rt(_ id: UUID) -> TargetRuntime { runtime[id] ?? TargetRuntime() }
    func isBusy(_ id: UUID) -> Bool { busy.contains(id) }

    // MARK: - CRUD

    func add(_ t: Target, connect: Bool) {
        targets.append(t)
        TargetStorage.save(targets)
        selection = t.id
        if connect { self.connect(t.id) }
    }

    func remove(_ id: UUID) {
        if rt(id).isConnected { disconnect(id) }
        // Purge the target from the daemon's preference store too; otherwise
        // "iscsictl list targets" and a relaunch of the App keep showing it.
        // Safe to do here because disconnect() above already logged out.
        if let t = targets.first(where: { $0.id == id }) {
            _ = Shell.runPrivileged([Self.iscsictl, "remove", "target", t.ctlTarget], timeout: 15)
        }
        targets.removeAll { $0.id == id }
        runtime[id] = nil
        TargetStorage.save(targets)
        if selection == id { selection = targets.first?.id }
    }

    func update(_ t: Target) {
        guard let i = targets.firstIndex(where: { $0.id == t.id }) else { return }
        targets[i] = t
        TargetStorage.save(targets)
    }

    // MARK: - Connect / disconnect

    func connect(_ id: UUID) {
        guard let t = targets.first(where: { $0.id == id }), !busy.contains(id) else { return }
        busy.insert(id)
        var r = rt(id); r.state = .connecting; runtime[id] = r
        Task.detached(priority: .userInitiated) {
            let result = Self.doConnect(t)
            await MainActor.run {
                self.busy.remove(id)
                switch result {
                case .success(let disk):
                    var rr = self.rt(id)
                    rr.state = .connected
                    rr.since = Date()
                    // Pin the disk we (likely) saw during the connect-time poll
                    // so refreshRuntime doesn't treat the connection as "never
                    // had a disk" if the IOMedia node briefly flickers away.
                    if let disk { rr.bsdDisk = disk }
                    self.runtime[id] = rr
                    self.refreshRuntime(id, settleDelay: 1.2)
                case .failure(let msg):
                    var rr = self.rt(id)
                    rr.state = .failed(msg)
                    self.runtime[id] = rr
                    self.lastError = msg
                }
            }
        }
    }

    func disconnect(_ id: UUID) {
        guard let t = targets.first(where: { $0.id == id }), !busy.contains(id) else { return }
        busy.insert(id)
        Task.detached(priority: .userInitiated) {
            // Best-effort: unmount the volume first so macOS doesn't complain.
            if let disk = await self.rt(id).bsdDisk {
                _ = Shell.run("/usr/sbin/diskutil", ["unmountDisk", "force", "/dev/\(disk)"], timeout: 20)
            }
            // Disable auto-login/persistent first, otherwise the daemon re-logs
            // in right after this manual logout (they're enabled by doConnect).
            _ = Shell.runPrivileged([Self.iscsictl, "modify", "target-config", t.ctlTarget,
                                     "-auto-login", "disable", "-persistent", "disable"], timeout: 15)
            let r = Shell.runPrivileged([Self.iscsictl, "logout", t.iqn], timeout: 30)
            await MainActor.run {
                self.busy.remove(id)
                var rr = TargetRuntime()
                if !r.ok && !r.combined.lowercased().contains("not") { self.lastError = r.combined }
                rr.state = .offline
                self.runtime[id] = rr
            }
        }
    }

    private enum ConnOutcome { case success(disk: String?); case failure(String) }

    /// Mirrors the proven login.sh path: disable discovery, static add, login.
    nonisolated private static func doConnect(_ t: Target) -> ConnOutcome {
        // Discovery has a separate known crash bug; static login never needs it.
        _ = Shell.runPrivileged([iscsictl, "modify", "discovery-config", "-SendTargets", "disable"], timeout: 15)
        _ = Shell.runPrivileged([iscsictl, "remove", "discovery-portal", t.portalHost], timeout: 15)
        _ = Shell.runPrivileged([iscsictl, "add", "target", t.ctlTarget], timeout: 15)
        if t.hasCHAP {
            _ = Shell.runPrivileged([iscsictl, "modify", "target-config", t.ctlTarget,
                                     "-authentication", "CHAP",
                                     "-CHAPName", t.chapUser,
                                     "-CHAPSecret", t.chapSecret], timeout: 15)
        }
        // Let the daemon handle reconnect: "persistent" re-logs in after a
        // dropped link (network restored), "auto-login" re-logs in on daemon
        // start. The App's own launch-time connect becomes a backstop.
        _ = Shell.runPrivileged([iscsictl, "modify", "target-config", t.ctlTarget,
                                 "-auto-login", "enable", "-persistent", "enable"], timeout: 15)
        let login = Shell.runPrivileged([iscsictl, "login", t.iqn], timeout: 45)
        // "login" may report success even before the LUN attaches; verify by
        // waiting briefly for a matching block device to appear, and remember
        // which disk we found so the caller can pin it to this target.
        for _ in 0..<10 {
            if let disk = findDisk(for: t) { return .success(disk: disk) }
            Thread.sleep(forTimeInterval: 0.6)
        }
        if login.ok { return .success(disk: nil) }  // logged in, disk may still be settling
        return .failure(login.combined.isEmpty ? "iscsictl login failed" : login.combined)
    }

    // MARK: - Runtime discovery (disk + mount + capacity)

    func refreshAll() {
        for t in targets { refreshRuntime(t.id, settleDelay: 0) }
    }

    func refreshRuntime(_ id: UUID, settleDelay: TimeInterval) {
        guard let t = targets.first(where: { $0.id == id }) else { return }
        Task.detached(priority: .utility) {
            if settleDelay > 0 { Thread.sleep(forTimeInterval: settleDelay) }
            // The iSCSI LUN's IOMedia node can take a moment to stabilise in the
            // IORegistry after login, even after the connect-time poll already
            // saw it once. Poll a few times so a transient nil probe (e.g. the
            // APFS container still being synthesised) doesn't make us throw away
            // a valid connection below.
            let info = Self.probeWithRetry(t)
            await MainActor.run {
                var rr = self.rt(id)
                // Preserve a fresh "connecting"/"failed" state set by an in-flight op.
                if self.busy.contains(id) { return }
                if let info = info {
                    rr.bsdDisk = info.disk
                    rr.mountPoint = info.mount
                    rr.volumeName = info.volume
                    rr.fsType = info.fs
                    rr.totalBytes = info.total
                    rr.usedBytes = info.used
                    // readWriteCounts 失败时 probe 返回 -1；此时跳过累计更新，
                    // 保持上次的累计值（累计用于详情页展示，实时速率另走 iostat）。
                    if info.readBytes >= 0 && info.writtenBytes >= 0 {
                        rr.totalReadBytes = info.readBytes
                        rr.totalWrittenBytes = info.writtenBytes
                    }
                    rr.state = info.mount != nil ? .mounted : .connected
                    if rr.since == nil { rr.since = Date() }
                } else if rr.isConnected {
                    // Only drop to offline if we had previously reached "mounted"
                    // (a successful probe saw both disk and mount) and the disk
                    // has since genuinely disappeared. If we're still just
                    // "connected" (probe hasn't succeeded yet), keep the state so
                    // a late-attaching LUN isn't marked as dropped.
                    if rr.isMounted {
                        rr = TargetRuntime()
                    }
                }
                self.runtime[id] = rr
            }
        }
    }

    /// Polls probe() a few times so a transient nil (IOMedia still settling)
    /// doesn't get treated as "no disk". Kept as a separate function so the
    /// caller binds the result to a `let` (avoids a captured-var concurrency
    /// warning inside Task.detached).
    nonisolated private static func probeWithRetry(_ t: Target) -> Probe? {
        if let info = probe(t) { return info }
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.6)
            if let info = probe(t) { return info }
        }
        return nil
    }

    struct Probe { let disk: String; let mount: String?; let volume: String?; let fs: String?; let total: Int64; let used: Int64; let readBytes: Int64; let writtenBytes: Int64 }

    /// Find the iSCSI-backed disk for a target and read its mount/capacity and
    /// cumulative read/write byte counts.
    nonisolated private static func probe(_ t: Target) -> Probe? {
        guard let disk = findDisk(for: t) else { return nil }
        // Look at the whole disk + any APFS/HFS volume on it.
        let mountInfo = mountInfo(forDisk: disk)
        let rw = IOKitDiskFinder.readWriteCounts(for: t.iqn)
        return Probe(disk: disk, mount: mountInfo?.mount, volume: mountInfo?.volume,
                     fs: mountInfo?.fs, total: mountInfo?.total ?? 0, used: mountInfo?.used ?? 0,
                     readBytes: rw?.readBytes ?? -1, writtenBytes: rw?.writtenBytes ?? -1)
    }

    /// Find the iSCSI-backed disk for a target by matching its IQN against the
    /// IORegistry (HBA → target entry → whole-disk IOMedia → BSD name). This
    /// binds each target to its own disk so disconnect/unmount never touches
    /// another target's volume. Returns nil if the LUN hasn't attached yet.
    nonisolated static func findDisk(for t: Target) -> String? {
        IOKitDiskFinder.findDiskForIQN(t.iqn)
    }

    struct MountInfo { let mount: String?; let volume: String?; let fs: String?; let total: Int64; let used: Int64 }

    nonisolated private static func mountInfo(forDisk disk: String) -> MountInfo? {
        // Build the set of device nodes that could hold the mounted filesystem.
        // For a plain-partitioned disk that's the partitions themselves; for an
        // APFS disk the mounted volume lives on the *synthesized* container disk
        // (diskN → diskNs2 → APFSContainerReference diskM → diskMs1), which is
        // NOT listed under `diskutil list <diskN>`, so we resolve it explicitly.
        var candidates: [String] = [disk]
        let r = Shell.run("/usr/sbin/diskutil", ["list", "-plist", disk], timeout: 8)
        if let data = r.out.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let all = plist["AllDisksAndPartitions"] as? [[String: Any]] {
            for d in all {
                if let parts = d["Partitions"] as? [[String: Any]] {
                    for p in parts {
                        guard let id = p["DeviceIdentifier"] as? String else { continue }
                        candidates.append(id)
                        if (p["Content"] as? String) == "Apple_APFS" {
                            candidates += apfsVolumes(ofPartition: id)
                        }
                    }
                }
                if let apfs = d["APFSVolumes"] as? [[String: Any]] {
                    candidates += apfs.compactMap { $0["DeviceIdentifier"] as? String }
                }
            }
        }
        var seen = Set<String>()
        for dev in candidates where seen.insert(dev).inserted {
            let info = Shell.run("/usr/sbin/diskutil", ["info", "-plist", dev], timeout: 8)
            guard let idata = info.out.data(using: .utf8),
                  let ip = try? PropertyListSerialization.propertyList(from: idata, options: [], format: nil) as? [String: Any] else { continue }
            let mounted = (ip["MountPoint"] as? String) ?? ""
            if !mounted.isEmpty {
                let total = (ip["TotalSize"] as? NSNumber)?.int64Value ?? 0
                let free = (ip["FreeSpace"] as? NSNumber)?.int64Value ?? (ip["VolumeAvailableSpace"] as? NSNumber)?.int64Value ?? 0
                let volume = ip["VolumeName"] as? String
                let fs = ip["FilesystemName"] as? String ?? ip["FilesystemType"] as? String
                return MountInfo(mount: mounted, volume: volume, fs: fs, total: total, used: max(0, total - free))
            }
        }
        return MountInfo(mount: nil, volume: nil, fs: nil, total: 0, used: 0)
    }

    /// Resolve an Apple_APFS partition (e.g. disk4s2) to the volume device nodes
    /// on its synthesized container (e.g. disk5s1, disk5s2 …).
    nonisolated private static func apfsVolumes(ofPartition part: String) -> [String] {
        let info = Shell.run("/usr/sbin/diskutil", ["info", "-plist", part], timeout: 8)
        guard let idata = info.out.data(using: .utf8),
              let ip = try? PropertyListSerialization.propertyList(from: idata, options: [], format: nil) as? [String: Any],
              let container = ip["APFSContainerReference"] as? String else { return [] }
        let list = Shell.run("/usr/sbin/diskutil", ["list", "-plist", container], timeout: 8)
        guard let ldata = list.out.data(using: .utf8),
              let lp = try? PropertyListSerialization.propertyList(from: ldata, options: [], format: nil) as? [String: Any],
              let all = lp["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        var vols: [String] = []
        for d in all {
            if let apfs = d["APFSVolumes"] as? [[String: Any]] {
                vols += apfs.compactMap { $0["DeviceIdentifier"] as? String }
            }
        }
        return vols
    }

    // MARK: - Discovery (best effort)

    func discover(host: String, port: Int, completion: @escaping ([String]) -> Void) {
        Task.detached(priority: .userInitiated) {
            _ = Shell.runPrivileged([Self.iscsictl, "add", "discovery-portal", host], timeout: 15)
            let r = Shell.run(Self.iscsictl, ["list", "targets"], timeout: 15)
            let iqns = r.out.split(separator: "\n").compactMap { line -> String? in
                let s = line.trimmingCharacters(in: .whitespaces)
                return s.hasPrefix("iqn.") ? String(s.split(separator: " ").first ?? "") : nil
            }
            await MainActor.run { completion(Array(Set(iqns)).sorted()) }
        }
    }

    // MARK: - Finder

    func revealInFinder(_ id: UUID) {
        if let mp = rt(id).mountPoint {
            NSWorkspace.shared.selectFile(mp, inFileViewerRootedAtPath: mp)
        }
    }
}
