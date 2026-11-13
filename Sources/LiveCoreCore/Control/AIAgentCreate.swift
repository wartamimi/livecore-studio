import Foundation

/// AI Assistant content tools (0.67.0): the assistant can create title / lower-third inputs from
/// the built-in templates (with its own text and colours), change the text of a title, create
/// running-text inputs and save macros. Pure logic: tool definitions and turning a tool call into
/// a checked request; the app creates the inputs.
extension AIAgent {
    public static var createTools: [[String: Any]] {
        let color: [String: Any] = ["type": "string", "description": "Colour as #RRGGBB or #RRGGBBAA."]
        return [
            [
                "name": "create_title",
                "description": "Creates a new title input (lower third, full-screen title, corner bug...) from a built-in template, with your text and optional colours / font. Returns the new input number. It is not shown until put on an overlay.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "template": ["type": "string", "enum": TitleTemplate.allCases.map(\.rawValue),
                                     "description": "Lower thirds: classicStrap, roundedStrap, twoTone, boxedName, accentLine, modernGlass, newsLive, minimalUnderline, pill, socialHandle, fullWidthBar, rightStrap, weddingScript, corporateSplit, goldBar, sportsBar... Titles: headline, fullScreenTitle, chapterCard, quote, endCard, breakingBanner, weddingCard, seminarTitle, sponsorCard... Corner: cornerBug, locationTag, liveBadge, hashtagTag, sponsorBug. 3D: chrome3D, gold3D, neonCube3D..."],
                        "title": ["type": "string"],
                        "subtitle": ["type": "string"],
                        "tag": ["type": "string", "description": "Small label some templates show (e.g. LIVE)."],
                        "name": ["type": "string", "description": "Input name shown in the input list."],
                        "title_color": color, "subtitle_color": color, "box_color": color, "accent_color": color,
                        "font": ["type": "string", "description": "A macOS font family, e.g. Helvetica Neue, Avenir Next, Snell Roundhand."],
                        "uppercase": ["type": "boolean"],
                        "overlay": ["type": "integer", "description": "Also load it on overlay channel 1-4 (not shown yet)."],
                    ] as [String: Any],
                    "required": ["template", "title"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "create_input",
                "description": "Adds a simple input: colour bars (test pattern) or a solid colour. Returns the new input number.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": ["colorBars", "color"]],
                        "color": color,
                        "name": ["type": "string"],
                    ] as [String: Any],
                    "required": ["kind"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "update_title",
                "description": "Changes the text of an existing title input (see get_state for numbers). Fields left out stay as they are.",
                "input_schema": [
                    "type": "object",
                    "properties": ["input": ["type": "integer"], "title": ["type": "string"], "subtitle": ["type": "string"]],
                    "required": ["input"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "create_ticker",
                "description": "Creates a running-text (ticker / crawl) input with your text. Returns the new input number.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "template": ["type": "string", "enum": TickerTemplate.allCases.map(\.rawValue)],
                        "text": ["type": "string"],
                        "name": ["type": "string"],
                        "overlay": ["type": "integer", "description": "Also load it on overlay channel 1-4 (not shown yet)."],
                    ] as [String: Any],
                    "required": ["text"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "create_macro",
                "description": "Saves a new macro (a named list of steps, same step format as run_steps) for the operator to run later. Does not run it. Returns the macro number.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "steps": stepsSchema,
                    ] as [String: Any],
                    "required": ["name", "steps"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
        ]
    }

    /// "#RRGGBB" / "#RRGGBBAA" / "RRGGBB" → colour.
    public static func color(_ v: Any?) -> ProjectColor? {
        guard var s = (v as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let n = UInt64(s, radix: 16) else { return nil }
        let full = s.count == 6 ? (n << 8) | 0xFF : n
        func c(_ shift: UInt64) -> Double { Double((full >> shift) & 0xFF) / 255 }
        return ProjectColor(r: c(24), g: c(16), b: c(8), a: c(0))
    }

    public struct TitleRequest {
        public var template: TitleTemplate
        public var title: String
        public var subtitle: String
        public var name: String?
        public var design: TitleDesign
        public var overlay: Int?
    }

    public static func titleRequest(from input: [String: Any]) -> Result<TitleRequest, StepError> {
        guard let raw = input["template"] as? String, let t = TitleTemplate(rawValue: raw) else {
            return .failure(.init("unknown template \(input["template"].map { "\($0)" } ?? "nil")"))
        }
        let title = (input["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .failure(.init("title text is missing")) }
        var d = t.defaultDesign
        if let tag = input["tag"] as? String { d.tag = tag }
        if let c = color(input["title_color"]) { d.titleColor = c }
        if let c = color(input["subtitle_color"]) { d.subtitleColor = c }
        if let c = color(input["box_color"]) { d.boxColor = c }
        if let c = color(input["accent_color"]) { d.accentColor = c }
        if let f = (input["font"] as? String)?.trimmingCharacters(in: .whitespaces), !f.isEmpty { d.fontFamily = f }
        if let u = input["uppercase"] as? Bool { d.uppercase = u }
        let overlay: Int?
        switch overlayValue(input["overlay"]) {
        case let .failure(e): return .failure(e)
        case let .success(o): overlay = o
        }
        let name = (input["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .success(TitleRequest(template: t, title: title, subtitle: input["subtitle"] as? String ?? "",
                                     name: name, design: d, overlay: overlay))
    }

    public struct TickerRequest {
        public var config: TickerConfig
        public var name: String?
        public var overlay: Int?
    }

    public static func tickerRequest(from input: [String: Any]) -> Result<TickerRequest, StepError> {
        let text = (input["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.init("text is missing")) }
        var template = TickerTemplate.allCases[0]
        if let raw = input["template"] as? String {
            guard let t = TickerTemplate(rawValue: raw) else { return .failure(.init("unknown ticker template \(raw)")) }
            template = t
        }
        switch overlayValue(input["overlay"]) {
        case let .failure(e): return .failure(e)
        case let .success(o):
            let name = (input["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .success(TickerRequest(config: template.config(text: text), name: name, overlay: o))
        }
    }

    /// A macro to save: name and checked steps (stream / record steps are allowed in a saved
    /// macro; running it from the assistant still needs the operator's permission).
    public static func macroRequest(from input: [String: Any], show: Show) -> Result<Macro, StepError> {
        let name = (input["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.init("macro name is missing")) }
        switch steps(from: input, show: show, allowOutputs: true) {
        case let .failure(e): return .failure(e)
        case let .success(st):
            var m = Macro(name: name)
            m.steps = st
            return .success(m)
        }
    }

    static func overlayValue(_ v: Any?) -> Result<Int?, StepError> {
        guard let v, !(v is NSNull) else { return .success(nil) }
        guard let o = intValue(v), (1...4).contains(o) else { return .failure(.init("overlay must be 1 to 4")) }
        return .success(o)
    }
}
