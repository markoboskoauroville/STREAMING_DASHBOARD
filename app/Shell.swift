// Shell.swift: running the few command-line tools the dashboard needs (ssh to the VM, netstat, ndimon), each with a
// deadline so a hung network never freezes the window.
import Foundation

enum Shell {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(home)/.local/bin"
        return e
    }

    /// (exit status, stdout, stderr); status -1 = could not start, -2 = past the deadline (killed)
    static func run(_ exe: String, _ args: [String], input: Data? = nil, timeout: Double = 20) -> (Int32, String, String) {
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        do { try p.run() } catch { return (-1, "", "\(error)") }
        if let input {
            DispatchQueue.global().async {
                inPipe.fileHandleForWriting.write(input)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        var o = Data(), e = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        var killed = false
        if g.wait(timeout: .now() + timeout) == .timedOut {
            killed = true
            p.terminate()
            _ = g.wait(timeout: .now() + 2)
        }
        p.waitUntilExit()
        return (killed ? -2 : p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}

/// The VM, by ssh. The host alias "chromium-vm" from ~/.ssh/config (its key, BatchMode). One shared connection
/// (ControlMaster, started once, kept 10 minutes) so a poll costs one round trip instead of a new handshake each time.
/// Note: plain ssh to the VM's Tailscale address is taken by Tailscale SSH, which asks for a browser check; the alias
/// goes to the VM's own sshd. The HTTP checks (test stream, cloud mixer) do go over Tailscale.
enum VM {
    static var host: String { UserDefaults.standard.string(forKey: "vmHost") ?? "chromium-vm" }
    static let tailscale = "100.102.86.30"
    static let control = "/tmp/sdash-\(getuid())-%C"
    static var common: [String] {
        ["-C", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10", "-o", "ControlPath=\(control)"]
    }

    static func ensureMaster() {
        let (s, _, _) = Shell.run("/usr/bin/ssh", common + ["-O", "check", host], timeout: 5)
        if s == 0 { return }
        // -f: into the background after the login; its output to /dev/null so nothing waits on its pipes
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = common + ["-M", "-N", "-f", "-o", "ControlPersist=600", host]
        p.environment = Shell.env
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// a command on the VM (ControlMaster=no: with no master the client connects by itself, never becomes one)
    static func run(_ command: String, input: Data? = nil, timeout: Double = 25) -> (Int32, String, String) {
        ensureMaster()
        return Shell.run("/usr/bin/ssh", common + ["-o", "ControlMaster=no", host, command], input: input, timeout: timeout)
    }
}
