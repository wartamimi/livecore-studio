#if os(macOS)
import AppKit
import CoreVideo
import LiveCoreCore
import LiveCoreEngine
import LiveCoreRemote

/// LCS Live (0.52.0): the small web server for guest links and call signaling (its own port,
/// separate from the Web Controller and its PIN), the optional online link through a Cloudflare
/// quick tunnel, and the TURN settings. Runs only while there is at least one LCS Live input.
final class LiveCallService: ObservableObject {
    static let shared = LiveCallService()
    static let defaultPort = 8089

    let hub = LiveCallHub()
    let tunnel = RemoteTunnel()
    @Published private(set) var port: Int?
    @Published private(set) var error: String?
    @Published private(set) var states: [InputID: LiveCallSource.CallState] = [:]
    @Published var ice: LiveCallICE {
        didSet {
            let d = UserDefaults.standard
            d.set(ice.turnURL, forKey: "lcslive.turn.url"); d.set(ice.turnUser, forKey: "lcslive.turn.user")
            d.set(ice.turnPassword, forKey: "lcslive.turn.password")
        }
    }
    private var server: RemoteServer?
    private var rooms = 0

    private init() {
        let d = UserDefaults.standard
        ice = LiveCallICE(turnURL: d.string(forKey: "lcslive.turn.url") ?? "", turnUser: d.string(forKey: "lcslive.turn.user") ?? "",
                          turnPassword: d.string(forKey: "lcslive.turn.password") ?? "")
    }

    private func ensureServer() -> Int? {
        if let s = server, s.isRunning { return s.port }
        for p in [Self.defaultPort, 0] {
            let s = RemoteServer(port: p, pin: RemoteAuth.generatePIN(), onCommand: { _ in })
            let hub = self.hub
            s.customHandler = { req, client in hub.handle(req, client: client) }
            s.maxRequestSize = 64 * 1024
            do {
                try s.start()
                server = s; port = s.port; error = nil
                return s.port
            } catch {
                self.error = "\(error)"
            }
        }
        return nil
    }

    /// Quit: ends the LCS Live server and its tunnel whatever the room count (0.61.0).
    func shutdown() {
        rooms = 0
        tunnel.stop()
        server?.stop(); server = nil; port = nil
    }

    private func stopServerIfIdle() {
        guard rooms <= 0 else { return }
        rooms = 0
        tunnel.stop()
        server?.stop(); server = nil; port = nil
    }

    /// Main thread: called by the engine for every new LCS Live input, before it starts.
    func connect(_ src: LiveCallSource, programFrame: @escaping () -> CVPixelBuffer?) {
        guard let port = ensureServer() else { return }
        src.hostURL = URL(string: "http://127.0.0.1:\(port)/live/host")
        src.iceJSON = ice.json
        src.returnFrameProvider = programFrame
        let id = src.id
        rooms += 1
        open(src)
        src.onAnswer = { [weak self, weak src] seq, sdp in
            guard let self, let src else { return }
            self.hub.setAnswer(key: src.config.key, seq: seq, sdp: sdp)
        }
        src.onCallStateChange = { [weak self] st in self?.states[id] = st }
        src.onStop = { [weak self, weak src] in
            guard let self else { return }
            if let src { self.hub.close(key: src.config.key) }
            self.states[id] = nil
            self.rooms -= 1
            self.stopServerIfIdle()
        }
        states[id] = src.callState
    }

    private func open(_ src: LiveCallSource) {
        hub.open(key: src.config.key, title: src.config.title, iceJSON: ice.json) { [weak src] ev in
            DispatchQueue.main.async {
                guard let src else { return }
                switch ev {
                case let .offer(o): src.deliverOffer(seq: o.seq, sdp: o.sdp, name: o.name)
                case let .left(seq): src.guestLeft(seq: seq)
                }
            }
        }
    }

    /// New title / return feed / TURN settings.
    func apply(_ config: ProjectLiveCall, to src: LiveCallSource) {
        src.update(config)
        src.iceJSON = ice.json
        hub.update(key: src.config.key, title: src.config.title, iceJSON: ice.json)
    }

    /// Revokes the link: the old one stops working at once.
    func newLink(_ src: LiveCallSource) {
        hub.close(key: src.config.key)
        src.replaceKey(LiveCallKey.make())
        open(src)
    }

    // MARK: Links

    func localLink(_ src: LiveCallSource) -> String? { port.map { "http://localhost:\($0)/live/\(src.config.key)" } }
    func lanLinks(_ src: LiveCallSource) -> [String] {
        guard let port else { return [] }
        return RemoteServer.lanAddresses().map { "http://\($0):\(port)/live/\(src.config.key)" }
    }
    func onlineLink(_ src: LiveCallSource) -> String? { tunnel.url.map { "\($0)/live/\(src.config.key)" } }
    func startOnline() { if let port { tunnel.start(port: port) } }
}

extension AppModel {
    func wireLiveCall(_ e: ProductionEngine) {
        e.liveCallConnector = { [weak self] src in
            LiveCallService.shared.connect(src) { [weak self] in self?.lastProgramFrame }
        }
    }

    public func addLiveCall() -> InputID? { engine?.addLiveCall(ProjectLiveCall()) }
    public func liveCallSource(_ id: InputID) -> LiveCallSource? { engine?.liveCallSource(id) }
}
#endif
