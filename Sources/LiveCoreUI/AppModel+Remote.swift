#if os(macOS)
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
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

    /// Refreshes what the remote page shows (10 times a second while the server runs).
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
        s.transitionKind = transitionKind.rawValue
        s.transitionDuration = transitionDuration
        s.transitions = remoteTransitions
        s.recordTime = isRecording ? recordStats.duration : 0
        s.streamTime = isStreamingActive ? destinationStats.values.map(\.uptime).max() ?? 0 : 0
        let m = meters.master
        s.master = .init(id: "master", name: "Master", fader: masterFader, muted: false, levelL: Double(m.l), levelR: Double(m.r))
        s.channels = audioChannels.map { c in
            let lv = meters.levels[c.id]
            return .init(id: c.id, name: c.name, fader: c.fader, muted: c.muted,
                         levelL: Double(lv?.l ?? -120), levelR: Double(lv?.r ?? -120))
        }
        s.frames = true
        server.update(state: s.json)
        if clients {
            let n = server.activeClients()
            if n != remoteClients { remoteClients = n }
            let a = RemoteServer.lanAddresses()
            if a != remoteAddresses { remoteAddresses = a }
        }
    }

    /// Transitions offered on the remote: the built-in ones, the stinger once a clip is chosen,
    /// and the selected custom shader.
    private var remoteTransitions: [RemoteState.Choice] {
        var list = TransitionKind.allCases
            .filter { $0 != .cut && $0 != .custom && ($0 != .stinger || stinger.source != nil) }
            .map { RemoteState.Choice(id: $0.rawValue, name: $0.displayName) }
        if let id = customTransitionID, let t = customTransitions.first(where: { $0.id == id }) {
            list.append(.init(id: TransitionKind.custom.rawValue, name: t.name))
        }
        return list
    }

    /// Small JPEGs of Program and Preview for the remote page (up to 15 per second, only while a
    /// page is showing them). Encoded off the main thread; a tick is skipped while the previous
    /// pair is still encoding, so a slow Mac lowers the rate instead of queueing work.
    func pushRemoteFrames() {
        guard let server = remoteServer, server.wantsFrames() else { return }
        guard Self.remoteEncoding.mutate({ busy -> Bool in
            if busy { return false }
            busy = true
            return true
        }) else { return }
        let frames = [("program", lastProgramFrame), ("preview", lastPreviewFrame)]
        Self.remoteEncodeQueue.async {
            for case let (bus, pb?) in frames {
                if let jpeg = Self.remoteJPEG(pb) { server.setFrame(jpeg, bus: bus) }
            }
            Self.remoteEncoding.mutate { $0 = false }
        }
    }

    private static let remoteEncoding = Locked(false)

    private static let remoteEncodeQueue = DispatchQueue(label: "studio.livecore.remote.jpeg", qos: .userInitiated)
    private static let remoteCI = CIContext(options: [.cacheIntermediates: false])

    /// 640 px wide JPEG (quality 0.55).
    static func remoteJPEG(_ pb: CVPixelBuffer, width: CGFloat = 640) -> [UInt8]? {
        var img = CIImage(cvPixelBuffer: pb)
        let scale = min(1, width / max(img.extent.width, 1))
        img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = remoteCI.createCGImage(img, from: img.extent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return [UInt8](data as Data)
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
        case let .transition(kind, duration):
            if let raw = kind, let k = TransitionKind(rawValue: raw), remoteTransitions.contains(where: { $0.id == raw }) {
                if k == .custom, let id = customTransitionID { selectCustomTransition(id) } else { transitionKind = k }
            }
            if let d = duration { transitionDuration = min(5, max(0.2, d)) }
        case let .masterFader(v):
            masterFader = v
        case let .channelFader(id, v):
            audioChannels.first { $0.id == id }?.fader = v
        case let .channelMute(id, on):
            audioChannels.first { $0.id == id }?.muted = on
        case let .ptzPreset(n, p):
            if let id = inputID(number: n) { ptz(.recallPreset(p - 1), input: id) }
        case let .ptzHome(n):
            if let id = inputID(number: n) { ptz(.home, input: id) }
        case let .dataRow(n, delta):
            if let id = inputID(number: n) { stepDataRow(id, by: delta) }
        case let .dataRowSet(n, row):
            if let id = inputID(number: n) { setDataRow(id, row - 1) }
        }
        pushRemoteState(clients: false)
    }
}
#endif
