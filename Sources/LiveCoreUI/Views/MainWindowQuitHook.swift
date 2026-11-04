#if os(macOS)
import AppKit
import SwiftUI

/// Closing the main studio window quits LiveCore Studio (0.61.0).
///
/// Before, "quit after the last window closed" never fired while any other window existed:
/// Browser / LCS Live inputs keep an off-screen host window, and Program Output, Multiview,
/// fullscreen outputs or plug-in editors may stay open. The app then kept running without a
/// window, with media, audio, streams and tunnels still going. Now the close button asks to quit
/// (same live/recording confirmation as ⌘Q), and any other close of the main window quits too.
struct MainWindowQuitHook: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HookView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class HookView: NSView {
        private weak var hooked: NSWindow?
        private var closeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window, w !== hooked else { return }
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            hooked = w
            if let close = w.standardWindowButton(.closeButton) {
                close.target = self
                close.action = #selector(closeClicked)
            }
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w,
                                                                   queue: .main) { [weak w] _ in
                // ⌘W or a programmatic close: quit unless another studio window is still open.
                guard !NSApp.windows.contains(where: { $0 !== w && $0.isVisible && HookView.isStudioWindow($0) }) else { return }
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }

        /// Another main studio window (a second WindowGroup window) keeps the app open.
        static func isStudioWindow(_ w: NSWindow) -> Bool {
            w.contentView?.firstDescendant(of: HookView.self) != nil
        }

        @objc private func closeClicked() { NSApp.terminate(nil) }

        deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for v in subviews {
            if let t = v as? T { return t }
            if let t = v.firstDescendant(of: type) { return t }
        }
        return nil
    }
}
#endif
