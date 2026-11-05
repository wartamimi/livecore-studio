#if os(macOS)
import AppKit
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import WebKit
import LiveCoreCore

/// LCS Live input (0.52.0): a remote guest on a WebRTC call, shown as an input with its own mixer
/// channel, in the spirit of vMix Call.
///
/// The call runs inside WebKit: a hidden web view loads the host page from the app's LCS Live
/// server (http://127.0.0.1, a secure context) and is the WebRTC end point. Its picture (the
/// guest's video, letterboxed) is captured with `takeSnapshot` like a browser input; the guest's
/// sound is taken from the page by an AudioWorklet and handed to the app as PCM through a script
/// message handler, into this input's own mixer channel (so it is never part of "Web audio").
/// The return feed goes the other way: Program JPEGs (≈12 fps) drawn on a canvas that is sent
/// as the call's video, and the mixer's mix-minus for this channel (program without the guest)
/// played into the call's audio track.
public final class LiveCallSource: NSObject, VideoSource, WKNavigationDelegate {
    public enum CallState: Equatable, Sendable {
        case waiting                 // link open, no guest
        case connecting(String)      // guest name
        case connected(String)
        case ended(String)           // guest left or the connection dropped
    }

    public let id: InputID
    public let kind: InputKind = .liveCall
    public var name: String
    public private(set) var config: ProjectLiveCall
    public private(set) var status: SourceStatus = .starting {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    public var onStatusChange: ((SourceStatus) -> Void)?

    /// Main thread.
    public private(set) var callState: CallState = .waiting {
        didSet { if callState != oldValue { onCallStateChange?(callState); updateReturn() } }
    }
    public var onCallStateChange: ((CallState) -> Void)?
    /// The host page answered offer `seq` (main thread): hand it to the signaling hub.
    public var onAnswer: ((Int, String) -> Void)?
    /// Called from `stop()` (input removed or project closed).
    public var onStop: (() -> Void)?
    /// http://127.0.0.1:<port>/live/host
    public var hostURL: URL?
    /// RTCPeerConnection iceServers JSON.
    public var iceJSON = "[]"
    /// The Program picture for the return feed (main thread).
    public var returnFrameProvider: (() -> CVPixelBuffer?)?
    public var audioChannelProvider: (() -> MixerChannel)?

    private let sampleRate: Double
    private var window: NSWindow?
    private var webView: WKWebView?
    private var timer: Timer?
    private var returnTimer: Timer?
    private var snapshotInFlight = false
    private var idleTick = 0
    private let slot = FrameSlot()
    private var activity: NSObjectProtocol?
    private var pageReady = false
    private var pendingOffer: (seq: Int, sdp: String, name: String)?
    private var currentSeq = 0
    private var guestName = ""
    private var channel: MixerChannel?
    private var resampler: LinearResampler?
    private var resamplerRate: Double = 0
    private let returnQueue = DispatchQueue(label: "studio.livecore.lcslive.return", qos: .userInitiated)
    private var returnBusy = false
    private static var ci: CIContext { SharedCI.standard }

    public init(id: InputID, config: ProjectLiveCall, sampleRate: Double) {
        self.id = id
        self.config = config.clamped
        self.sampleRate = sampleRate
        self.name = "LCS Live"
        super.init()
    }

    public var guestLink: String { "/live/\(config.key)" }

    // MARK: Lifecycle (main thread)

    public func start() {
        guard webView == nil, let hostURL else { if hostURL == nil { status = .error("LCS Live server is not running") }; return }
        let w = config.width, h = config.height
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        let ucc = WKUserContentController()
        ucc.add(WeakScriptHandler(self), name: "lcs")
        cfg.userContentController = ucc
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h), configuration: cfg)
        wv.navigationDelegate = self
        let win = OffscreenHostWindow(contentRect: NSRect(origin: OffscreenHostWindow.parkingOrigin(), size: NSSize(width: w, height: h)),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.transient, .ignoresCycle, .stationary, .fullScreenNone]
        win.ignoresMouseEvents = true
        win.hasShadow = false
        win.backgroundColor = .black
        win.contentView = BrowserHostView(webView: wv, pageSize: NSSize(width: w, height: h), baseZoom: 1)
        win.orderBack(nil)
        window = win
        webView = wv
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "LCS Live call")
        pageReady = false
        wv.load(URLRequest(url: hostURL))
        let t = Timer(timeInterval: 1 / Double(config.fps), repeats: true) { [weak self] _ in self?.snapshot() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate(); timer = nil
        returnTimer?.invalidate(); returnTimer = nil
        channel?.mixMinusEnabled.value = false
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "lcs")
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        webView = nil; window = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        onStop?()
    }

    deinit { timer?.invalidate(); returnTimer?.invalidate() }

    /// Title, return feed switches (the link key is changed with `newLink`).
    public func update(_ new: ProjectLiveCall) {
        var c = new.clamped
        c.key = config.key; c.width = config.width; c.height = config.height; c.fps = config.fps
        config = c
        if pageReady { js("lcs.setup(\(Int(sampleRate)),\(LiveCallJSON.string(config.title)))") }
        updateReturn()
    }

    /// Revokes the current link (main thread). The caller re-registers the room.
    public func replaceKey(_ key: String) {
        hangUp()
        config.key = key
    }

    public func hangUp() {
        js("lcs.hangup()")
        currentSeq += 1                     // late answers of the old call are ignored
        if case .waiting = callState {} else { callState = .ended(guestName) }
    }

    // MARK: Signaling (main thread)

    public func deliverOffer(seq: Int, sdp: String, name: String) {
        guestName = name
        currentSeq = seq
        callState = .connecting(name)
        if !pageReady { pendingOffer = (seq, sdp, name); return }
        js("lcs.offer(\(seq),\(LiveCallJSON.string(sdp)),\(iceJSON))")
    }

    public func guestLeft(seq: Int) {
        guard seq == currentSeq else { return }
        js("lcs.hangup()")
        callState = .ended(guestName)
    }

    private func js(_ s: String) { webView?.evaluateJavaScript(s, completionHandler: nil) }

    fileprivate func receive(_ body: Any) {
        guard let m = body as? [String: Any], let t = m["t"] as? String else { return }
        switch t {
        case "ready":
            pageReady = true
            status = .live
            js("lcs.setup(\(Int(sampleRate)),\(LiveCallJSON.string(config.title)))")
            if let p = pendingOffer { pendingOffer = nil; deliverOffer(seq: p.seq, sdp: p.sdp, name: p.name) }
        case "answer":
            guard let seq = m["seq"] as? Int, seq == currentSeq, let sdp = m["sdp"] as? String else { return }
            onAnswer?(seq, sdp)
        case "state":
            guard let seq = m["seq"] as? Int, seq == currentSeq, let s = m["s"] as? String else { return }
            switch s {
            case "connected", "completed": callState = .connected(guestName)
            case "failed", "closed", "disconnected": callState = .ended(guestName)
            default: callState = .connecting(guestName)
            }
        case "pcm":
            guard let d = m["d"] as? String, let data = Data(base64Encoded: d) else { return }
            let rate = (m["rate"] as? NSNumber)?.doubleValue ?? sampleRate
            pushGuestAudio(data, rate: rate)
        case "error":
            Log.video.error("LCS Live: \(String(describing: m["s"] ?? ""), privacy: .public)")
            if let seq = m["seq"] as? Int, seq == currentSeq { callState = .ended(guestName) }
        default:
            if let s = m["s"] as? String { Log.video.info("LCS Live page: \(s, privacy: .public)") }
        }
    }

    // MARK: Guest audio → mixer channel

    private func pushGuestAudio(_ data: Data, rate: Double) {
        if channel == nil { channel = audioChannelProvider?() }
        guard let ch = channel else { return }
        let n = data.count / 4
        guard n > 0 else { return }
        var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<n { l[i] = Float(Int16(littleEndian: p[2 * i])) / 32768; r[i] = Float(Int16(littleEndian: p[2 * i + 1])) / 32768 }
        }
        if abs(rate - sampleRate) < 1 {
            _ = ch.ringL.write(l, count: n); _ = ch.ringR.write(r, count: n)
            return
        }
        if resampler == nil || resamplerRate != rate { resampler = LinearResampler(inputRate: rate, outputRate: sampleRate); resamplerRate = rate }
        guard var rs = resampler else { return }
        let cap = rs.maxOutputFrames(forInput: n)
        var ol = [Float](repeating: 0, count: cap), or = [Float](repeating: 0, count: cap)
        let got = l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in
            ol.withUnsafeMutableBufferPointer { olp in or.withUnsafeMutableBufferPointer { orp in
                rs.process(inLeft: lp.baseAddress!, inRight: rp.baseAddress!, inputFrames: n,
                           outLeft: olp.baseAddress!, outRight: orp.baseAddress!, outputCapacity: cap)
            } }
        } }
        resampler = rs
        _ = ch.ringL.write(ol, count: got); _ = ch.ringR.write(or, count: got)
    }

    // MARK: Return feed (Program picture + mix-minus)

    private var isConnected: Bool { if case .connected = callState { return true }; return false }

    private func updateReturn() {
        let on = isConnected
        if channel == nil, on { channel = audioChannelProvider?() }
        if let ch = channel {
            let want = on && config.returnAudio
            if want != ch.mixMinusEnabled.value {
                // Start from an empty ring so the guest does not hear stale sound.
                ch.minusL.skip(ch.minusL.availableToRead); ch.minusR.skip(ch.minusR.availableToRead)
                ch.mixMinusEnabled.value = want
            }
        }
        if on, returnTimer == nil {
            // 80 ms ticks: one audio block + one Program frame (≈12 fps) per tick, so half as
            // many main-thread JavaScript calls as 40 ms audio ticks.
            let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.sendReturnAudio()
                self.sendReturnFrame()
            }
            RunLoop.main.add(t, forMode: .common)
            returnTimer = t
        } else if !on {
            returnTimer?.invalidate(); returnTimer = nil
        }
        if !config.returnVideo { js("lcs.blank()") }
    }

    private func sendReturnAudio() {
        guard config.returnAudio, let ch = channel else { return }
        let n = min(ch.minusL.availableToRead, ch.minusR.availableToRead, Int(sampleRate / 2))
        guard n > 0 else { return }
        var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
        _ = l.withUnsafeMutableBufferPointer { ch.minusL.read(into: $0.baseAddress!, count: n) }
        _ = r.withUnsafeMutableBufferPointer { ch.minusR.read(into: $0.baseAddress!, count: n) }
        var pcm = Data(count: n * 4)
        pcm.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<n {
                p[2 * i] = Int16(min(max(l[i], -1), 1) * 32767).littleEndian
                p[2 * i + 1] = Int16(min(max(r[i], -1), 1) * 32767).littleEndian
            }
        }
        js("lcs.audio('\(pcm.base64EncodedString())')")
    }

    private func sendReturnFrame() {
        guard config.returnVideo, !returnBusy, let pb = returnFrameProvider?() else { return }
        returnBusy = true
        returnQueue.async { [weak self] in
            let jpeg = Self.jpeg(pb)
            DispatchQueue.main.async {
                guard let self else { return }
                self.returnBusy = false
                if let jpeg, self.isConnected { self.js("lcs.frame('\(jpeg.base64EncodedString())')") }
            }
        }
    }

    /// 640×360 JPEG of the Program picture.
    static func jpeg(_ pb: CVPixelBuffer) -> Data? {
        var img = CIImage(cvPixelBuffer: pb)
        let s = min(640 / max(img.extent.width, 1), 360 / max(img.extent.height, 1), 1)
        img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let cg = ci.createCGImage(img, from: img.extent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: Picture

    private func snapshot() {
        guard let wv = webView, !snapshotInFlight else { return }
        // No guest on the line: the page shows a still "waiting" card, so about 1 fps is enough.
        if !isConnected {
            idleTick += 1
            if idleTick % max(config.fps, 1) != 1, slot.get() != nil { return }
        } else {
            idleTick = 0
        }
        snapshotInFlight = true
        let sc = WKSnapshotConfiguration()
        sc.afterScreenUpdates = false
        // WebRTC guest video is rarely above 720p; capturing wider only costs CPU (the compositor scales).
        let captureWidth = min(config.width, 1280)
        sc.snapshotWidth = NSNumber(value: Double(captureWidth) / Double(wv.window?.backingScaleFactor ?? 1))
        wv.takeSnapshot(with: sc) { [weak self] image, error in
            guard let self else { return }
            self.snapshotInFlight = false
            guard let image, error == nil, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let w = cg.width, h = cg.height
            if let pb = PixelBufferFactory.draw(width: w, height: h, { ctx in ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)) }) {
                self.slot.put(pb)
            }
        }
    }

    public func currentFrame() -> CVPixelBuffer? { slot.get() }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the host page itself.
        let u = navigationAction.request.url
        decisionHandler(u?.host == hostURL?.host && u?.path == hostURL?.path ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        status = .error(error.localizedDescription)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        status = .noSignal("call page ended, reloading")
        pageReady = false
        if case .waiting = callState {} else { callState = .ended(guestName) }
        webView.reload()
    }
}

/// WKUserContentController keeps its handlers alive: this breaks the cycle with the source.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: LiveCallSource?
    init(_ t: LiveCallSource) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message.body)
    }
}
#endif
