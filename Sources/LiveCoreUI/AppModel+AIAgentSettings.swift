#if os(macOS)
import AppKit
import Foundation
import LiveCoreCore
import LiveCoreEngine
import LiveCoreServices

/// AI Assistant settings tools (0.68.0): read / patch every input setting, the mixer, the
/// transition, delete inputs. Each change is checked by decoding the patched model first.
extension AIAgentSession {
    typealias ToolAnswer = (id: String, text: String, isError: Bool)

    func settingsTool(_ use: AIAgent.ToolUse, _ model: AppModel) -> ToolAnswer? {
        switch use.name {
        case "get_input_settings":
            guard let i = input(use, model) else { return (use.id, "No such input.", true) }
            let s = sections(i.id, name: i.name, model)
            let obj = s.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
            guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
                  let text = String(data: d, encoding: .utf8) else { return (use.id, "Cannot read the settings.", true) }
            return (use.id, text, false)
        case "set_input_settings":
            guard let i = input(use, model) else { return (use.id, "No such input.", true) }
            guard !model.isLocked(i.id) else { return (use.id, "Input \(i.number) is locked by the operator.", true) }
            let section = use.input["section"] as? String ?? ""
            let patch = use.input["patch_json"] as? String ?? ""
            if let err = apply(section, patch, to: i.id, name: i.name, model) { return (use.id, err, true) }
            lines.append(Line(role: .action, text: "input \(i.number) \(section) ← \(patch.prefix(80))"))
            return (use.id, "Input \(i.number) \(section) changed.", false)
        case "set_audio":
            return setAudio(use, model)
        case "set_transition":
            var parts: [String] = []
            if let k = use.input["kind"] as? String {
                guard let kind = TransitionKind.allCases.first(where: { "\($0)" == k }) else {
                    return (use.id, "Unknown transition \(k).", true)
                }
                model.transitionKind = kind
                parts.append(kind.displayName)
            }
            if let d = AIAgent.doubleValue(use.input["duration"]), d.isFinite {
                model.transitionDuration = min(max(d, 0.1), 10)
                parts.append(String(format: "%.1f s", model.transitionDuration))
            }
            guard !parts.isEmpty else { return (use.id, "Nothing to change.", true) }
            lines.append(Line(role: .action, text: "transition " + parts.joined(separator: ", ")))
            return (use.id, "Transition: " + parts.joined(separator: ", "), false)
        case "delete_input":
            guard let i = input(use, model) else { return (use.id, "No such input.", true) }
            if model.switcher.program == i.id { return (use.id, "Input \(i.number) is on Program; take it off air first.", true) }
            if model.isLocked(i.id) { return (use.id, "Input \(i.number) is locked by the operator.", true) }
            model.remove(i.id)
            lines.append(Line(role: .action, text: "removed input \(i.number) \"\(i.name)\" (Edit › Undo brings it back)"))
            return (use.id, "Input \(i.number) removed.", false)
        default:
            return nil
        }
    }

    private func input(_ use: AIAgent.ToolUse, _ model: AppModel) -> (id: InputID, number: Int, name: String)? {
        guard let n = AIAgent.intValue(use.input["input"]), let i = model.inputs.first(where: { $0.number == n }) else { return nil }
        return (i.id, i.number, i.name)
    }

    /// The sections this input has, as JSON objects.
    private func sections(_ id: InputID, name: String, _ model: AppModel) -> [String: Any] {
        var s: [String: Any] = [:]
        s["name"] = AIAgent.jsonObject(AINameSettings(name: name))
        if let t = model.engine?.source(id) as? TextSource {
            s["title"] = AIAgent.jsonObject(AITitleSettings(title: t.style.title, subtitle: t.style.subtitle, design: t.style.design))
        }
        if let t = model.tickerSource(id) { s["ticker"] = AIAgent.jsonObject(t.config) }
        if let q = model.qrSource(id) { s["qr"] = AIAgent.jsonObject(q.design) }
        if let t = model.timerSource(id) { s["timer"] = AIAgent.jsonObject(t.config) }
        if let v = model.virtualSetSource(id) { s["virtualSet"] = AIAgent.jsonObject(v.design) }
        s["adjust"] = AIAgent.jsonObject(model.adjust(of: id))
        s["chromaKey"] = AIAgent.jsonObject(model.chromaKey(id))
        s["layers"] = AIAgent.jsonObject(model.layers(of: id))
        return s
    }

