#if os(macOS)
import AppKit
import Foundation
import LiveCoreCore
import LiveCoreEngine
import LiveCoreServices

/// Safe slate and auto-director (0.71.0), checked 10 times a second from `tick`.
extension AppModel {
    func checkShowAutomation() {
        let now = CACurrentMediaTime()
        if safeSlate.isActive || safeSlateReplaced != nil { checkSafeSlate(now) }
        if autoDirector.enabled { checkAutoDirector(now) }
    }

    func resetShowAutomation() {
        safeSlateWatch.reset()
        safeSlateReplaced = nil
        director.reset()
        directorExpectedProgram = nil
    }

    // MARK: Safe slate

    /// No signal or an error counts as lost; an input that is still starting does not.
    func inputHealthy(_ id: InputID) -> Bool {
        guard let i = inputs.first(where: { $0.id == id }) else { return false }
        switch i.status {
        case .noSignal, .error: return false
        case .live, .starting: return true
        }
    }

    private func checkSafeSlate(_ now: Double) {
        let action = safeSlateWatch.update(now: now, config: safeSlate, program: switcher.program) { [unowned self] in
            self.inputHealthy($0)
        }
        switch action {
        case .none: break
        case let .cutToSlate(slate, replacing: lost):
            let name = inputs.first { $0.id == lost }?.name ?? "?"
            FileLog.shared.warning("safe slate: \(name) lost its signal, slate on Program")
            cutDirect(slate)
            report(L10n.f("slate.on", name))
        case let .returnTo(input):
            FileLog.shared.info("safe slate: signal back, returning to \(input)")
            cutDirect(input)
        }
        if safeSlateReplaced != safeSlateWatch.replaced { safeSlateReplaced = safeSlateWatch.replaced }
    }

    // MARK: Auto-director

    private func checkAutoDirector(_ now: Double) {
        // A slate standing in for a lost camera wins over the director.
        guard safeSlateReplaced == nil, switcher.transition == nil else { return }
        if switcher.program != directorExpectedProgram {
            director.noteManualSwitch(now: now)
            directorExpectedProgram = switcher.program
        }
        var levels: [String: Double] = [:]
        for p in autoDirector.pairs {
            guard let vm = audioChannels.first(where: { $0.id == p.channel }), !vm.muted,
                  let lv = meters.levels[p.channel] else { continue }
            levels[p.channel] = Double(max(lv.l, lv.r))
        }
        guard let target = director.update(now: now, levelsDB: levels, program: switcher.program, config: autoDirector) else { return }
        directorExpectedProgram = target
        if autoDirector.useTransition {
            preview(target)
            auto()
        } else {
            cutDirect(target)
        }
    }

    public func setAutoDirector(enabled: Bool) {
        autoDirector.enabled = enabled
        director.reset()
        directorExpectedProgram = switcher.program
        FileLog.shared.info("auto-director \(enabled ? "on" : "off")")
    }
}
#endif
