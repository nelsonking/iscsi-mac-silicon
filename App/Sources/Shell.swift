import Foundation

struct CommandResult {
    let status: Int32
    let out: String
    let err: String
    var ok: Bool { status == 0 }
    var combined: String { (out + (err.isEmpty ? "" : "\n" + err)).trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Shell {
    /// Run a non-privileged command, capturing stdout/stderr.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 30) -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch {
            return CommandResult(status: -1, out: "", err: "launch failed: \(error.localizedDescription)")
        }
        // Drain concurrently to avoid pipe-buffer deadlock on large output.
        var outData = Data(); var errData = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let deadline = DispatchTime.now() + timeout
        if p.isRunning { _ = g.wait(timeout: deadline) }
        p.waitUntilExit()
        g.wait()
        return CommandResult(status: p.terminationStatus,
                             out: String(data: outData, encoding: .utf8) ?? "",
                             err: String(data: errData, encoding: .utf8) ?? "")
    }

    /// Run a privileged command. Prefers a passwordless sudoers rule installed
    /// by the .pkg (so the app is usable with zero prompts). If that is not
    /// present it falls back to a single native admin-authentication prompt via
    /// AppleScript, whose credential macOS caches for a few minutes.
    @discardableResult
    static func runPrivileged(_ argv: [String], timeout: TimeInterval = 30) -> CommandResult {
        // Fast path: sudo -n (non-interactive). Works when the sudoers drop-in exists.
        let sudoTry = run("/usr/bin/sudo", ["-n"] + argv, timeout: timeout)
        if sudoTry.status != 1 || !sudoTry.err.lowercased().contains("password") {
            // status 1 with a "password is required" message means sudoers rule missing.
            return sudoTry
        }
        // Fallback: osascript with administrator privileges (one auth prompt, cached).
        let joined = argv.map { shQuote($0) }.joined(separator: " ")
        let script = "do shell script \"\(joined.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", script], timeout: timeout)
    }

    private static func shQuote(_ s: String) -> String {
        if s.range(of: "^[A-Za-z0-9_./:=@,%-]+$", options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