    /// Applies a patch to one section; nil on success, else the reason.
    private func apply(_ section: String, _ patch: String, to id: InputID, name: String, _ model: AppModel) -> String? {
        func run<T: Codable>(_ value: T, _ set: (T) -> Void) -> String? {
            switch AIAgent.patched(value, patchJSON: patch) {
            case let .failure(e): return e.message
            case let .success(v): set(v); return nil
            }
        }
        switch section {
        case "name":
            return run(AINameSettings(name: name)) { model.rename(id, String($0.name.prefix(60))) }
        case "title":
            guard let t = model.engine?.source(id) as? TextSource else { return "This input is not a title." }
            return run(AITitleSettings(title: t.style.title, subtitle: t.style.subtitle, design: t.style.design)) { v in
                var style = t.style
                style.title = v.title
                style.subtitle = v.subtitle
                style.design = v.design
                model.updateTitle(id, style: style)
            }
        case "ticker":
            guard let t = model.tickerSource(id) else { return "This input is not a running text." }
            return run(t.config) { model.updateTicker(id, $0) }
        case "qr":
            guard let q = model.qrSource(id) else { return "This input is not a QR code." }
            return run(q.design) { model.updateQRCode(id, $0) }
        case "timer":
            guard let t = model.timerSource(id) else { return "This input is not a timer." }
            return run(t.config) { model.updateTimer(id, $0) }
        case "virtualSet":
            guard let v = model.virtualSetSource(id) else { return "This input is not a virtual set." }
            return run(v.design) { model.updateVirtualSet(id, $0) }
        case "adjust":
            return run(model.adjust(of: id)) { model.setAdjust(id, $0) }
        case "chromaKey":
            return run(model.chromaKey(id)) { model.setChromaKey($0, for: id) }
        case "layers":
            return run(model.layers(of: id)) { model.setLayers($0, of: id) }
        default:
            return "Unknown section \(section)."
        }
    }

    private func setAudio(_ use: AIAgent.ToolUse, _ model: AppModel) -> ToolAnswer {
        let name = (use.input["channel"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let keys = use.input.keys.filter { $0 != "channel" }.sorted()
        guard !keys.isEmpty else { return (use.id, "Nothing to change.", true) }
        if name.caseInsensitiveCompare("master") == .orderedSame {
            guard keys == ["fader"], case let .success(v) = AIAgent.audioValue("fader", use.input["fader"]), let f = v as? Double else {
                return (use.id, "Only fader (0-1) can be set on master.", true)
            }
            model.masterFader = f
            lines.append(Line(role: .action, text: String(format: "master fader %.2f", f)))
            return (use.id, "Master fader set.", false)
        }
        guard let ch = model.audioChannels.first(where: { $0.id == name })
                ?? model.audioChannels.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return (use.id, "There is no audio channel \"\(name)\".", true)
        }
        // Check everything first, then apply.
        var values: [(String, Any)] = []
        for k in keys {
            switch AIAgent.audioValue(k, use.input[k]) {
            case let .failure(e): return (use.id, e.message, true)
            case let .success(v): values.append((k, v))
            }
        }
        for (k, v) in values {
            if let b = v as? Bool, let kp = Self.boolControls[k] { ch[keyPath: kp] = b }
            if let d = v as? Double, let kp = Self.doubleControls[k] { ch[keyPath: kp] = d }
        }
        let text = values.map { k, v in "\(k)=\(v)" }.joined(separator: ", ")
        lines.append(Line(role: .action, text: "audio \(ch.name): \(text)"))
        return (use.id, "\(ch.name): \(text)", false)
    }

    static let boolControls: [String: ReferenceWritableKeyPath<ChannelVM, Bool>] = [
        "muted": \.muted, "solo": \.solo, "toProgram": \.toProgram, "toBusA": \.toBusA, "toBusB": \.toBusB,
        "toBusC": \.toBusC, "toBusD": \.toBusD, "compressor": \.compressor, "gate": \.gate, "highPass": \.highPass,
        "eq": \.eq, "lowPass": \.lowPass, "limiter": \.limiter,
    ]
    static let doubleControls: [String: ReferenceWritableKeyPath<ChannelVM, Double>] = [
        "fader": \.fader, "gainDB": \.gainDB, "pan": \.pan, "compThreshold": \.compThreshold, "compRatio": \.compRatio,
        "gateThreshold": \.gateThreshold, "highPassHz": \.highPassHz, "eqLow": \.eqLow, "eqMid": \.eqMid,
        "eqHigh": \.eqHigh, "lowPassHz": \.lowPassHz, "limiterCeiling": \.limiterCeiling,
    ]
}
#endif
