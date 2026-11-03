#if os(macOS)
import AppKit
import CoreVideo
import WebKit
import LiveCoreCore

/// Web page as an input (HTML overlays, scoreboards, chat widgets...).
///
/// The page is rendered by a WKWebView in a borderless window placed outside every screen, and
/// captured with `takeSnapshot` at a fixed rate (5–30 fps) into a BGRA buffer. With
/// `transparent` the page background is not painted, so CSS `background: transparent` keys
/// over the program like a PNG.
///
/// Security: a non-persistent website data store (no cookies or storage shared with Safari or
/// kept between launches), no script message handlers (the page cannot call into the app), no
/// pop-up windows, and navigation limited to http/https (and file URLs inside the folder of a
/// local page the operator picked).
/// Audio: on macOS 14.2+ the pages' sound is taken into the mixer's "Web audio" channel
/// (see `WebAudioCapture`); on older systems it plays on the system output.
/// The hidden window that hosts the page while it is not being edited (0.46.1). macOS sometimes
/// moved the old off-screen window back onto the display (after a display change or Space switch),
/// leaving a black window that ignores clicks and cannot be closed. This window refuses to be
/// constrained onto a screen and moves itself away again whenever it lands on one.
final class OffscreenHostWindow: NSWindow {
    /// While the operator edits the page this same window is shown as a normal titled window
    /// (0.48.0): the page never changes window, which reloaded some sites on the next edit.
    var editing = false
    override var canBecomeKey: Bool { editing }
    override var canBecomeMain: Bool { editing }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        editing ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }

    private var observers: [NSObjectProtocol] = []

    /// Far beyond the bottom-left of every connected display.
    static func parkingOrigin() -> NSPoint {
        let all = NSScreen.screens.map(\.frame).reduce(NSRect.zero) { $0.union($1) }
        return NSPoint(x: all.minX - 20_000, y: all.minY - 20_000)
    }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in self?.parkIfVisible() })
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.park() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.parkIfVisible() })
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func park() { if !editing { setFrameOrigin(Self.parkingOrigin()) } }

    private func parkIfVisible() {
        if !editing, NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) { park() }
    }
}

/// Content of the page's window (0.48.0). Off screen it is exactly the page; while editing it
/// shows the address bar on top and the page scaled to fit below, keeping the output's CSS
/// viewport (page zoom, letterboxed). The web view only changes frame and zoom here, it never
/// leaves its view or window.
final class BrowserHostView: NSView {
    let pageSize: NSSize
    var baseZoom: CGFloat { didSet { needsLayout = true } }
    var bar: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let bar { addSubview(bar) }
            needsLayout = true
        }
    }
    static let barHeight: CGFloat = 40
    private weak var webView: WKWebView?

    init(webView: WKWebView, pageSize: NSSize, baseZoom: CGFloat) {
        self.webView = webView
        self.pageSize = pageSize
        self.baseZoom = baseZoom
        super.init(frame: NSRect(origin: .zero, size: pageSize))
        addSubview(webView)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard let wv = webView else { return }
        guard let bar else {
            wv.frame = NSRect(origin: .zero, size: pageSize)
            if wv.pageZoom != baseZoom { wv.pageZoom = baseZoom }
            return
        }
        bar.frame = NSRect(x: 0, y: bounds.height - Self.barHeight, width: bounds.width, height: Self.barHeight)
        let area = NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height - Self.barHeight, 1))
        guard pageSize.width > 0, pageSize.height > 0 else { return }
        let scale = min(area.width / pageSize.width, area.height / pageSize.height)
        let size = NSSize(width: (pageSize.width * scale).rounded(), height: (pageSize.height * scale).rounded())
        wv.frame = NSRect(x: ((area.width - size.width) / 2).rounded(), y: ((area.height - size.height) / 2).rounded(),
                          width: size.width, height: size.height)
        let zoom = max(0.1, baseZoom * scale)
        if abs(wv.pageZoom - zoom) > 0.001 { wv.pageZoom = zoom }
    }

    override func draw(_ dirtyRect: NSRect) {
        if bar != nil { NSColor.black.setFill(); dirtyRect.fill() }
    }
}

