#if os(macOS)
import AppKit
import CoreVideo
import SwiftUI

/// Pushes frames into a layer-backed NSView without going through SwiftUI state, so a 60 fps
/// monitor does not re-evaluate any SwiftUI body. The IOSurface behind the CVPixelBuffer is
/// handed to Core Animation directly (no copy).
public final class FrameFeed {
    /// Every on-screen view showing this feed (main window, Multiview, ...). Weak references.
    private let views = NSHashTable<PixelBufferNSView>.weakObjects()
    // Keep the last two buffers alive so the pool cannot recycle a surface still on screen.
    private var current: CVPixelBuffer?
    private var previous: CVPixelBuffer?

    public init() {}

    public func push(_ pb: CVPixelBuffer) {
        previous = current
        current = pb
        for v in views.allObjects { v.show(pb) }
    }

    public func clear() {
        current = nil; previous = nil
        for v in views.allObjects { v.layer?.contents = nil }
    }

    /// Attaches a view created outside SwiftUI (fullscreen output window).
    func attachView(_ v: PixelBufferNSView) { attach(v) }

    fileprivate func attach(_ v: PixelBufferNSView) {
        if v.feed !== self {
            v.feed?.views.remove(v)   // SwiftUI reused the view for another feed
            v.feed = self
        }
        views.add(v)
        if let current { v.show(current) }
    }
}

final class PixelBufferNSView: NSView {
    fileprivate weak var feed: FrameFeed?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ pb: CVPixelBuffer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() {
            layer?.contents = surface
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
