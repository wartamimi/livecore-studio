/// Keyboard shortcuts (0.62.0): every switcher action can get a key, nothing is assigned by
/// default, and a few ready-made presets fill the whole table at once. Portable model; the
/// macOS app turns key presses into `KeyCombo`s and runs the bound `ShortcutAction`.

/// A key with modifiers. `key` is a normalized name: "a"..."z", "0"..."9", "f1"..."f12",
/// "kp0"..."kp9", "kpenter", "kpplus", "kpminus", "space", "return", "tab", "escape", "delete",
/// "up", "down", "left", "right", "pageup", "pagedown", "home", "end", or a punctuation character.
public struct KeyCombo: Codable, Hashable, Sendable {
    public var key: String
    public var command = false
    public var shift = false
    public var option = false
    public var control = false

    public init(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key.lowercased(); self.command = command; self.shift = shift; self.option = option; self.control = control
    }

    /// "⌃⌥⇧⌘K" as macOS menus show it.
    public var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        return s + Self.keyName(key)
    }

    public static func keyName(_ k: String) -> String {
        switch k {
        case "space": return "Space"
        case "return": return "↩"
        case "tab": return "⇥"
        case "escape": return "Esc"
        case "delete": return "⌫"
        case "up": return "↑"
        case "down": return "↓"
        case "left": return "←"
        case "right": return "→"
        case "pageup": return "PgUp"
        case "pagedown": return "PgDn"
        case "home": return "Home"
        case "end": return "End"
        case "kpenter": return "Num ↩"
        case "kpplus": return "Num +"
        case "kpminus": return "Num −"
        default:
            if k.hasPrefix("kp") { return "Num " + k.dropFirst(2) }
            if k.hasPrefix("f"), k.count > 1, Int(k.dropFirst()) != nil { return k.uppercased() }
            return k.uppercased()
        }
    }

    /// Combos the app keeps for itself (quit, close, save, open, undo, settings...).
    public var isReserved: Bool {
        guard command, !option, !control else { return false }
        let menu: Set<String> = ["q", "w", "s", "o", "z", "n", ",", "h", "m", "c", "v", "x", "a", "?"]
        return menu.contains(key) && (!shift || ["s", "z", "n", "o", "h"].contains(key))
    }
}

/// Everything a shortcut can do.
public enum ShortcutAction: Hashable, Sendable {
    case cut, auto, streamToggle, recordToggle, snapshot, fullscreenToggle, highlight, outputsPanel
    case preview(Int)          // input number 1...
    case program(Int)          // input number 1... straight to Program
    case previewNext, previewPrevious
    case overlay(Int)          // overlay 1...4 on / off Program
    case overlayPreview(Int)   // overlay 1...4 on Preview
    case replay(Int)           // seconds
    case presentationNext, presentationPrevious
    case macro(Int)            // macro 1... (0.65.0)

    public static let inputCount = 20

    /// All actions in display order.
    public static let all: [ShortcutAction] = {
        var a: [ShortcutAction] = [.cut, .auto, .previewNext, .previewPrevious]
        a += (1...inputCount).map { ShortcutAction.preview($0) }
        a += (1...inputCount).map { ShortcutAction.program($0) }
        a += (1...4).map { ShortcutAction.overlay($0) }
        a += (1...4).map { ShortcutAction.overlayPreview($0) }
        a += [5, 10, 20].map { ShortcutAction.replay($0) }
        a += [.streamToggle, .recordToggle, .snapshot, .fullscreenToggle, .highlight, .outputsPanel,
              .presentationNext, .presentationPrevious]
        a += (1...MacroBook.maxNumber).map { ShortcutAction.macro($0) }
        return a
    }()

    /// Stable id used in the saved table.
    public var id: String {
        switch self {
        case .cut: return "cut"
        case .auto: return "auto"
        case .streamToggle: return "stream"
        case .recordToggle: return "record"
        case .snapshot: return "snapshot"
        case .fullscreenToggle: return "fullscreen"
        case .highlight: return "highlight"
        case .outputsPanel: return "outputs"
        case let .preview(n): return "preview.\(n)"
        case let .program(n): return "program.\(n)"
        case .previewNext: return "preview.next"
        case .previewPrevious: return "preview.previous"
        case let .overlay(n): return "overlay.\(n)"
        case let .overlayPreview(n): return "overlayPreview.\(n)"
        case let .replay(s): return "replay.\(s)"
        case .presentationNext: return "presentation.next"
        case .presentationPrevious: return "presentation.previous"
        case let .macro(n): return "macro.\(n)"
        }
    }

    public init?(id: String) {
        guard let a = Self.all.first(where: { $0.id == id }) else { return nil }
        self = a
    }

    public enum Group: String, CaseIterable, Sendable { case switching, preview, program, overlays, replay, output, presentation, macros }

    public var group: Group {
        switch self {
        case .cut, .auto, .previewNext, .previewPrevious: return .switching
        case .preview: return .preview
        case .program: return .program
        case .overlay, .overlayPreview: return .overlays
        case .replay, .highlight: return .replay
        case .streamToggle, .recordToggle, .snapshot, .fullscreenToggle, .outputsPanel: return .output
        case .presentationNext, .presentationPrevious: return .presentation
        case .macro: return .macros
        }
    }
}

