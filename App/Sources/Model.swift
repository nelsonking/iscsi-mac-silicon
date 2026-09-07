import Foundation

/// A persisted iSCSI target definition.
struct Target: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var portalHost: String
    var portalPort: Int = 3260
    var iqn: String
    var chapUser: String = ""
    var chapSecret: String = ""
    var autoConnect: Bool = false

    var portal: String { "\(portalHost):\(portalPort)" }
    var hasCHAP: Bool { !chapUser.isEmpty }
    /// The identifier iscsictl expects: "<iqn>,<portal>"
    var ctlTarget: String { "\(iqn),\(portal)" }
}

/// Live (non-persisted) runtime state discovered from the system.
struct TargetRuntime: Equatable {
    enum State: Equatable { case offline, connecting, connected, mounted, failed(String) }
    var state: State = .offline
    var bsdDisk: String? = nil          // e.g. "disk4"
    var mountPoint: String? = nil       // e.g. "/Volumes/nas"
    var volumeName: String? = nil
    var fsType: String? = nil
    var totalBytes: Int64 = 0
    var usedBytes: Int64 = 0
    var totalReadBytes: Int64 = 0
    var totalWrittenBytes: Int64 = 0
    var since: Date? = nil

    var isConnected: Bool {
        switch state { case .connected, .mounted: return true; default: return false }
    }
    var isMounted: Bool { if case .mounted = state { return true }; return false }
}

/// JSON-backed persistence in Application Support.
enum TargetStorage {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("iSCSI-for-Apple-Silicon", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("targets.json")
    }

    static func load() -> [Target] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Target].self, from: data) else { return [] }
        return list
    }

    static func save(_ targets: [Target]) {
        guard let data = try? JSONEncoder().encode(targets) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
