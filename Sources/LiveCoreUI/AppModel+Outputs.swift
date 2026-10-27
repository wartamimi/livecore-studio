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
        ndiAvailable = NDIRuntime.isAvailable
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

    public func setOutputNDI(_ index: Int, _ on: Bool) {
        var r = outputRouting
        r.setNDI(index, on)
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
        if on {
            // NDI is switched on for Output 1 once, the first time EXTERNAL starts with the NDI
            // runtime installed; after that the operator's choice is kept.
            let offerNDI = ndiAvailable && !UserDefaults.standard.bool(forKey: Self.ndiOfferedKey)
            setOutputRouting(outputRouting.withDefaultSending(ndi: offerNDI))
            if offerNDI { UserDefaults.standard.set(true, forKey: Self.ndiOfferedKey) }
        }
        outputRouter?.setExternal(on)
        externalActive = on
        refreshExternalStatus()
    }

    private static let ndiOfferedKey = "outputs.ndi.offered"

    /// Re-reads which Syphon and NDI outputs run and who receives them (shown under EXTERNAL ⚙).
    public func refreshExternalStatus() {
        let s = outputRouter?.syphonStatus() ?? [:]
        if s != syphonStatus { syphonStatus = s }
        let n = outputRouter?.ndiStatus() ?? [:]
        if n != ndiStatus { ndiStatus = n }
    }
}
#endif
