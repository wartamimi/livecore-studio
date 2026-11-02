#if os(macOS)
import AppKit

/// Online access to the Web Controller (0.45.0) through a Cloudflare quick tunnel: the free
/// `cloudflared` tool (installed by the operator, e.g. `brew install cloudflared`) gives an
/// https://….trycloudflare.com address that reaches the controller from any network.
/// The Host header is rewritten to "localhost" so the server's DNS-rebinding guard still
/// applies; the PIN and its lockout protect the page as on the local network.
final class RemoteTunnel: ObservableObject {
    @Published private(set) var url: String?
    @Published private(set) var running = false
    @Published private(set) var error: String?
    private var process: Process?
    private var quitObserver: NSObjectProtocol?

    init() {
        // The tunnel is a separate process: end it when LiveCore quits.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: nil, queue: .main) { [weak self] _ in self?.stop() }
    }

    static let searchPaths = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", "/usr/bin/cloudflared"]
    static var executable: String? { searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) } }

    func start(port: Int) {
        stop()
        guard let exe = Self.executable else {
            error = "cloudflared is not installed. Install it with Homebrew: brew install cloudflared"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(port)", "--http-host-header", "localhost"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if let r = text.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression) {
                let found = String(text[r])
                DispatchQueue.main.async { self?.url = found }
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                self.running = false; self.url = nil; self.process = nil
                if proc.terminationStatus != 0 && proc.terminationReason != .uncaughtSignal {
                    self.error = "Tunnel stopped (code \(proc.terminationStatus)). Check the internet connection."
                }
            }
        }
        do {
            try p.run()
            process = p; running = true; error = nil; url = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        if let p = process { process = nil; p.terminate() }
        running = false
        url = nil
    }

    deinit { process?.terminate() }
}
#endif
