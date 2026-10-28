#if os(macOS)
import Foundation
import LiveCoreCore
import LiveCoreEngine

/// MultiCorder (ISO recording): chosen inputs are recorded to their own files with RECORD.
extension AppModel {
    /// Adds or removes an input from the ISO list (takes effect at the next RECORD).
    public func toggleISO(_ id: InputID) {
        var m = multiCorder
        if !m.toggle(id) { report(L10n.f("multicorder.full", MultiCorderConfig.maxInputs)); return }
        multiCorder = m
    }

    public func setMultiCorderEnabled(_ on: Bool) {
        var m = multiCorder
        m.enabled = on
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
