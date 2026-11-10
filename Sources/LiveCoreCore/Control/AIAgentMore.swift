import Foundation

// AI Assistant 0.69.0: more of the app reachable (app_action), web search through Exa, forgiving
// step names, plain-text answers (no Markdown marks in the chat).

extension AIAgent.Show {
    /// "1 Camera, 2 Logo, …" for error messages, so the model can correct itself.
    public var inputList: String {
        let list = inputs.map { i in names[i.number].map { "\(i.number) \($0)" } ?? "\(i.number)" }
        return list.isEmpty ? "none" : list.joined(separator: ", ")
    }
}

/// One app_action call, checked (input numbers are resolved by the app).
public enum AIAppAction: Equatable, Sendable {
    case previewNext, previewPrevious
    case overlayPreview(Int)
    case replay(Int)
    case tbar(Double)
    case ptzPreset(input: Int, preset: Int)
    case ptzHome(input: Int)
    case dataRow(input: Int, delta: Int)
    case dataRowSet(input: Int, row: Int)
    case qrItem(input: Int, delta: Int)
    case qrItemSet(input: Int, item: Int)
    case qrShow(input: Int)
    case fullscreen
    case presentationNext, presentationPrevious
    case openWindow(String)

    public static let actions = ["preview_next", "preview_previous", "overlay_preview", "replay", "tbar",
                                 "ptz_preset", "ptz_home", "data_row_next", "data_row_previous", "data_row_set",
                                 "qr_next", "qr_previous", "qr_set", "qr_show", "fullscreen",
                                 "slide_next", "slide_previous", "open_window"]
    public static let windows = ["multiview", "macros", "rundown", "highlights", "transcript", "program-output", "automation", "teleprompter"]

    public var needsInput: Bool {
        switch self {
        case .ptzPreset, .ptzHome, .dataRow, .dataRowSet, .qrItem, .qrItemSet, .qrShow: return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .previewNext: return "next input to Preview"
        case .previewPrevious: return "previous input to Preview"
        case let .overlayPreview(o): return "overlay \(o) on Preview"
        case let .replay(s): return "replay last \(s) s"
        case let .tbar(v): return "T-bar \(Int(v * 100))%"
        case let .ptzPreset(i, p): return "input \(i) PTZ preset \(p)"
        case let .ptzHome(i): return "input \(i) PTZ home"
        case let .dataRow(i, d): return "input \(i) data row \(d > 0 ? "next" : "previous")"
        case let .dataRowSet(i, r): return "input \(i) data row \(r)"
        case let .qrItem(i, d): return "input \(i) QR \(d > 0 ? "next" : "previous")"
        case let .qrItemSet(i, n): return "input \(i) QR item \(n)"
        case let .qrShow(i): return "input \(i) QR show / hide"
        case .fullscreen: return "full screen on / off"
        case .presentationNext: return "next slide"
        case .presentationPrevious: return "previous slide"
        case let .openWindow(w): return "open \(w)"
        }
    }

