#if os(macOS)
import AppKit
import CoreVideo
import LiveCoreCore

/// PowerPoint / Keynote / OpenDocument / PDF slides. A PDF is shown directly; other files are
/// first exported to a cached PDF by Keynote, PowerPoint or LibreOffice (whichever is installed).
/// Each slide is drawn aspect-fit at the output size; the slide on air and its neighbours are kept
/// rendered so next / previous switch at once. Slides are static: slide animations, transitions and
/// embedded video are not played.
public final class PresentationSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .presentation
    public var name: String
    public let url: URL
    public var status: SourceStatus { lock.withLock { st } }
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

    public init(id: InputID, url: URL, slide: Int = 0, background: ProjectColor? = nil, outputSize: PixelSize) {
        self.id = id; self.url = url; self.outputSize = outputSize
        current = max(0, slide); bg = background
        name = url.deletingPathExtension().lastPathComponent
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.load(force: false)
        }
    }
    public func stop() {}
    public func currentFrame() -> CVPixelBuffer? { lock.withLock { frame } }

    public func go(to slide: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            let n = self.lock.withLock { self.count }
            self.show(SlideMath.clamp(slide, count: n))
        }
    }
    public func next() { go(to: SlideMath.next(slide, count: slideCount)) }
    public func previous() { go(to: SlideMath.previous(slide, count: slideCount)) }
    public func first() { go(to: 0) }
    public func last() { go(to: max(0, slideCount - 1)) }

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

    private static func osascript(_ lines: [String], args: [String]) throws {
        try run(URL(fileURLWithPath: "/usr/bin/osascript"), lines.flatMap { ["-e", $0] } + args)
    }

    /// Runs a tool and waits up to `timeout` seconds (opening a big deck can take a while).
    private static func run(_ tool: URL, _ args: [String], timeout: Double = 180) throws {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
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
    }
}
#endif
