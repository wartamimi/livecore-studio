#if os(macOS)
import AppKit
import Foundation
import QuartzCore
import LiveCoreCore
import LiveCoreEngine

/// Show graphics (0.74.0): scoreboard and automatic speaker name tags.
extension AppModel {
    // MARK: Scoreboard

    var titleInputs: [ProductionEngine.InputInfo] { inputs.filter { $0.kind == .text } }

    public func score(_ c: ScoreCommand) { scoreboard.perform(c) }

    /// Writes the score into its title input (called whenever `scoreboard` changes).
    func applyScore() {
        guard let id = scoreboard.input else { return }
        setTitleText(id, title: scoreboard.titleText, subtitle: scoreboard.subtitleText)
    }

    func setTitleText(_ id: InputID, title: String, subtitle: String) {
        guard var style = textSource(id)?.style, style.title != title || style.subtitle != subtitle else { return }
        style.title = title
        style.subtitle = subtitle
        updateTitle(id, style: style)
    }

    // MARK: Name tags

    /// Called on every Program change: shows the speaker's name tag for a few seconds.
    func showNameTag(for program: InputID?) {
        guard let program, let tag = nameTagger.onProgram(program, now: CACurrentMediaTime(), config: nameTags),
              let title = nameTags.title, let e = engine else { return }
        let n = nameTags.overlayIndex
        setTitleText(title, title: tag.name, subtitle: tag.role)
        if e.overlays.first(where: { $0.index == n })?.source != title { configureOverlay(n, source: title, preset: .fullScreen) }
        e.setOverlay(n, on: true)
        overlays = e.overlays
        nameTagToken += 1
        let token = nameTagToken
        DispatchQueue.main.asyncAfter(deadline: .now() + nameTags.showSeconds) { [weak self] in
            guard let self, self.nameTagToken == token, let e = self.engine,
                  e.overlays.first(where: { $0.index == n })?.source == title else { return }
            e.setOverlay(n, on: false)
            self.overlays = e.overlays
        }
    }
}
#endif
