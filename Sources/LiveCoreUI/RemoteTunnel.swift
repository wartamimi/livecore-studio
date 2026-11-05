#if os(macOS)
import AppKit
import Darwin

/// Online access to the Web Controller.
/// - Cloudflare quick tunnel (0.45.0): the free `cloudflared` tool gives an
///   https://….trycloudflare.com address that reaches the controller from any network. The Host
///   header is rewritten to "localhost" so the server's DNS-rebinding guard still applies.
/// - Tailscale (0.61.0): `tailscale serve` publishes https://<mac>.<tailnet>.ts.net to the
///   devices signed in to the same tailnet only; `tailscale funnel` makes that address public.
///   Without either, the Mac's 100.x tailnet address works directly (shown as well).
/// The PIN and its lockout protect the page as on the local network.
final class RemoteTunnel: ObservableObject {
    enum Method: String, CaseIterable, Identifiable {
        case cloudflare, tailscale, tailscaleFunnel
        var id: String { rawValue }
        var isTailscale: Bool { self != .cloudflare }
    }

    @Published private(set) var url: String?
    @Published private(set) var running = false
    @Published private(set) var error: String?
    /// Tailscale asks for a one-time admin approval (Serve / Funnel not enabled on the tailnet).
    @Published private(set) var actionURL: String?
    /// Direct tailnet address (http://100.x.y.z:port) when Tailscale is connected.
    @Published private(set) var tailnetAddress: String?
    @Published var method: Method {
        didSet { if let persistKey { UserDefaults.standard.set(method.rawValue, forKey: persistKey) } }
    }
    private let persistKey: String?
    private var process: Process?
    private var quitObserver: NSObjectProtocol?
    private var output = ""

    /// `persistKey` remembers the chosen method (the Web Controller); nil = Cloudflare always.
    init(persistKey: String? = nil) {
        self.persistKey = persistKey
        let saved = persistKey.flatMap { UserDefaults.standard.string(forKey: $0) }.flatMap(Method.init(rawValue:))
        method = saved ?? .cloudflare
        Self.killOrphans()
        // The tunnel is a separate process: end it when LiveCore quits.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: nil, queue: .main) { [weak self] _ in self?.stop() }
    }

    static let searchPaths = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", "/usr/bin/cloudflared"]
    static var executable: String? { searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// The Tailscale CLI: the Mac app's own binary works as the CLI, or Homebrew's `tailscale`.
    static let tailscalePaths = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                                 "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/usr/bin/tailscale"]
    static var tailscaleExecutable: String? { tailscalePaths.first { FileManager.default.isExecutableFile(atPath: $0) } }

    func executable(for m: Method) -> String? { m.isTailscale ? Self.tailscaleExecutable : Self.executable }
    var isInstalled: Bool { executable(for: method) != nil }

    func start(port: Int) {
        stop()
        actionURL = nil
        guard let exe = executable(for: method) else {
            error = method.isTailscale
                ? "Tailscale is not installed. Install the Tailscale app from tailscale.com/download (or brew install tailscale) and sign in."
                : "cloudflared is not installed. Install it with Homebrew: brew install cloudflared"
            return
        }
        let target = "http://127.0.0.1:\(port)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        switch method {
        case .cloudflare:
            p.arguments = ["tunnel", "--no-autoupdate", "--url", target, "--http-host-header", "localhost"]
        case .tailscale:
            p.arguments = ["serve", target]       // foreground: removed again when the process ends
        case .tailscaleFunnel:
            p.arguments = ["funnel", target]
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        output = ""
        let m = method
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(text, method: m) }
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
            if m.isTailscale { lookupTailscale(exe: exe, port: port) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func consume(_ text: String, method m: Method) {
        output += text
        if output.count > 8000 { output = String(output.suffix(4000)) }
        let pattern = m.isTailscale ? #"https://[a-z0-9-]+(\.[a-z0-9-]+)*\.ts\.net"# : #"https://[a-z0-9-]+\.trycloudflare\.com"#
        if url == nil, let r = text.range(of: pattern, options: .regularExpression) { url = String(text[r]) }
        // "Serve is not enabled on your tailnet. To enable, visit: https://login.tailscale.com/f/serve?node=…"
        if m.isTailscale, let r = text.range(of: #"https://login\.tailscale\.com/[^\s]+"#, options: .regularExpression) {
            actionURL = String(text[r])
        }
    }

    /// Reads the Mac's MagicDNS name and 100.x address (`tailscale status --json`).
    private func lookupTailscale(exe: String, port: Int) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["status", "--json"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let me = json["Self"] as? [String: Any] else {
                DispatchQueue.main.async { if self?.url == nil { self?.error = "Tailscale is not running or not signed in. Open the Tailscale app and connect." } }
                return
            }
            let ips = (me["TailscaleIPs"] as? [String]) ?? []
            let v4 = ips.first { $0.hasPrefix("100.") }
            let dns = (me["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            DispatchQueue.main.async {
                guard let self else { return }
                self.tailnetAddress = v4.map { "http://\($0):\(port)" }
                if self.url == nil, let dns, !dns.isEmpty, self.running { self.url = "https://\(dns)" }
            }
        }
    }

    func stop() {
        if let p = process {
            process = nil
            Self.forget(pid: p.processIdentifier)
            // SIGINT lets `tailscale serve/funnel` remove its configuration before it exits.
            p.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
        }
        running = false
        url = nil
        actionURL = nil
    }

    deinit { process?.terminate() }

    // MARK: Orphans

    /// Tunnel processes still running from a previous launch that crashed or was force-quit
    /// (a child process outlives its parent on macOS) are ended at the next launch.
    private static let pidsKey = "remote.tunnelPIDs"
    private static var cleaned = false

    /// Saved as "pid:startTime" so a reused process id (for example the Tailscale app itself) is
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
            if (searchPaths + tailscalePaths).contains(String(cString: buf)) { kill(pid, SIGINT) }
        }
    }
}
#endif
