#if os(macOS)
import AppKit
import Foundation
import LiveCoreCore
import LiveCoreEngine

/// What the virtual camera can do right now (shown under EXTERNAL ⚙).
public enum VirtualCameraStatus: Equatable {
    case unknown
    /// The camera extension is not active (not installed yet, or this build cannot install it).
    case notInstalled
    /// Installed and visible to apps; LiveCore is not sending.
    case installed
    case sending
    case waitingForApproval
    case failed(String)
}

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
        virtualCameraInstaller.onResult = { [weak self] outcome in self?.virtualCameraInstallResult(outcome) }
        refreshVirtualCamera()
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

    public func setVirtualCameraOutput(_ index: Int?) {
        var r = outputRouting
        r.virtualCameraOutput = index
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
        guard let router = outputRouter else { return }
        router.setExternal(on)
        externalActive = on
        if on { connectVirtualCamera() } else { refreshVirtualCamera() }
    }

    private func connectVirtualCamera() {
        guard let router = outputRouter, outputRouting.virtualCameraOutput != nil else { refreshVirtualCamera(); return }
        switch router.startVirtualCamera() {
        case .running: virtualCamera = .sending
        case .notFound: virtualCamera = .notInstalled
        case let .failed(msg): virtualCamera = .failed(msg)
        case .off: virtualCamera = .installed
        }
    }

    public func refreshVirtualCamera() {
        if outputRouter?.virtualCamera.isRunning == true { virtualCamera = .sending; return }
        if case .waitingForApproval = virtualCamera, !VirtualCameraSender.isInstalled() { return }
        virtualCamera = VirtualCameraSender.isInstalled() ? .installed : .notInstalled
        if externalActive && virtualCamera == .installed { connectVirtualCamera() }
    }

    public func installVirtualCamera() {
        virtualCameraInstaller.activate()
    }

    public func removeVirtualCamera() {
        outputRouter?.stopVirtualCamera()
        virtualCameraInstaller.deactivate()
    }

    private func virtualCameraInstallResult(_ outcome: VirtualCameraInstaller.Outcome) {
        switch outcome {
        case .activated:
            // The camera appears a moment after activation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshVirtualCamera() }
            virtualCamera = .installed
        case .removed:
            virtualCamera = .notInstalled
        case .needsApproval:
            virtualCamera = .waitingForApproval
        case .willCompleteAfterReboot:
            virtualCamera = .failed(L10n.t("vcam.reboot"))
        case let .failed(f):
            let msg: String
            switch f {
            case .notSigned: msg = L10n.t("vcam.err_unsigned")
            case .notInApplications: msg = L10n.t("vcam.err_location")
            case .extensionMissing: msg = L10n.t("vcam.err_missing")
            case .signatureInvalid: msg = L10n.t("vcam.err_signature")
            case .cancelled: msg = L10n.t("vcam.err_cancelled")
            case let .other(s): msg = s
            }
            virtualCamera = .failed(msg)
        }
    }

    /// Opens System Settings at the extensions page, where a waiting camera extension is allowed.
    public func openExtensionSettings() {
        let urls = ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                    "x-apple.systempreferences:com.apple.preference.security"]
        for u in urls { if let url = URL(string: u), NSWorkspace.shared.open(url) { return } }
    }
}
#endif
