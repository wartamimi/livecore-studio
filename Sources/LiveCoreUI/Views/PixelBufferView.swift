#if os(macOS)
import AppKit
import CoreVideo
import SwiftUI

/// Pushes frames into a layer-backed NSView without going through SwiftUI state, so a 60 fps
/// monitor does not re-evaluate any SwiftUI body. The IOSurface behind the CVPixelBuffer is
/// handed to Core Animation directly (no copy).
public final class FrameFeed {
    fileprivate weak var view: PixelBufferNSView?
    // Keep the last two buffers alive so the pool cannot recycle a surface still on screen.
    private var current: CVPixelBuffer?
    private var previous: CVPixelBuffer?

    public init() {}

    public func push(_ pb: CVPixelBuffer) {
        previous = current
        current = pb
        view?.show(pb)
    }

    public func clear() {
        current = nil; previous = nil
        view?.layer?.contents = nil
    }

    fileprivate func attach(_ v: PixelBufferNSView) {
        view = v
        if let current { v.show(current) }
    }
}

final class PixelBufferNSView: NSView {
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
    func makeNSView(context: Context) -> PixelBufferNSView {
        let v = PixelBufferNSView(frame: .zero)
        feed.attach(v)
        return v
    }
    func updateNSView(_ nsView: PixelBufferNSView, context: Context) {
        if feed.view !== nsView { feed.attach(nsView) }
    }
}
#endif
