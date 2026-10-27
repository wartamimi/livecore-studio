#if os(macOS)
import AppKit
import LiveCoreCore

/// vMix-style "Fullscreen": the Program output fills a chosen display (projector, HDMI out,
/// external monitor) with no window chrome, menu bar or cursor. Esc, the toolbar button or
/// the MIDI action closes it. If the display is unplugged the output closes by itself.
/// Main thread only.
public final class FullscreenOutput: ObservableObject {
    @Published public private(set) var isActive = false
    @Published public private(set) var displays: [DisplayInfo] = []
    @Published public private(set) var current: DisplayInfo?

    private let feed: FrameFeed
    private var window: NSWindow?
    private var observer: NSObjectProtocol?
    private var cursorHidden = false

    private static let idKey = "fullscreen.displayID"
    private static let nameKey = "fullscreen.displayName"

    public init(feed: FrameFeed) {
        self.feed = feed
        refreshDisplays()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// The display the next "Fullscreen" press will use.
    public var target: DisplayInfo? {
        let d = UserDefaults.standard
        let savedID = d.object(forKey: Self.idKey) as? Int
        return OutputDisplayPicker.choose(savedID: savedID.map { UInt32(truncatingIfNeeded: $0) },
                                          savedName: d.string(forKey: Self.nameKey), displays: displays)
    }

    public func select(_ display: DisplayInfo) {
        UserDefaults.standard.set(Int(display.id), forKey: Self.idKey)
        UserDefaults.standard.set(display.name, forKey: Self.nameKey)
        objectWillChange.send()
        if isActive { open(on: display) }
    }

    public func toggle() { isActive ? close() : open() }

    public func open() {
        refreshDisplays()
        guard let d = target else { return }
        open(on: d)
    }

    public func close() {
        window?.orderOut(nil)
        window = nil
        current = nil
        isActive = false
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
    }

    private func open(on display: DisplayInfo) {
        guard let screen = Self.screen(for: display.id) else { return }
        close()
        let w = FullscreenWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.onEscape = { [weak self] in self?.close() }
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        // Above the menu bar and Dock of that display, on every Space.
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = PixelBufferNSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        w.contentView = view
        feed.attachView(view)
        w.setFrame(screen.frame, display: true)
        // Only take key focus (for Esc) when it covers the operator's own screen; on an external
        // display the main window keeps the keyboard so shortcuts keep working.
        if display.isMain || NSScreen.screens.count == 1 { w.makeKeyAndOrderFront(nil) } else { w.orderFrontRegardless() }
        window = w
        current = display
        isActive = true
        if display.isMain || NSScreen.screens.count == 1 { NSCursor.hide(); cursorHidden = true }
    }

    private func screensChanged() {
        refreshDisplays()
        if let current, OutputDisplayPicker.lost(current, in: displays) { close() }
        else if let current, let screen = Self.screen(for: current.id) { window?.setFrame(screen.frame, display: true) }
    }

    private func refreshDisplays() {
        let main = CGMainDisplayID()
        displays = NSScreen.screens.compactMap { s in
            guard let id = Self.displayID(s) else { return nil }
            let name: String
            if #available(macOS 10.15, *) { name = s.localizedName } else { name = "Display \(id)" }
            let size = s.frame.size
            return DisplayInfo(id: id, name: "\(name) (\(Int(size.width * s.backingScaleFactor))×\(Int(size.height * s.backingScaleFactor)))",
                               isMain: id == main)
        }
    }

    private static func displayID(_ s: NSScreen) -> UInt32? {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func screen(for id: UInt32) -> NSScreen? {
        NSScreen.screens.first { displayID($0) == id }
    }
}

/// Borderless windows refuse key status by default; this one accepts it so Esc can close it.
final class FullscreenWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}
#endif
