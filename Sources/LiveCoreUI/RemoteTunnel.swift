#if os(macOS)
import AppKit
import Darwin

/// Online access to the Web Controller.
/// Cloudflare quick tunnel (0.45.0): the free `cloudflared` tool gives an
/// https://….trycloudflare.com address that reaches the controller from any network. The Host
/// header is rewritten to "localhost" so the server's DNS-rebinding guard still applies.
/// (The Tailscale method of 0.61.0 was removed in 0.76.1.) The PIN and its lockout protect the page as on the local network.
final class RemoteTunnel: ObservableObject {
    @Published private(set) var url: String?
    @Published private(set) var running = false
    @Published private(set) var error: String?
    private var process: Process?
    private var quitObserver: NSObjectProtocol?
    private var output = ""

    init() {
        Self.killOrphans()
        // The tunnel is a separate process: end it when LiveCore quits.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: nil, queue: .main) { [weak self] _ in self?.stop() }
    }

    static let searchPaths = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", "/usr/bin/cloudflared"]
    static var executable: String? { searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) } }

    var isInstalled: Bool { Self.executable != nil }

    func start(port: Int) {
        stop()
        guard let exe = Self.executable else {
            error = "cloudflared is not installed. Install it with Homebrew: brew install cloudflared"
            return
        }
        let target = "http://127.0.0.1:\(port)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["tunnel", "--no-autoupdate", "--url", target, "--http-host-header", "localhost"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        output = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(text) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                Self.forget(pid: proc.processIdentifier)
                self.running = false; self.url = nil; self.process = nil
                if proc.terminationStatus != 0 && proc.terminationReason != .uncaughtSignal {
                    let last = self.output.split(separator: "\n").last.map(String.init) ?? ""
                    self.error = "Tunnel stopped (code \(proc.terminationStatus)). " + (last.isEmpty ? "Check the internet connection." : last)
                }
            }
        }
        do {
            try p.run()
            process = p; running = true; error = nil; url = nil
            Self.remember(pid: p.processIdentifier)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func consume(_ text: String) {
        output += text
        if output.count > 8000 { output = String(output.suffix(4000)) }
        if url == nil, let r = text.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression) { url = String(text[r]) }
    }

    func stop() {
        if let p = process {
            process = nil
            Self.forget(pid: p.processIdentifier)
            p.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
        }
        running = false
        url = nil
    }

    deinit { process?.terminate() }

    // MARK: Orphans

    /// Tunnel processes still running from a previous launch that crashed or was force-quit
    /// (a child process outlives its parent on macOS) are ended at the next launch.
    private static let pidsKey = "remote.tunnelPIDs"
    private static var cleaned = false

    /// Saved as "pid:startTime" so a reused process id is
    /// never touched.
    private static func startTime(_ pid: Int32) -> Int? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n == Int32(MemoryLayout<proc_bsdinfo>.size) ? Int(info.pbi_start_tvsec) : nil
    }
    private static func remember(pid: Int32) {
        guard let t = startTime(pid) else { return }
        var a = UserDefaults.standard.stringArray(forKey: pidsKey) ?? []
        a.append("\(pid):\(t)"); UserDefaults.standard.set(a, forKey: pidsKey)
    }
    private static func forget(pid: Int32) {
        let a = (UserDefaults.standard.stringArray(forKey: pidsKey) ?? []).filter { !$0.hasPrefix("\(pid):") }
        UserDefaults.standard.set(a, forKey: pidsKey)
    }
    static func killOrphans() {
        guard !cleaned else { return }
        cleaned = true
        let saved = UserDefaults.standard.stringArray(forKey: pidsKey) ?? []
        UserDefaults.standard.removeObject(forKey: pidsKey)
        for entry in saved {
            let parts = entry.split(separator: ":")
            guard parts.count == 2, let pid = Int32(parts[0]), let t = Int(parts[1]), startTime(pid) == t else { continue }
            var buf = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            if searchPaths.contains(String(cString: buf)) { kill(pid, SIGINT) }
        }
    }
}
#endif
