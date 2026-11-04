#if os(macOS)
import AppKit
import CoreVideo
import SwiftUI

/// Pushes frames into a layer-backed NSView without going through SwiftUI state, so a 60 fps
/// monitor does not re-evaluate any SwiftUI body. The IOSurface behind the CVPixelBuffer is
/// handed to Core Animation directly (no copy).
///
/// 0.58.1: `push` may be called from any thread. Program, Preview and the output windows are
/// pushed from a display queue, not the main thread, so opening a window, sheet or menu (which
/// keeps the main thread busy for a moment) no longer freezes the monitors or the picture on a
/// TV/projector. Off the main thread only plain `CALayer`s are touched (each view's
/// `pictureLayer`, set inside an explicit transaction), never NSViews.
public final class FrameFeed {
    /// Every on-screen view showing this feed (main window, Multiview, ...). Weak references.
    /// Main thread only.
    private let views = NSHashTable<PixelBufferNSView>.weakObjects()
    private let lock = NSLock()
    /// The picture layers of `views`, for pushes from any thread. Guarded by `lock`.
    private let layers = NSHashTable<CALayer>.weakObjects()
    // Keep the last two buffers alive so the pool cannot recycle a surface still on screen.
    private var current: CVPixelBuffer?
    private var previous: CVPixelBuffer?

    public init() {}

    /// Called when a view showing any feed joins or leaves a window (0.56.0), so the app can
    /// tell the engine which pictures are on screen right away.
    static var onVisibilityChange: (() -> Void)?

    /// True when at least one view of this feed can be seen: in a visible, unoccluded window, not
    /// hidden and not scrolled out of sight (0.56.0). Views not laid out yet count as visible.
    /// Main thread.
    public var isOnScreen: Bool { views.allObjects.contains { $0.isOnScreen } }

    /// Any thread.
    public func push(_ pb: CVPixelBuffer) {
        let targets: [CALayer]
        lock.lock()
        previous = current
        current = pb
        targets = layers.allObjects
        lock.unlock()
        guard !targets.isEmpty, let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in targets { l.contents = surface }
        CATransaction.commit()
    }

    public func clear() {
        lock.lock()
        current = nil; previous = nil
        let targets = layers.allObjects
        lock.unlock()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in targets { l.contents = nil }
        CATransaction.commit()
    }

    /// Attaches a view created outside SwiftUI (fullscreen output window).
    func attachView(_ v: PixelBufferNSView) { attach(v) }

    fileprivate func attach(_ v: PixelBufferNSView) {
        if v.feed !== self {
            v.feed?.detach(v)   // SwiftUI reused the view for another feed
            v.feed = self
        }
        views.add(v)
        lock.lock()
        layers.add(v.pictureLayer)
        let pb = current
        lock.unlock()
        if let pb { v.show(pb) }
    }

    fileprivate func detach(_ v: PixelBufferNSView) {
        views.remove(v)
        lock.lock()
        layers.remove(v.pictureLayer)
        lock.unlock()
    }
}

final class PixelBufferNSView: NSView {
    fileprivate weak var feed: FrameFeed?
    /// Holds the picture. A plain sublayer (not the view's own backing layer, which belongs to
    /// AppKit) so frames can be set on it from the display queue.
    let pictureLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        pictureLayer.contentsGravity = .resizeAspect
        pictureLayer.magnificationFilter = .linear
        pictureLayer.minificationFilter = .linear
        pictureLayer.frame = bounds
        pictureLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(pictureLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        FrameFeed.onVisibilityChange?()
    }

    override func layout() {
        super.layout()
        fitPicture()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitPicture()
    }

    private func fitPicture() {
        guard pictureLayer.frame != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureLayer.frame = bounds
        CATransaction.commit()
    }

    var isOnScreen: Bool {
        guard let w = window, w.isVisible, !w.isMiniaturized, w.occlusionState.contains(.visible),
              !isHiddenOrHasHiddenAncestor else { return false }
        return bounds.isEmpty || !visibleRect.isEmpty
    }

    func show(_ pb: CVPixelBuffer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() {
            pictureLayer.contents = surface
        }
        CATransaction.commit()
    }
}

struct PixelBufferView: NSViewRepresentable {
    let feed: FrameFeed
    /// Clear background instead of black, for pictures with transparency drawn over `Checkerboard`.
    var transparent = false
    func makeNSView(context: Context) -> PixelBufferNSView {
        let v = PixelBufferNSView(frame: .zero)
        if transparent { v.layer?.backgroundColor = NSColor.clear.cgColor }
        feed.attach(v)
        return v
    }
    func updateNSView(_ nsView: PixelBufferNSView, context: Context) {
        if nsView.feed !== feed { feed.attach(nsView) }
    }
}

/// Grey checkerboard shown behind transparent parts of a picture (input tiles, source viewer).
struct Checkerboard: View {
    var cell: CGFloat = 8
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.22)))
            let cols = Int(size.width / cell) + 1, rows = Int(size.height / cell) + 1
            var p = Path()
            for r in 0..<rows { for c in 0..<cols where (r + c) % 2 == 0 {
                p.addRect(CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell))
            } }
            ctx.fill(p, with: .color(Color(white: 0.30)))
        }
    }
}
#endif