/// The user's table: action id → key. Empty by default.
public struct ShortcutMap: Codable, Equatable, Sendable {
    public private(set) var bindings: [String: KeyCombo] = [:]

    public init(_ pairs: [(ShortcutAction, KeyCombo)] = []) {
        for (a, k) in pairs { bind(k, to: a) }
    }

    public func combo(for a: ShortcutAction) -> KeyCombo? { bindings[a.id] }

    public func action(for k: KeyCombo) -> ShortcutAction? {
        bindings.first { $0.value == k }.flatMap { ShortcutAction(id: $0.key) }
    }

    /// Binds a key; the action it was bound to before (if any) loses it. Returns that action.
    @discardableResult
    public mutating func bind(_ k: KeyCombo, to a: ShortcutAction) -> ShortcutAction? {
        let previous = action(for: k)
        if let p = previous, p != a { bindings[p.id] = nil }
        bindings[a.id] = k
        return previous == a ? nil : previous
    }

    public mutating func clear(_ a: ShortcutAction) { bindings[a.id] = nil }
    public mutating func clearAll() { bindings = [:] }
    public var isEmpty: Bool { bindings.isEmpty }
}

/// Ready-made tables. Applying one replaces the whole table.
public enum ShortcutPreset: String, CaseIterable, Sendable {
    case classic, numpad, functionKeys, laptop, presenter

    public var map: ShortcutMap {
        var m = ShortcutMap()
        func b(_ a: ShortcutAction, _ k: KeyCombo) { m.bind(k, to: a) }
        switch self {
        case .classic:
            // Space / Return, number row for Preview, ⇧ number for Program.
            b(.cut, KeyCombo("space")); b(.auto, KeyCombo("return"))
            for n in 1...9 { b(.preview(n), KeyCombo("\(n)")); b(.program(n), KeyCombo("\(n)", shift: true)) }
            b(.preview(10), KeyCombo("0")); b(.program(10), KeyCombo("0", shift: true))
            for n in 1...4 { b(.overlay(n), KeyCombo("f\(n)")); b(.overlayPreview(n), KeyCombo("f\(n)", shift: true)) }
            b(.streamToggle, KeyCombo("l", command: true)); b(.recordToggle, KeyCombo("r", command: true))
            b(.snapshot, KeyCombo("p", command: true, option: true))
            b(.presentationNext, KeyCombo("pagedown")); b(.presentationPrevious, KeyCombo("pageup"))
        case .numpad:
            // Number pad as a switcher: digits pick Preview, Enter cuts, + runs AUTO.
            for n in 1...9 { b(.preview(n), KeyCombo("kp\(n)")); b(.program(n), KeyCombo("kp\(n)", control: true)) }
            b(.preview(10), KeyCombo("kp0"))
            b(.cut, KeyCombo("kpenter")); b(.auto, KeyCombo("kpplus"))
            b(.previewNext, KeyCombo("right")); b(.previewPrevious, KeyCombo("left"))
            for n in 1...4 { b(.overlay(n), KeyCombo("f\(n)")) }
            b(.replay(5), KeyCombo("kpminus"))
            b(.streamToggle, KeyCombo("l", command: true)); b(.recordToggle, KeyCombo("r", command: true))
        case .functionKeys:
            // F1–F8 Preview, ⇧F1–F8 Program, F9 CUT, F10 AUTO.
            for n in 1...8 { b(.preview(n), KeyCombo("f\(n)")); b(.program(n), KeyCombo("f\(n)", shift: true)) }
            b(.cut, KeyCombo("f9")); b(.auto, KeyCombo("f10"))
            for n in 1...4 { b(.overlay(n), KeyCombo("f\(n)", option: true)) }
            b(.streamToggle, KeyCombo("l", command: true)); b(.recordToggle, KeyCombo("r", command: true))
        case .laptop:
            // Letters only (no number pad): top row Preview, home row Program, bottom row overlays.
            for (i, k) in ["q", "w", "e", "r", "t", "y", "u", "i", "o"].enumerated() { b(.preview(i + 1), KeyCombo(k)) }
            for (i, k) in ["a", "s", "d", "f", "g", "h", "j", "k", "l"].enumerated() { b(.program(i + 1), KeyCombo(k)) }
            for (i, k) in ["z", "x", "c", "v"].enumerated() { b(.overlay(i + 1), KeyCombo(k)) }
            b(.cut, KeyCombo("space")); b(.auto, KeyCombo("return"))
            b(.highlight, KeyCombo("m"))
            b(.streamToggle, KeyCombo("l", command: true)); b(.recordToggle, KeyCombo("r", command: true))
        case .presenter:
            // Presentation clickers send Page Up / Page Down (and arrows).
            b(.presentationNext, KeyCombo("pagedown")); b(.presentationPrevious, KeyCombo("pageup"))
            b(.previewNext, KeyCombo("right")); b(.previewPrevious, KeyCombo("left"))
            b(.cut, KeyCombo("space")); b(.auto, KeyCombo("return"))
            b(.overlay(1), KeyCombo("b"))
        }
        return m
    }
}