    public static func parse(_ o: [String: Any], show: AIAgent.Show) -> Result<AIAppAction, AIAgent.StepError> {
        let name = (o["action"] as? String ?? "").lowercased().replacingOccurrences(of: "-", with: "_")
        let num = AIAgent.intValue(o["number"])
        var input: Int?
        if let v = o["input"] { input = show.inputNumber(v) }
        func needInput() -> Result<Int, AIAgent.StepError> {
            guard let i = input, show.inputs.contains(where: { $0.number == i }) else {
                return .failure(.init("\(name) needs an existing input; inputs are \(show.inputList)"))
            }
            return .success(i)
        }
        switch name {
        case "preview_next": return .success(.previewNext)
        case "preview_previous": return .success(.previewPrevious)
        case "overlay_preview":
            guard let n = num, (1...4).contains(n) else { return .failure(.init("overlay_preview: number must be overlay 1 to 4")) }
            return .success(.overlayPreview(n))
        case "replay":
            return .success(.replay(min(60, max(3, num ?? 10))))
        case "tbar":
            guard let v = AIAgent.doubleValue(o["value"]) ?? num.map(Double.init), v.isFinite else {
                return .failure(.init("tbar: value 0 to 1 is missing"))
            }
            return .success(.tbar(min(1, max(0, v > 1 ? v / 100 : v))))
        case "ptz_preset":
            guard let p = num, (1...8).contains(p) else { return .failure(.init("ptz_preset: number must be preset 1 to 8")) }
            return needInput().map { .ptzPreset(input: $0, preset: p) }
        case "ptz_home": return needInput().map { .ptzHome(input: $0) }
        case "data_row_next": return needInput().map { .dataRow(input: $0, delta: 1) }
        case "data_row_previous": return needInput().map { .dataRow(input: $0, delta: -1) }
        case "data_row_set":
            guard let r = num, r >= 1 else { return .failure(.init("data_row_set: number (row, from 1) is missing")) }
            return needInput().map { .dataRowSet(input: $0, row: r) }
        case "qr_next": return needInput().map { .qrItem(input: $0, delta: 1) }
        case "qr_previous": return needInput().map { .qrItem(input: $0, delta: -1) }
        case "qr_set":
            guard let r = num, r >= 1 else { return .failure(.init("qr_set: number (item, from 1) is missing")) }
            return needInput().map { .qrItemSet(input: $0, item: r) }
        case "qr_show": return needInput().map { .qrShow(input: $0) }
        case "fullscreen": return .success(.fullscreen)
        case "slide_next": return .success(.presentationNext)
        case "slide_previous": return .success(.presentationPrevious)
        case "open_window":
            let w = (o["window"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: "-")
            guard windows.contains(w) else { return .failure(.init("open_window: window must be one of \(windows.joined(separator: ", "))")) }
            return .success(.openWindow(w))
        default:
            return .failure(.init("unknown action \"\(name)\"; use one of \(actions.joined(separator: ", "))"))
        }
    }
}

extension AIAgent {
    /// Step names as models write them: any case, with _ / - / spaces, and common synonyms.
    public static func stepKind(_ raw: String) -> MacroStepKind? {
        let key = raw.lowercased().filter { $0.isLetter }
        if let k = MacroStepKind.allCases.first(where: { $0.rawValue.lowercased() == key }) { return k }
        let synonyms: [String: MacroStepKind] = [
            "take": .cut, "fade": .auto, "mix": .auto, "dissolve": .auto,
            "onair": .program, "live": .program, "cutto": .program, "go": .transition,
            "show": .overlayOn, "showoverlay": .overlayOn, "hide": .overlayOff, "hideoverlay": .overlayOff,
            "toggleoverlay": .overlayToggle, "overlay": .overlayToggle,
            "mute": .audioOff, "unmute": .audioOn, "play": .videoPlay, "pause": .videoPause,
            "restart": .videoRestart, "rewind": .videoRestart, "delay": .wait, "sleep": .wait, "pauseseconds": .wait,
            "screenshot": .snapshot, "still": .snapshot, "mark": .highlight,
            "startstream": .streamStart, "stopstream": .streamStop, "startrecord": .recordStart, "stoprecord": .recordStop,
            "startrecording": .recordStart, "stoprecording": .recordStop, "golive": .streamStart,
        ]
        return synonyms[key]
    }

    static var extraTools: [[String: Any]] {
        [
            detailsTool,
            [
                "name": "app_action",
                "description": """
                Does one more thing the operator can do with a button or shortcut: preview_next / \
                preview_previous; overlay_preview (number = overlay 1-4 on Preview); replay (number = \
                seconds); tbar (value 0-1); ptz_preset (input, number = preset 1-8) / ptz_home (input); \
                data_row_next / data_row_previous / data_row_set (input, number = row) for titles with a \
                data source; qr_next / qr_previous / qr_set (input, number) / qr_show (input) for QR inputs; \
                fullscreen (full-screen output on / off); slide_next / slide_previous (presentation); \
                open_window (window = \(AIAppAction.windows.joined(separator: ", "))).
                """,
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": AIAppAction.actions],
                        "input": ["description": "Input number (or exact input name)"],
                        "number": ["type": "integer"],
                        "value": ["type": "number"],
                        "window": ["type": "string", "enum": AIAppAction.windows],
                    ] as [String: Any],
                    "required": ["action"],
                ] as [String: Any],
            ],
            [
                "name": "web_search",
                "description": "Looks something up on the web with Exa (needs the operator's Exa API key) and returns a short answer with sources. Use it for facts you do not know (names, scores, schedules, news) before writing them into a title.",
                "input_schema": [
                    "type": "object",
                    "properties": ["query": ["type": "string"]],
                    "required": ["query"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
        ]
    }

    // MARK: Exa

    public static let exaKeychainAccount = "exa-api-key"
    public static let exaAnswerURL = URL(string: "https://api.exa.ai/answer")!

    public static func exaAnswerBody(_ query: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["query": query, "text": false], options: [.sortedKeys])) ?? Data()
    }