public final class BrowserSource: NSObject, VideoSource, WKNavigationDelegate, NSWindowDelegate {
    public let id: InputID
    public let kind: InputKind = .browser
    public var name: String
    public private(set) var config: ProjectBrowser
    public private(set) var status: SourceStatus = .starting {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    public var onStatusChange: ((SourceStatus) -> Void)?

    private var window: NSWindow?
    private var webView: WKWebView?
    private var timer: Timer?
    private var snapshotInFlight = false
    private let slot = FrameSlot()
    private var activity: NSObjectProtocol?

    /// Edit mode (vMix "Show window"): the page moves into a normal window with an address bar
    /// where the operator can click and type (log in, pick a match, fill a form). While
    /// `freezeWhileEditing` is on the input keeps showing the last picture, so the audience does not
    /// see the editing; "Done" puts the page back and shows it again.
    public var isEditing: Bool { editWindow != nil }
    public var freezeWhileEditing = true
    /// Main thread; called when edit mode starts or ends (Done button or closing the window).
    public var onEditingChange: ((Bool) -> Void)?
    /// Main thread; the page address changed in edit mode and was kept (the project should save it).
    public var onConfigChange: (() -> Void)?
    private var editWindow: NSWindow?
    private weak var urlField: NSTextField?
    private weak var backButton: NSButton?
    private weak var forwardButton: NSButton?
    /// Done was pressed while the edit window was full screen (keepAddress value).
    private var pendingEnd: Bool?

    public init(id: InputID, config: ProjectBrowser) {
        self.id = id
        self.config = config
        self.name = BrowserSource.defaultName(config.url)
        super.init()
    }

    static func defaultName(_ url: String) -> String {
        URL(string: url)?.host ?? URL(string: url)?.lastPathComponent ?? "Browser"
    }

    /// Process ids of this page's WebKit processes (for audio capture), when WebKit reports them.
    public var webKitProcessIDs: [pid_t] {
        guard let wv = webView else { return [] }
        return ["_webProcessIdentifier", "_gpuProcessIdentifier"].compactMap { key in
            guard wv.responds(to: NSSelectorFromString(key)), let n = wv.value(forKey: key) as? NSNumber else { return nil }
            let pid = n.int32Value
            return pid > 0 ? pid : nil
        }
    }

    /// Main thread.
    public func start() {
        guard webView == nil else { return }
        let w = min(max(config.width, 320), 3840), h = min(max(config.height, 180), 2160)
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Identify as Safari: some sites (YouTube among them) hide player features such as the
        // fullscreen button from an unknown WebKit browser.
        cfg.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        cfg.userContentController = WKUserContentController()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h), configuration: cfg)
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        if config.transparent { wv.setValue(false, forKey: "drawsBackground") }
        // Offscreen but ordered in, so WebKit keeps laying out and animating the page.
        let win = OffscreenHostWindow(contentRect: NSRect(origin: OffscreenHostWindow.parkingOrigin(), size: NSSize(width: w, height: h)),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        // Not in Mission Control, ⌘` cycling or Spaces: it must never become a visible window.
        win.collectionBehavior = [.transient, .ignoresCycle, .stationary, .fullScreenNone]
        win.ignoresMouseEvents = true
        win.hasShadow = false
        win.backgroundColor = .clear
        win.isOpaque = false
        win.contentView = BrowserHostView(webView: wv, pageSize: NSSize(width: w, height: h), baseZoom: CGFloat(config.pageZoom))
        win.orderBack(nil)
        window = win
        webView = wv
        applyPageOptions()
        // Keep timers and rendering alive while the app is in the background.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Browser source rendering")
        load()
        startTimer()
    }

