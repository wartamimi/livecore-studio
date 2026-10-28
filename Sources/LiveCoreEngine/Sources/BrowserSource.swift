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
/// Audio from the page plays on the system output and is not captured by the mixer.
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

    /// Edit mode (vMix "interact"): the page is shown in a normal window where the operator can
    /// click and type (log in, pick a match, fill a form). While `freezeWhileEditing` is on the
    /// input keeps showing the last picture, so the audience does not see the editing; "Done"
    /// shows the page again.
    public private(set) var isEditing = false
    public var freezeWhileEditing = true
    /// Main thread; called when edit mode ends (Done button or closing the window).
    public var onEditingChange: ((Bool) -> Void)?
    private var savedFrame: NSRect?

    public init(id: InputID, config: ProjectBrowser) {
        self.id = id
        self.config = config
        self.name = BrowserSource.defaultName(config.url)
        super.init()
    }

    static func defaultName(_ url: String) -> String {
        URL(string: url)?.host ?? URL(string: url)?.lastPathComponent ?? "Browser"
    }

    /// Main thread.
    public func start() {
        guard webView == nil else { return }
        let w = min(max(config.width, 320), 3840), h = min(max(config.height, 180), 2160)
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h), configuration: cfg)
        wv.navigationDelegate = self
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
        // Keep timers and rendering alive while the app is in the background.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Browser source rendering")
        load()
        startTimer()
    }

    public func stop() {
        if isEditing { endEditing() }
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
        config = new
        config.fps = BrowserURLPolicy.clampFPS(new.fps)
        if recreate && webView != nil { stop(); start(); return }
        startTimer()
        load()
    }

    public func reload() { webView?.reloadFromOrigin() }

    /// Shows the page in a window the operator can use (main thread).
    public func beginEditing(doneTitle: String, windowTitle: String) {
        guard let win = window, let wv = webView, !isEditing else { window?.makeKeyAndOrderFront(nil); return }
        isEditing = true
        savedFrame = win.frame
        let page = wv.frame.size
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // A page larger than the screen scrolls inside the window instead of being scaled.
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: page))
        scroll.hasVerticalScroller = page.height > visible.height * 0.9
        scroll.hasHorizontalScroller = page.width > visible.width * 0.9
        scroll.drawsBackground = true
        scroll.backgroundColor = .darkGray
        scroll.documentView = wv
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.title = windowTitle
        win.contentView = scroll
        win.isOpaque = true
        win.backgroundColor = .windowBackgroundColor
        win.hasShadow = true
        win.ignoresMouseEvents = false
        win.delegate = self
        let size = NSSize(width: min(page.width, visible.width * 0.9), height: min(page.height, visible.height * 0.9))
        win.setContentSize(size)
        win.contentMaxSize = page
        win.center()
        let done = NSButton(title: doneTitle, target: self, action: #selector(doneEditing))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: done.intrinsicContentSize.width + 16, height: 28))
        done.frame = NSRect(x: 8, y: 2, width: done.intrinsicContentSize.width, height: 24)
        holder.addSubview(done)
        accessory.view = holder
        win.addTitlebarAccessoryViewController(accessory)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        onEditingChange?(true)
    }

    @objc private func doneEditing() { endEditing() }

    /// Back to off-screen rendering; the page is shown on the input again (main thread).
    public func endEditing() {
        guard isEditing, let win = window, let wv = webView else { return }
        while !win.titlebarAccessoryViewControllers.isEmpty { win.removeTitlebarAccessoryViewController(at: 0) }
        win.delegate = nil
        win.orderOut(nil)
        (win.contentView as? NSScrollView)?.documentView = nil
        wv.frame = NSRect(origin: .zero, size: wv.frame.size)
        win.styleMask = [.borderless]
        win.contentView = wv
        win.hasShadow = false
        win.backgroundColor = .clear
        win.isOpaque = false
        win.ignoresMouseEvents = true
        win.setFrame(savedFrame ?? NSRect(x: -20_000, y: -20_000, width: wv.frame.width, height: wv.frame.height), display: false)
        win.orderBack(nil)
        isEditing = false
        onEditingChange?(false)
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        endEditing()
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
        sc.snapshotWidth = NSNumber(value: Double(config.width) / Double(window?.backingScaleFactor ?? 1))
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

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { status = .live }

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
