#if os(macOS)
import Foundation
import LiveCoreCore

extension AppModel {
    /// Runs one AI Assistant app_action (0.69.0) through the same paths as shortcuts and the
    /// Web Controller, so locks set in the app still apply.
    func performAIAction(_ a: AIAppAction) {
        switch a {
        case .previewNext: runShortcut(.previewNext)
        case .previewPrevious: runShortcut(.previewPrevious)
        case let .overlayPreview(n): runShortcut(.overlayPreview(n))
        case let .replay(s): runShortcut(.replay(s))
        case .presentationNext: runShortcut(.presentationNext)
        case .presentationPrevious: runShortcut(.presentationPrevious)
        case let .tbar(v): handleRemote(.tbar(v))
        case let .ptzPreset(i, p): handleRemote(.ptzPreset(input: i, preset: p))
        case let .ptzHome(i): handleRemote(.ptzHome(input: i))
        case let .dataRow(i, d): handleRemote(.dataRow(input: i, delta: d))
        case let .dataRowSet(i, r): handleRemote(.dataRowSet(input: i, row: r))
        case let .qrItem(i, d): handleRemote(.qrItem(input: i, delta: d))
        case let .qrItemSet(i, n): handleRemote(.qrItemSet(input: i, item: n))
        case let .qrShow(i): handleRemote(.qrShow(input: i))
        case .fullscreen: handleRemote(.fullscreen)
        case .openWindow: break   // opened by the AI panel
        }
    }
}
#endif