    /// Zoom, CSS, video-only and mute (main thread; scripts apply from the next page load).
    private func applyPageOptions() {
        guard let wv = webView else { return }
        if let host = wv.superview as? BrowserHostView {
            host.baseZoom = CGFloat(config.pageZoom)
        } else {
            wv.pageZoom = CGFloat(config.pageZoom)
        }
        let ucc = wv.configuration.userContentController
        ucc.removeAllUserScripts()
        // A site's fullscreen button fills the input's picture, never the Mac's screen.
        ucc.addUserScript(WKUserScript(source: ProjectBrowser.fullscreenScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if let js = config.userScript {
            ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
    }

    public func stop() {
        if isEditing { endEditing(keepAddress: false) }
        if let w = editWindow {
            // Still full screen: close it (closing, unlike ordering out, also leaves its Space).
            w.delegate = nil
            w.close()
            editWindow = nil
            pendingEnd = nil
        }
        timer?.invalidate(); timer = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        webView = nil; window = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    deinit { timer?.invalidate() }

    /// Changes the page or its settings (main thread). Size changes recreate the web view.
    public func update(_ new: ProjectBrowser) {
        let recreate = new.width != config.width || new.height != config.height || new.transparent != config.transparent
        // Only a new address reloads; CSS / video-only / mute apply to the open page (0.46.2), so
        // changing them in Edit no longer restarts the video or logs the page out.
        let reloadPage = new.url != config.url
        let restyle = new.userScript != config.userScript
        config = new
        config.fps = BrowserURLPolicy.clampFPS(new.fps)
        if recreate && webView != nil { stop(); start(); return }
        applyPageOptions()
        startTimer()
        if reloadPage { load() } else if restyle { webView?.evaluateJavaScript(config.liveStyleScript, completionHandler: nil) }
    }

    public func reload() { webView?.reloadFromOrigin() }

    // MARK: Edit window

    /// Moves the page into a window the operator can use (main thread).
    public func beginEditing(doneTitle: String, windowTitle: String) {
        if let w = editWindow { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        guard let wv = webView else { return }
        guard let win = window as? OffscreenHostWindow, let host = win.contentView as? BrowserHostView else { return }
        let page = host.pageSize
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let barHeight = BrowserHostView.barHeight
        let content = NSSize(width: min(page.width, (visible.width * 0.8).rounded()),
                             height: min(page.height, (visible.height * 0.8).rounded() - barHeight) + barHeight)
        // The page's own window becomes the edit window: no new window, the page stays put.
        win.editing = true
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        win.ignoresMouseEvents = false
        win.hasShadow = true
        win.isOpaque = true
        win.backgroundColor = .black
        win.title = windowTitle
        win.minSize = NSSize(width: 520, height: 320)
        win.delegate = self

        func button(_ symbol: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
                             target: self, action: action)
            b.bezelStyle = .rounded
            return b
        }
        let back = button("chevron.left", #selector(goBack))
        let forward = button("chevron.right", #selector(goForward))
        let reload = button("arrow.clockwise", #selector(reloadPage))
        let field = NSTextField(string: wv.url?.absoluteString ?? config.url)
        field.target = self
        field.action = #selector(openTypedAddress)
        field.lineBreakMode = .byTruncatingTail
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // No key equivalent: Return must reach the page's own forms, not close the window.
        let done = NSButton(title: doneTitle, target: self, action: #selector(doneEditing))
        done.bezelStyle = .rounded
        done.bezelColor = .controlAccentColor
        let bar = NSStackView(views: [back, forward, reload, field, done])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.bar = bar
        win.setContentSize(content)
        win.center()
        editWindow = win
        urlField = field
        backButton = back
        forwardButton = forward
        updateNavigationButtons()
        host.layoutSubtreeIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(wv)
        onEditingChange?(true)
    }

    @objc private func doneEditing() { endEditing(keepAddress: true) }
    @objc private func goBack() { webView?.goBack() }
    @objc private func goForward() { webView?.goForward() }
    @objc private func reloadPage() { webView?.reload() }
    @objc private func openTypedAddress() {
        guard let wv = webView, let typed = urlField?.stringValue else { return }
        switch BrowserURLPolicy.check(typed) {
        case let .web(s): if let u = URL(string: s) { wv.load(URLRequest(url: u)) }
        case .file, .rejected: NSSound.beep()
        }
    }

    private func updateNavigationButtons() {
        backButton?.isEnabled = webView?.canGoBack ?? false
        forwardButton?.isEnabled = webView?.canGoForward ?? false
        if let u = webView?.url?.absoluteString, urlField?.currentEditor() == nil { urlField?.stringValue = u }
    }

    /// Puts the page back off screen; with `keepAddress` the page the operator ended on becomes the
    /// input's address (saved with the project). Main thread.
    public func endEditing(keepAddress: Bool = true) {
        guard let win = editWindow, let wv = webView else { return }
        if win.styleMask.contains(.fullScreen) {
            // Leave full screen first (finished in windowDidExitFullScreen), or the Space stays black.
            pendingEnd = keepAddress
            win.toggleFullScreen(nil)
            return
        }
        pendingEnd = nil
        editWindow = nil
        win.delegate = nil
        // Back to the hidden page window: same window, same view, only its look and place change.
        if let w = win as? OffscreenHostWindow, let hostView = w.contentView as? BrowserHostView {
            hostView.bar = nil
            w.styleMask = [.borderless]
            w.collectionBehavior = [.transient, .ignoresCycle, .stationary, .fullScreenNone]
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.isOpaque = false
            w.backgroundColor = .clear
            w.setContentSize(hostView.pageSize)
            w.editing = false
            w.park()
            w.orderBack(nil)
            hostView.layoutSubtreeIfNeeded()
        }
        if keepAddress, let u = wv.url, ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.absoluteString != config.url {
            config.url = u.absoluteString
            onConfigChange?()
        }
        onEditingChange?(false)
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        if let keep = pendingEnd { endEditing(keepAddress: keep) }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        endEditing(keepAddress: true)
        return false
    }

    private func load() {
        guard let wv = webView else { return }
        switch BrowserURLPolicy.check(config.url) {
        case let .web(s):
            guard let url = URL(string: s) else { status = .error("Invalid address"); return }
            wv.load(URLRequest(url: url))
        case let .file(s):
            guard let url = URL(string: s) else { status = .error("Invalid file path"); return }
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        case let .rejected(reason):
            status = .error(reason)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let fps = Double(BrowserURLPolicy.clampFPS(config.fps))
        let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.snapshot() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func snapshot() {
        guard let wv = webView, !snapshotInFlight, !(isEditing && freezeWhileEditing) else { return }
        snapshotInFlight = true
        let sc = WKSnapshotConfiguration()
        sc.afterScreenUpdates = false
        // snapshotWidth is in points; divide by the backing scale so the image has `width` pixels.
        sc.snapshotWidth = NSNumber(value: Double(config.width) / Double(wv.window?.backingScaleFactor ?? 1))
        wv.takeSnapshot(with: sc) { [weak self] image, error in
            guard let self else { return }
            self.snapshotInFlight = false
            guard let image, error == nil,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
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
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        switch scheme {
        case "http", "https", "about", "blob": decisionHandler(.allow)
        case "file":
            // Only inside the folder of the local page that was loaded.
            if case let .file(s) = BrowserURLPolicy.check(config.url), let base = URL(string: s)?.deletingLastPathComponent().path,
               let p = navigationAction.request.url?.standardizedFileURL.path, p.hasPrefix(base) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        default: decisionHandler(.cancel)
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        status = .live
        updateNavigationButtons()
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { updateNavigationButtons() }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        status = .error(error.localizedDescription)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        status = .error(error.localizedDescription)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page's process crashed or was killed for using too much memory: reload it.
        status = .noSignal("page process ended, reloading")
        webView.reload()
    }
}
#endif