    /// "answer\n\nSources: title (url), …" from an Exa /answer reply.
    public static func exaAnswerText(_ data: Data) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let answer: String
        if let a = o["answer"] as? String { answer = a }
        else if let a = o["answer"] { answer = "\(a)" }
        else { return nil }
        let cites = ((o["citations"] as? [[String: Any]]) ?? []).prefix(5).compactMap { c -> String? in
            guard let u = c["url"] as? String else { return nil }
            return (c["title"] as? String).map { "\($0) (\(u))" } ?? u
        }
        return cites.isEmpty ? answer : answer + "\n\nSources: " + cites.joined(separator: "; ")
    }

    // MARK: Suggestions (0.69.1)

    /// Splits "answer … <suggest>a\nb</suggest>" into the answer and up to 4 tap-able replies.
    /// Also accepts a block that the model left unclosed.
    public static func splitSuggestions(_ s: String) -> (text: String, suggestions: [String]) {
        guard let open = s.range(of: "<suggest>", options: .caseInsensitive) else { return (s, []) }
        let rest = s[open.upperBound...]
        let close = rest.range(of: "</suggest>", options: .caseInsensitive)
        let block = close.map { rest[..<$0.lowerBound] } ?? rest
        let after = close.map { String(rest[$0.upperBound...]) } ?? ""
        var seen = Set<String>()
        let items = block.components(separatedBy: .newlines).compactMap { raw -> String? in
            var t = raw.trimmingCharacters(in: .whitespaces)
            for p in ["- ", "* ", "• "] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
            if let dot = t.firstIndex(of: "."), t[..<dot].allSatisfy(\.isNumber), !t[..<dot].isEmpty {
                t = String(t[t.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            }
            t = plainText(t)
            guard !t.isEmpty, t.count <= 200, seen.insert(t.lowercased()).inserted else { return nil }
            return t
        }
        let text = (String(s[..<open.lowerBound]) + after).trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, Array(items.prefix(4)))
    }

    // MARK: Plain text

    /// Removes Markdown marks a model may still write (**bold**, __bold__, `code`, # headings,
    /// list bullets, [text](link)), so the chat shows clean text.
    public static func plainText(_ s: String) -> String {
        var lines: [String] = []
        var inFence = false
        for var line in s.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { lines.append(line); continue }
            if t.hasPrefix("#") {
                line = String(t.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
                let indent = line.prefix(while: { $0 == " " })
                line = indent + "• " + t.dropFirst(2)
            } else if t.hasPrefix(">") {
                line = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if t.count >= 3, t.allSatisfy({ "-*_ ".contains($0) }) {
                continue   // horizontal rule
            } else if t.hasPrefix("|"), t.allSatisfy({ "|-: ".contains($0) }) {
                continue   // table separator row
            }
            line = line.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"__(.+?)__"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![\w*])"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"`([^`\n]+)`"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[([^\]\n]+)\]\((https?://[^)\s]+)\)"#, with: "$1 ($2)", options: .regularExpression)
            line = line.replacingOccurrences(of: "**", with: "")
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The show as it is now, attached to each command so the model does not have to ask.
    public static func withState(_ command: String, stateJSON: String) -> String {
        let state = stateJSON.count > 12000 ? String(stateJSON.prefix(12000)) + "…" : stateJSON
        return command + "\n\n<app_state>\n" + state + "\n</app_state>"
    }
}
