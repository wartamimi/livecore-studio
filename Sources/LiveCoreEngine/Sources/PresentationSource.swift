#if os(macOS)
import AppKit
import CoreVideo
import ScreenCaptureKit
import LiveCoreCore

/// PowerPoint / Keynote / OpenDocument / PDF slides. A PDF is shown directly; other files are
/// first exported to a cached PDF by Keynote, PowerPoint or LibreOffice (whichever is installed).
/// Each slide is drawn aspect-fit at the output size; the slide on air and its neighbours are kept
/// rendered so next / previous switch at once. These slides are static.
///
/// Live mode (vMix PowerPoint input): PowerPoint plays the slide show in a window and the input
/// captures that window and its sound, so animations, transitions and embedded video play. Needs
/// Microsoft PowerPoint, the Automation permission and the Screen Recording permission.
public final class PresentationSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .presentation
    public var name: String
    public let url: URL
    public var status: SourceStatus {
        if let c = lock.withLock({ capture }) { return c.status }
        return lock.withLock { st }
    }
    public var onStatusChange: ((SourceStatus) -> Void)?
    /// Called on the main queue when the slide, the slide count or the conversion state changes.
    public var onChange: (() -> Void)?

    public var slideCount: Int { lock.withLock { count } }
    public var slide: Int { lock.withLock { current } }
    public var isConverting: Bool { lock.withLock { converting } }
    public var background: ProjectColor? { lock.withLock { bg } }

    private let outputSize: PixelSize
    private let queue = DispatchQueue(label: "livecore.presentation", qos: .userInitiated)
    private let lock = UnfairLock()
    // Lock state.
    private var st: SourceStatus = .starting
    private var frame: CVPixelBuffer?
    private var count = 0
    private var current: Int
    private var converting = false
    private var bg: ProjectColor?
    // Queue state.
    private var document: CGPDFDocument?
    private var rendered: [Int: CVPixelBuffer] = [:]
    private var started = false

    public init(id: InputID, url: URL, slide: Int = 0, background: ProjectColor? = nil, live: Bool = false,
                outputSize: PixelSize) {
        self.id = id; self.url = url; self.outputSize = outputSize
        current = max(0, slide); bg = background
        wantsLive = live && PresentationSource.canPlayLive(url)
        name = url.deletingPathExtension().lastPathComponent
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            if self.lock.withLock({ self.wantsLive }) { self.startLive() } else { self.load(force: false) }
        }
    }
    public func stop() {
        let c: ScreenCaptureSource? = lock.withLock { let c = capture; capture = nil; return c }
        guard let c else { return }
        c.stop()
        queue.async { Self.endSlideShow() }
    }
    public func currentFrame() -> CVPixelBuffer? {
        if let c = lock.withLock({ capture }), let pb = c.currentFrame() { return pb }
        return lock.withLock { frame }
    }

    public func go(to slide: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.lock.withLock({ self.capture != nil }) {
                self.liveCommand("go to slide (slide show view of slide show window 1) number \(slide + 1)")
                return
            }
            let n = self.lock.withLock { self.count }
            self.show(SlideMath.clamp(slide, count: n))
        }
    }
    // In live mode PowerPoint moves on, so builds (click animations) inside a slide play too.
    public func next() {
        if isLive { queue.async { [weak self] in self?.liveCommand("go to next slide (slide show view of slide show window 1)") }; return }
        go(to: SlideMath.next(slide, count: slideCount))
    }
    public func previous() {
        if isLive { queue.async { [weak self] in self?.liveCommand("go to previous slide (slide show view of slide show window 1)") }; return }
        go(to: SlideMath.previous(slide, count: slideCount))
    }
    public func first() { go(to: 0) }
    public func last() { go(to: max(0, slideCount - 1)) }

    // MARK: - Live mode

    /// PowerPoint is installed and can open this file.
    public static func canPlayLive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return (PresentationFiles.powerPoint.contains(ext) || PresentationFiles.openDocument.contains(ext))
            && PresentationConverter.isInstalled(.powerPoint)
    }
    public var canPlayLive: Bool { Self.canPlayLive(url) }
    /// The slide show is being captured from PowerPoint.
    public var isLive: Bool { lock.withLock { capture != nil } }
    /// Live mode was chosen (saved in the project), even while PowerPoint is still starting.
    public var prefersLive: Bool { lock.withLock { wantsLive } }
    /// Set by the engine: the mixer channel for the slide show's sound (main thread).
    public var audioChannelProvider: (() -> MixerChannel)?
    private var capture: ScreenCaptureSource?
    private var wantsLive = false

    /// Switches between live (PowerPoint plays) and static slides. Main thread.
    public func setLive(_ on: Bool) {
        guard on != prefersLive, !on || canPlayLive else { return }
        lock.withLock { wantsLive = on }
        if on {
            queue.async { [weak self] in self?.startLive() }
        } else {
            stop()
            queue.async { [weak self] in
                guard let self else { return }
                if self.document == nil { self.load(force: false) } else { self.show(self.lock.withLock { self.current }) }
            }
            notify()
        }
    }

    /// Queue. Opens the file in PowerPoint, plays it in a window and captures that window.
    private func startLive() {
        lock.withLock { converting = true }
        setStatus(.starting)
        notify()
        let before = Set(Self.powerPointWindows().map(\.windowID))
        do {
            try PresentationConverter.osascript([
                "on run argv",
                "tell application \"Microsoft PowerPoint\"",
                "open (POSIX file (item 1 of argv))",
                "set p to active presentation",
                "set show type of slide show settings of p to slide show type window",
                "run slide show slide show settings of p",
                "end tell",
                "end run",
            ], args: [url.path], timeout: 120)
        } catch {
            liveFailed("PowerPoint: \(error.localizedDescription)")
            return
        }
        var found: WindowCandidate?
        for _ in 0..<40 where found == nil {
            found = Self.powerPointWindows().first { !before.contains($0.windowID) }
            if found == nil { usleep(250_000) }
        }
        guard let window = found else {
            liveFailed("PowerPoint: the slide show window did not open")
            return
        }
        let start = lock.withLock { current }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.prefersLive else { return }
            let cap = ScreenCaptureSource(id: self.id, config: ProjectScreenCapture(
                target: .window, bundleID: window.bundleID, appName: window.appName, windowTitle: window.title,
                captureAudio: true, fps: 30, showsCursor: false))
            cap.audioChannelProvider = self.audioChannelProvider
            cap.onStatusChange = { [weak self] s in self?.onStatusChange?(s) }
            self.lock.withLock { self.capture = cap; self.converting = false }
            cap.start()
            self.notify()
            self.queue.async {
                if start > 0 { self.liveCommand("go to slide (slide show view of slide show window 1) number \(start + 1)") }
                else { self.refreshLivePosition() }
            }
        }
    }

    private func liveFailed(_ message: String) {
        lock.withLock { converting = false; wantsLive = false }
        setStatus(.error(message))
        notify()
        // Fall back to the static slides.
        if document == nil { load(force: false) }
    }

    /// Queue. Sends one PowerPoint command, then reads the slide on show.
    private func liveCommand(_ command: String) {
        _ = try? PresentationConverter.osascript(["tell application \"Microsoft PowerPoint\" to \(command)"], timeout: 10)
        refreshLivePosition()
    }

    private func refreshLivePosition() {
        let script = [
            "tell application \"Microsoft PowerPoint\"",
            "set n to current show position of slide show view of slide show window 1",
            "set c to count of slides of presentation of slide show window 1",
            "return (n as string) & \"/\" & (c as string)",
            "end tell",
        ]
        guard let out = try? PresentationConverter.osascript(script, timeout: 10) else { return }
        let parts = out.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts[1] > 0 else { return }
        lock.withLock { count = parts[1]; current = SlideMath.clamp(parts[0] - 1, count: parts[1]) }
        notify()
    }

    private static func endSlideShow() {
        _ = try? PresentationConverter.osascript([
            "tell application \"Microsoft PowerPoint\"",
            "if (count of slide show windows) > 0 then exit slide show (slide show view of slide show window 1)",
            "end tell",
        ], timeout: 10)
    }

    /// PowerPoint's windows as ScreenCaptureKit lists them (blocking; not on the main thread).
    private static func powerPointWindows() -> [WindowCandidate] {
        let done = DispatchSemaphore(value: 0)
        var result: [WindowCandidate] = []
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, _ in
            result = (content?.windows ?? []).compactMap { w in
                guard let app = w.owningApplication, app.bundleIdentifier == "com.microsoft.Powerpoint",
                      w.frame.width >= 200, w.frame.height >= 150 else { return nil }
                return WindowCandidate(windowID: w.windowID, bundleID: app.bundleIdentifier,
                                       appName: app.applicationName, title: w.title ?? "")
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        return result
    }

    public func setBackground(_ c: ProjectColor?) {
        lock.withLock { bg = c }
        queue.async { [weak self] in
            guard let self else { return }
            self.rendered = [:]
            self.show(self.lock.withLock { self.current })
        }
    }

    /// Exports the file again (after it was edited in PowerPoint / Keynote) and reloads it.
    public func reload() {
        queue.async { [weak self] in self?.load(force: true) }
    }

    // MARK: - Queue

    private func setStatus(_ s: SourceStatus) {
        let changed: Bool = lock.withLock { let c = st != s; st = s; return c }
        if changed { DispatchQueue.main.async { [weak self] in self?.onStatusChange?(s) } }
    }
    private func notify() { DispatchQueue.main.async { [weak self] in self?.onChange?() } }

    private func load(force: Bool) {
        var pdf = url
        if PresentationFiles.needsConversion(url.pathExtension) {
            let cached = PresentationConverter.cacheURL(for: url)
            if force || !FileManager.default.fileExists(atPath: cached.path) {
                lock.withLock { converting = true }
                setStatus(.starting)
                notify()
                do {
                    try PresentationConverter.convert(url, to: cached)
                } catch {
                    lock.withLock { converting = false }
                    setStatus(.error(error.localizedDescription))
                    notify()
                    return
                }
                lock.withLock { converting = false }
            }
            pdf = cached
        }
        guard let doc = CGPDFDocument(pdf as CFURL), doc.numberOfPages > 0 else {
            setStatus(.error(FileManager.default.fileExists(atPath: url.path) ? "Cannot read the presentation" : "File not found"))
            notify()
            return
        }
        document = doc
        rendered = [:]
        let n = doc.numberOfPages
        let i: Int = lock.withLock { count = n; current = SlideMath.clamp(current, count: n); return current }
        show(i)
        setStatus(.live)
    }

    private func show(_ i: Int) {
        guard document != nil else { return }
        guard let pb = render(i) else { setStatus(.error("Out of memory drawing the slide")); return }
        lock.withLock { current = i; frame = pb }
        notify()
        // Keep the neighbours ready and drop the rest.
        let n = lock.withLock { count }
        let keep = Set([i - 1, i, i + 1].filter { $0 >= 0 && $0 < n })
        rendered = rendered.filter { keep.contains($0.key) }
        for j in keep where rendered[j] == nil { _ = render(j) }
    }

    private func render(_ i: Int) -> CVPixelBuffer? {
        if let pb = rendered[i] { return pb }
        guard let doc = document, let page = doc.page(at: i + 1) else { return nil }
        let w = outputSize.width, h = outputSize.height
        let back = lock.withLock { bg } ?? ProjectColor(r: 0, g: 0, b: 0)
        let pb = PresentationSource.draw(page: page, width: w, height: h, background: back)
        if let pb { rendered[i] = pb }
        return pb
    }

    /// Draws one page aspect-fit on `background`, the page itself on white (like the slide app).
    static func draw(page: CGPDFPage, width w: Int, height h: Int, background: ProjectColor) -> CVPixelBuffer? {
        PixelBufferFactory.draw(width: w, height: h) { ctx in
            let box = page.getBoxRect(.cropBox)
            let (t, pw, ph) = SlideMath.pageTransform(minX: Double(box.minX), minY: Double(box.minY),
                                                      maxX: Double(box.maxX), maxY: Double(box.maxY),
                                                      rotation: Int(page.rotationAngle))
            let fit = SlideMath.fit(pw, ph, into: Double(w), Double(h))
            ctx.setFillColor(CGColor(srgbRed: background.r, green: background.g, blue: background.b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.setShouldAntialias(true)
            ctx.translateBy(x: fit.x, y: fit.y)
            ctx.scaleBy(x: fit.scale, y: fit.scale)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
            ctx.clip(to: CGRect(x: 0, y: 0, width: pw, height: ph))
            ctx.concatenate(CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty))
            ctx.drawPDFPage(page)
        }
    }
}

/// Turns a .pptx / .key / .odp into PDF with an app the user has installed.
public enum PresentationConverter {
    public typealias Converter = PresentationFiles.Converter

    static let bundleIDs: [Converter: [String]] = [
        .keynote: ["com.apple.iWork.Keynote"],
        .powerPoint: ["com.microsoft.Powerpoint"],
        .libreOffice: ["org.libreoffice.script", "org.libreoffice"],
    ]

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    static func appURL(_ c: Converter) -> URL? {
        bundleIDs[c]?.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    public static func installed() -> Set<Converter> {
        Set([Converter.keynote, .powerPoint, .libreOffice].filter { appURL($0) != nil })
    }

    /// One cached PDF per file version (path, size and modification date).
    public static func cacheURL(for url: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in "\(url.standardizedFileURL.path)|\(size)|\(stamp)".utf8 { hash = (hash ^ UInt64(b)) &* 0x100_0000_01b3 }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("studio.livecore.LiveCoreStudio/Presentations", isDirectory: true)
        return dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(String(hash, radix: 16)).pdf")
    }

    /// Blocking; call off the main thread. Tries each installed app in turn.
    public static func convert(_ url: URL, to out: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure(message: "File not found") }
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ext = url.pathExtension
        let apps = PresentationFiles.converters(for: ext).filter { appURL($0) != nil }
        guard !apps.isEmpty else {
            throw Failure(message: "To show .\(ext.lowercased()) slides install Keynote (free in the App Store), PowerPoint or LibreOffice, or export the presentation as PDF and add the PDF.")
        }
        var errors: [String] = []
        for app in apps {
            try? FileManager.default.removeItem(at: out)
            do {
                switch app {
                case .keynote: try keynote(url, out)
                case .powerPoint: try powerPoint(url, out)
                case .libreOffice: try libreOffice(url, out)
                }
                if FileManager.default.fileExists(atPath: out.path) { return }
                errors.append("\(app.rawValue): no PDF was written")
            } catch {
                errors.append("\(app.rawValue): \(error.localizedDescription)")
            }
        }
        throw Failure(message: "Could not export the slides to PDF (\(errors.joined(separator: "; ")))")
    }

    private static func keynote(_ src: URL, _ out: URL) throws {
        try osascript([
            "on run argv",
            "set wasRunning to running of application \"Keynote\"",
            "tell application \"Keynote\"",
            "set d to open (POSIX file (item 1 of argv))",
            "export d to (POSIX file (item 2 of argv)) as PDF",
            "close d saving no",
            "if not wasRunning then quit",
            "end tell",
            "end run",
        ], args: [src.path, out.path])
    }

    /// PowerPoint is sandboxed: it writes into its own container, then the file is moved here.
    private static func powerPoint(_ src: URL, _ out: URL) throws {
        let box = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.microsoft.Powerpoint/Data/tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let tmp = box.appendingPathComponent("livecore-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try osascript([
            "on run argv",
            "set wasRunning to running of application \"Microsoft PowerPoint\"",
            "tell application \"Microsoft PowerPoint\"",
            "open (POSIX file (item 1 of argv))",
            "set p to active presentation",
            "save p in ((POSIX file (item 2 of argv)) as string) as save as PDF",
            "close p saving no",
            "if not wasRunning then quit",
            "end tell",
            "end run",
        ], args: [src.path, tmp.path])
        try FileManager.default.moveItem(at: tmp, to: out)
    }

    private static func libreOffice(_ src: URL, _ out: URL) throws {
        guard let app = appURL(.libreOffice) else { throw Failure(message: "LibreOffice not found") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("livecore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try run(app.appendingPathComponent("Contents/MacOS/soffice"),
                ["--headless", "--convert-to", "pdf", "--outdir", dir.path, src.path])
        let pdf = dir.appendingPathComponent(src.deletingPathExtension().lastPathComponent + ".pdf")
        try FileManager.default.moveItem(at: pdf, to: out)
    }

    /// Runs an AppleScript (one line per entry) with arguments; returns what it printed.
    @discardableResult
    static func osascript(_ lines: [String], args: [String] = [], timeout: Double = 180) throws -> String {
        try run(URL(fileURLWithPath: "/usr/bin/osascript"), lines.flatMap { ["-e", $0] } + args, timeout: timeout)
    }

    /// Runs a tool and waits up to `timeout` seconds (opening a big deck can take a while).
    @discardableResult
    private static func run(_ tool: URL, _ args: [String], timeout: Double = 180) throws -> String {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let err = Pipe()
        let out = Pipe()
        p.standardError = err
        p.standardOutput = out
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw Failure(message: "timed out after \(Int(timeout)) s")
        }
        guard p.terminationStatus == 0 else {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let line = text.split(separator: "\n").last.map(String.init) ?? "exit \(p.terminationStatus)"
            // -1743: the user has not allowed LiveCore Studio to control the app.
            if text.contains("-1743") {
                throw Failure(message: "allow LiveCore Studio in System Settings › Privacy & Security › Automation")
            }
            throw Failure(message: line)
        }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isInstalled(_ c: Converter) -> Bool { appURL(c) != nil }
}
#endif
