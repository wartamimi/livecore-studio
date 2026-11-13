#if os(macOS)
import Foundation
import LiveCoreCore

/// QR code inputs (0.58.0).
extension ProductionEngine {
    @discardableResult
    public func addQRCode(_ design: QRDesign, id: InputID? = nil) -> InputID {
        let src = QRCodeSource(id: id ?? InputID(UUID().uuidString), design: design, outputSize: settings.output.size)
        add(src)
        startOverlayAutoHide()
        return src.id
    }

    public func updateQRCode(_ id: InputID, _ design: QRDesign) {
        guard let q = source(id) as? QRCodeSource else { return }
        q.update(design)
        q.name = QRCodeSource.name(for: design)
        publishInputs()
    }

    /// Shows item `index` (0-based) of a QR input.
    public func selectQRItem(_ id: InputID, _ index: Int) {
        guard let q = source(id) as? QRCodeSource else { return }
        q.select(index)
        q.name = QRCodeSource.name(for: q.design)
        publishInputs()
    }

    public func stepQRItem(_ id: InputID, by delta: Int) {
        guard let q = source(id) as? QRCodeSource else { return }
        var d = q.design
        d.step(delta)
        selectQRItem(id, d.selected)
    }

    func startOverlayAutoHide() {
        overlayAutoHide.start { [weak self] in self?.tickOverlayAutoHide() }
    }

    /// Takes a QR overlay off air once it has been up for its "hide after" time, however it was
    /// put on (button, CUT/AUTO from Preview, remote, MIDI).
    func tickOverlayAutoHide() {
        let now = HostClock.now()
        let channels = control.read { st -> [(Int, InputID, Double)] in
            st.overlays.compactMap { ch in
                guard ch.isOn, let id = ch.source, let q = st.sources[id] as? QRCodeSource else { return nil }
                return (ch.index, id, q.design.style.autoHide)
            }
        }
        let expired = overlayAutoHide.update(channels, now: now)
        for index in expired { setOverlay(index, on: false) }
    }
}

/// Remembers since when each timed overlay has been on air.
final class OverlayAutoHide {
    private var timer: DispatchSourceTimer?
    private var since: [Int: (InputID, Double)] = [:]

    func start(_ tick: @escaping () -> Void) {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler(handler: tick)
        t.resume()
        timer = t
    }

    /// Channels now on air with a QR source and its hide time; returns the ones to take off.
    func update(_ on: [(Int, InputID, Double)], now: Double) -> [Int] {
        var expired: [Int] = []
        var next: [Int: (InputID, Double)] = [:]
        for (index, id, hide) in on {
            let start = since[index].flatMap { $0.0 == id ? $0.1 : nil } ?? now
            next[index] = (id, start)
            if hide > 0, now - start >= hide { expired.append(index) }
        }
        since = next
        return expired
    }
}
#endif
