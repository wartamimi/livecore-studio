#if os(macOS)
import Foundation
import LiveCoreCore
import LiveCoreEngine

/// MultiCorder (ISO recording): chosen inputs recorded to their own files, with its own
/// MULTICORDER button and recording profile (Settings › MultiCorder).
extension AppModel {
    public var isMultiCorderRunning: Bool { engine?.isMultiCorderRunning ?? false }

    /// MULTICORDER button: starting is immediate, stopping asks first (like RECORD). The dock
    /// padlock covers it too.
    public func requestToggleMultiCorder() {
        guard !recordLocked else { report(L10n.t("lock.record_locked")); return }
        if isMultiCorderRunning { pendingStop = .multicorder } else { toggleMultiCorder() }
    }

    public func toggleMultiCorder() {
        guard let e = engine else { return }
        if e.isMultiCorderRunning {
            e.stopMultiCorder()
            objectWillChange.send()
            return
        }
        guard !multiCorder.inputs.isEmpty else { report(L10n.t("multicorder.choose_first")); return }
        e.multiCorder = multiCorder
        if e.startMultiCorder() == 0 { report(L10n.t("multicorder.choose_first")) }
        objectWillChange.send()
    }

    /// Adds or removes an input from the ISO list (takes effect at the next start).
    public func toggleISO(_ id: InputID) {
        var m = multiCorder
        if !m.toggle(id) { report(L10n.f("multicorder.full", MultiCorderConfig.maxInputs)); return }
        multiCorder = m
    }

    public struct ISOFile: Identifiable {
        public let input: ProductionEngine.InputInfo
        public let stats: RecordingEngine.Stats
        public var id: InputID { input.id }
    }

    /// ISO files of the current / last recording, in input order.
    public var isoFiles: [ISOFile] {
        inputs.compactMap { i in isoStats[i.id].map { ISOFile(input: i, stats: $0) } }
    }
}
#endif
