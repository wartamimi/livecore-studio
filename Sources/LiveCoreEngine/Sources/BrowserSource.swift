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
        cfg.userContentController = WKUserContentController()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h), configuration: cfg)
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        if config.transparent { wv.setValue(false, forKey: "drawsBackground") }
        // Offscreen but ordered in, so WebKit keeps laying out and animating the page.
        let win = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: w, height: h),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.ignoresMouseEvents = true
        win.hasShadow = false
        win.backgroundColor = .clear
        win.isOpaque = false
        win.contentView = wv
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
        wv.pageZoom = CGFloat(config.pageZoom)
        let ucc = wv.configuration.userContentController
        ucc.removeAllUserScripts()
        if let js = config.userScript {
            ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
    }

    public func stop() {
        if isEditing { endEditing(keepAddress: false) }
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
        let reloadPage = new.url != config.url || new.userScript != config.userScript
        config = new
        config.fps = BrowserURLPolicy.clampFPS(new.fps)
        if recreate && webView != nil { stop(); start(); return }
        applyPageOptions()
        startTimer()
        if reloadPage { load() }
    }

    public func reload() { webView?.reloadFromOrigin() }

    // MARK: Edit window

    /// Moves the page into a window the operator can use (main thread).
    public func beginEditing(doneTitle: String, windowTitle: String) {
        if let w = editWindow { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        guard let wv = webView else { return }
        let page = wv.frame.size
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let barHeight: CGFloat = 40
        let content = NSSize(width: min(page.width, (visible.width * 0.8).rounded()),
                             height: min(page.height, (visible.height * 0.8).rounded() - barHeight) + barHeight)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: content),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
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
        bar.translatesAutoresizingMaskIntoConstraints = false

        // The page keeps its output size (what the audience sees); a larger page scrolls.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        scroll.translatesAutoresizingMaskIntoConstraints = false
        wv.removeFromSuperview()
        wv.frame = NSRect(origin: .zero, size: page)
        scroll.documentView = wv

        let root = NSView(frame: NSRect(origin: .zero, size: content))
        root.addSubview(bar)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: barHeight),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        win.contentView = root
        win.center()
        editWindow = win
        urlField = field
        backButton = back
        forwardButton = forward
        updateNavigationButtons()
        // Show the top of the page (the clip view is not flipped).
        root.layoutSubtreeIfNeeded()
        let visibleHeight = scroll.contentSize.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, page.height - visibleHeight)))
        scroll.reflectScrolledClipView(scroll.contentView)
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
        guard let win = editWindow, let wv = webView, let host = window else { return }
        editWindow = nil
        win.delegate = nil
        win.orderOut(nil)
        wv.removeFromSuperview()
        wv.frame = NSRect(origin: .zero, size: wv.frame.size)
        host.contentView = wv
        host.orderBack(nil)
        win.contentView = nil
        if keepAddress, let u = wv.url, ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.absoluteString != config.url {
            config.url = u.absoluteString
            onConfigChange?()
        }
        onEditingChange?(false)
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
