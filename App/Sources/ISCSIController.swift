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

    init() {
        targets = TargetStorage.load()
        selection = targets.first?.id
        scheduleAutoConnect()
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
                case .success:
                    var rr = self.rt(id)
                    rr.state = .connected
                    rr.since = Date()
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

    private enum ConnOutcome { case success; case failure(String) }

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
        let login = Shell.runPrivileged([iscsictl, "login", t.iqn], timeout: 45)
        // "login" may report success even before the LUN attaches; verify by
        // waiting briefly for a matching block device to appear.
        for _ in 0..<10 {
            if findDisk(for: t) != nil { return .success }
            Thread.sleep(forTimeInterval: 0.6)
        }
        if login.ok { return .success }          // logged in, disk may still be settling
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
            let info = Self.probe(t)
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
                    rr.state = info.mount != nil ? .mounted : .connected
                    if rr.since == nil { rr.since = Date() }
                } else if rr.isConnected {
                    // was connected but no disk now -> dropped
                    rr = TargetRuntime()
                }
                self.runtime[id] = rr
            }
        }
    }

    struct Probe { let disk: String; let mount: String?; let volume: String?; let fs: String?; let total: Int64; let used: Int64 }

    /// Find the iSCSI-backed disk for a target and read its mount/capacity.
    nonisolated private static func probe(_ t: Target) -> Probe? {
        guard let disk = findDisk(for: t) else { return nil }
        // Look at the whole disk + any APFS/HFS volume on it.
        let mountInfo = mountInfo(forDisk: disk)
        return Probe(disk: disk, mount: mountInfo?.mount, volume: mountInfo?.volume,
                     fs: mountInfo?.fs, total: mountInfo?.total ?? 0, used: mountInfo?.used ?? 0)
    }

    /// Scan external physical disks for one whose transport is iSCSI.
    nonisolated static func findDisk(for t: Target) -> String? {
        let list = Shell.run("/usr/sbin/diskutil", ["list", "-plist", "physical"], timeout: 12)
        guard let data = list.out.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return fallbackFindDisk()
        }
        for d in disks {
            guard let dev = d["DeviceIdentifier"] as? String else { continue }
            let info = Shell.run("/usr/sbin/diskutil", ["info", "-plist", dev], timeout: 8)
            guard let idata = info.out.data(using: .utf8),
                  let ip = try? PropertyListSerialization.propertyList(from: idata, options: [], format: nil) as? [String: Any] else { continue }
            let proto = (ip["BusProtocol"] as? String ?? "") + (ip["MediaType"] as? String ?? "")
            if proto.lowercased().contains("iscsi") { return dev }
        }
        return fallbackFindDisk()
    }

    /// If diskutil doesn't tag the protocol, fall back to the newest external disk.
    nonisolated private static func fallbackFindDisk() -> String? {
        let r = Shell.run("/usr/sbin/diskutil", ["list", "external", "physical"], timeout: 8)
        let lines = r.out.split(separator: "\n")
        var last: String? = nil
        for line in lines where line.hasPrefix("/dev/disk") {
            last = String(line.dropFirst("/dev/".count)).split(separator: " ").first.map(String.init)
        }
        return last
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
