#if os(macOS)
import AppKit
import Foundation
import LiveCoreCore
import LiveCoreEngine

extension AppModel {
    private static let routingKey = "outputs.routing"

    func makeOutputFullscreens() -> [Int: FullscreenOutput] {
        var d: [Int: FullscreenOutput] = [:]
        for i in 1...OutputRouting.count {
            let f = FullscreenOutput(feed: outputFeeds[i]!, keyPrefix: "output\(i).fullscreen")
            f.onActiveChange = { [weak self] _ in self?.updateOutputWindow(i) }
            d[i] = f
        }
        return d
    }

    func startOutputs(_ e: ProductionEngine) {
        let router = OutputRouter(engine: e)
        router.onWindowFrame = { [weak self] i, pb in self?.outputFeeds[i]?.push(pb) }
        router.onError = { [weak self] msg in self?.report(msg) }
        outputRouter = router
        if let data = UserDefaults.standard.data(forKey: Self.routingKey),
           let r = try? JSONDecoder().decode(OutputRouting.self, from: data) {
            outputRouting = r
        }
        router.setRouting(outputRouting)
    }

    // MARK: Routing

    func setOutputRouting(_ r: OutputRouting) {
        outputRouter?.setRouting(r)
        outputRouting = outputRouter?.routing ?? r
        if let data = try? JSONEncoder().encode(outputRouting) { UserDefaults.standard.set(data, forKey: Self.routingKey) }
    }

    public func setOutputSource(_ index: Int, _ source: OutputSource) {
        var r = outputRouting
        r.setSource(index, source)
        setOutputRouting(r)
    }

    public func setOutputSyphon(_ index: Int, _ on: Bool) {
        var r = outputRouting
        r.setSyphon(index, on)
        setOutputRouting(r)
    }

    func outputInputsChanged() {
        guard let router = outputRouter else { return }
        router.inputsChanged()
        if router.routing != outputRouting { setOutputRouting(router.routing) }
    }

    public func outputSourceName(_ s: OutputSource) -> String {
        switch s {
        case .program: return L10n.t("monitor.program")
        case .preview: return L10n.t("monitor.preview")
        case let .input(id):
            guard let i = inputs.first(where: { $0.id == id }) else { return L10n.t("monitor.no_input") }
            return "\(i.number) \(i.name)"
        }
    }

    // MARK: Windows

    /// An output window appeared or closed.
    public func setOutputWindow(_ index: Int, open: Bool) {
        if open { outputWindows.insert(index) } else { outputWindows.remove(index) }
        updateOutputWindow(index)
    }

    private func updateOutputWindow(_ index: Int) {
        let showing = outputWindows.contains(index) || outputFullscreens[index]?.isActive == true
        outputRouter?.setWindow(index, open: showing)
        if !showing { outputFeeds[index]?.clear() }
    }

    // MARK: EXTERNAL

    public func toggleExternal() {
        setExternal(!externalActive)
    }

    public func setExternal(_ on: Bool) {
        guard outputRouter != nil else { return }
        if on { setOutputRouting(outputRouting.withDefaultSyphon()) }
        outputRouter?.setExternal(on)
        externalActive = on
        refreshSyphonStatus()
    }

    /// Re-reads which Syphon outputs run and which have an app connected (shown under EXTERNAL ⚙).
    public func refreshSyphonStatus() {
        let s = outputRouter?.syphonStatus() ?? [:]
        if s != syphonStatus { syphonStatus = s }
    }
}
#endif
