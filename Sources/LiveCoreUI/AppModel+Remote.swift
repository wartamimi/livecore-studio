#if os(macOS)
import Foundation
import LiveCoreCore
import LiveCoreEngine
import LiveCoreRemote

/// Web Controller: phones and tablets on the same network open http://<this Mac>:<port>/ and
/// drive the switcher after entering the PIN. Off until the operator turns it on; the PIN
/// lives in the Keychain and a new PIN signs every device out.
extension AppModel {
    static let remotePINAccount = "remote-pin"
    private static let remoteEnabledKey = "remoteEnabled"
    private static let remotePortKey = "remotePort"

    func startRemoteIfEnabled() {
        let p = UserDefaults.standard.integer(forKey: Self.remotePortKey)
        remotePort = (1024...65535).contains(p) ? p : RemoteServer.defaultPort
        if UserDefaults.standard.bool(forKey: Self.remoteEnabledKey) { setRemoteEnabled(true) }
    }

    public func setRemoteEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.remoteEnabledKey)
        remoteServer?.stop()
        remoteServer = nil
        remoteClients = 0
        remoteError = nil
        remoteEnabled = on
        guard on else { return }
        let pin = loadOrCreateRemotePIN()
        let server = RemoteServer(port: remotePort, pin: pin) { [weak self] cmd in self?.handleRemote(cmd) }
        do {
            try server.start()
            remoteServer = server
            remoteAddresses = RemoteServer.lanAddresses()
            pushRemoteState(clients: true)
        } catch {
            remoteError = "\(error)"
            remoteEnabled = false
            UserDefaults.standard.set(false, forKey: Self.remoteEnabledKey)
        }
    }

    /// Ports below 1024 need root on macOS.
    public func setRemotePort(_ port: Int) {
        guard (1024...65535).contains(port), port != remotePort else { return }
        remotePort = port
        UserDefaults.standard.set(port, forKey: Self.remotePortKey)
        if remoteEnabled { setRemoteEnabled(true) }
    }

    /// A fresh random PIN; devices signed in with the old one must enter the new one.
    public func newRemotePIN() {
        let pin = RemoteAuth.generatePIN()
        do {
            try KeychainStore.save(streamKey: pin, account: Self.remotePINAccount)
        } catch {
            report(error.localizedDescription)
        }
        remotePIN = pin
        remoteServer?.pin = pin
    }

    private func loadOrCreateRemotePIN() -> String {
        if let p = (try? KeychainStore.load(account: Self.remotePINAccount)) ?? nil, RemoteAuth.isValidPIN(p) {
            remotePIN = p
            return p
        }
        newRemotePIN()
        return remotePIN
    }

    /// Addresses to open on the phone (Wi-Fi / Ethernet), e.g. "http://192.168.1.20:8088".
    public var remoteURLs: [String] { remoteAddresses.map { "http://\($0):\(remotePort)" } }

    /// Refreshes what the remote page shows (5 times a second while the server runs).
    func pushRemoteState(clients: Bool) {
        guard let server = remoteServer else { return }
        let number: (InputID?) -> Int? = { id in id.flatMap { id in self.inputs.first { $0.id == id }?.number } }
        var s = RemoteState()
        s.title = projectURL?.deletingPathExtension().lastPathComponent ?? "LiveCore Studio"
        s.program = number(switcher.program)
        s.preview = number(switcher.preview)
        s.transitioning = switcher.transition != nil
        s.transition = transitionKind == .custom
            ? customTransitions.first { $0.id == customTransitionID }?.name ?? transitionKind.displayName
            : "\(transitionKind.displayName) \(String(format: "%.1f", transitionDuration)) s"
        s.tbar = tbar
        s.tbarRest = switcher.tbarRest
        s.inputs = inputs.map { .init(number: $0.number, name: $0.name, kind: "\($0.kind)") }
        s.overlays = overlays.map { .init(index: $0.index, on: $0.isOn, onPreview: $0.onPreview, input: number($0.source)) }
        s.streaming = isStreamingActive
        s.streamLocked = streamLocked
        s.recording = isRecording
        s.recordLocked = recordLocked
        s.replayAvailable = replayAvailable
        server.update(state: s.json)
        if clients {
            let n = server.activeClients()
            if n != remoteClients { remoteClients = n }
            let a = RemoteServer.lanAddresses()
            if a != remoteAddresses { remoteAddresses = a }
        }
    }

    /// Runs a remote command (main thread). Locks set in the app still apply.
    func handleRemote(_ c: RemoteCommand) {
        switch c {
        case let .action(a):
            switch a {
            case .streamToggle, .recordToggle, .fullscreenToggle, .tbar: return
            default: perform(a)
            }
        case let .tbar(v):
            setTBar(v)
        case let .stream(on):
            guard !streamLocked, on != isStreamingActive else { return }
            pendingStop = nil
            toggleStream()
        case let .record(on):
            guard !recordLocked, on != isRecording else { return }
            pendingStop = nil
            toggleRecord()
        }
        pushRemoteState(clients: false)
    }
}
#endif
