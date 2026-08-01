import Foundation
import Combine

/// Samples per-disk throughput via `iostat` and keeps a small ring buffer for
/// the detail-view sparkline. Only runs while a mounted disk is selected.
@MainActor
final class DiskMonitor: ObservableObject {
    @Published var mbPerSec: Double = 0
    @Published var history: [Double] = Array(repeating: 0, count: 32)

    private var disk: String?
    private var timer: Timer?

    func start(disk: String) {
        if self.disk == disk, timer != nil { return }
        stop()
        self.disk = disk
        history = Array(repeating: 0, count: 32)
        // iostat's own interval provides the rate; sample every ~1.4s.
        let t = Timer(timeInterval: 1.4, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        sample()
    }

    func stop() {
        timer?.invalidate(); timer = nil; disk = nil
        mbPerSec = 0
    }

    private func sample() {
        guard let disk else { return }
        Task.detached(priority: .utility) {
            // `iostat -d -w 1 -c 2 <disk>`: 2 samples 1s apart; 2nd line is the
            // live rate. Column layout: KB/t  tps  MB/s.
            let r = Shell.run("/usr/sbin/iostat", ["-d", "-w", "1", "-c", "2", disk], timeout: 6)
            let mb = Self.parseMBs(r.out)
            await MainActor.run {
                self.mbPerSec = mb
                var h = self.history; h.removeFirst(); h.append(mb); self.history = h
            }
        }
    }

    nonisolated static func parseMBs(_ out: String) -> Double {
        // Take the last numeric data row; MB/s is the 3rd column of the last group.
        let lines = out.split(separator: "\n").map(String.init)
        for line in lines.reversed() {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // A data row is all-numeric triples; grab the last triple's 3rd value.
            let nums = cols.compactMap { Double($0) }
            if nums.count >= 3 {
                return nums[2]   // MB/s of the first (only) disk column group
            }
        }
        return 0
    }
}
