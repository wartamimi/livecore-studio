#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore

/// Keyboard shortcuts (0.62.0): a table of action → key, empty by default, saved in user
/// preferences. Key presses are caught by one local event monitor; while a text field has the
/// focus, a sheet is open or a key is being recorded, keys go to their normal place.
public enum ShortcutStore {
    static let key = "shortcuts.v2"

    public static func load() -> ShortcutMap {
        guard let d = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode(ShortcutMap.self, from: d) else { return ShortcutMap() }
        return m
    }

    public static func save(_ m: ShortcutMap) {
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// The key of an NSEvent as a KeyCombo (nil for keys that cannot be bound).
    static func combo(_ e: NSEvent) -> KeyCombo? {
        let f = e.modifierFlags
        let name: String
        switch e.keyCode {
        case 49: name = "space"
        case 36: name = "return"
        case 76: name = "kpenter"
        case 48: name = "tab"
        case 53: name = "escape"
        case 51, 117: name = "delete"
        case 126: name = "up"
        case 125: name = "down"
        case 123: name = "left"
        case 124: name = "right"
        case 116: name = "pageup"
        case 121: name = "pagedown"
        case 115: name = "home"
        case 119: name = "end"
        case 69: name = "kpplus"
        case 78: name = "kpminus"
        case 82: name = "kp0"
        case 83: name = "kp1"
        case 84: name = "kp2"
        case 85: name = "kp3"
        case 86: name = "kp4"
        case 87: name = "kp5"
        case 88: name = "kp6"
        case 89: name = "kp7"
        case 91: name = "kp8"
        case 92: name = "kp9"
        case 122: name = "f1"
        case 120: name = "f2"
        case 99: name = "f3"
        case 118: name = "f4"
        case 96: name = "f5"
        case 97: name = "f6"
        case 98: name = "f7"
        case 100: name = "f8"
        case 101: name = "f9"
        case 109: name = "f10"
        case 103: name = "f11"
        case 111: name = "f12"
        default:
            guard let c = e.charactersIgnoringModifiers?.lowercased(), let ch = c.first, c.count == 1,
                  ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol else { return nil }
            // ⇧1 gives "!" on most layouts: use the key's unshifted character.
            if f.contains(.shift), let base = Self.unshifted[e.keyCode] { name = base } else { name = String(ch) }
        }
        return KeyCombo(name, command: f.contains(.command), shift: f.contains(.shift),
                        option: f.contains(.option), control: f.contains(.control))
    }

    /// Number row key codes → digit, so ⇧1 is stored as shift + "1" on any keyboard layout.
    private static let unshifted: [UInt16: String] = [18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0"]

    static func title(_ g: ShortcutAction.Group) -> String { L10n.t("shortcut.group.\(g.rawValue)") }

    static func title(_ p: ShortcutPreset) -> String { L10n.t("shortcut.preset.\(p.rawValue)") }

    static func title(_ a: ShortcutAction) -> String {
        switch a {
        case .cut: return "CUT"
        case .auto: return "AUTO"
        case .streamToggle: return L10n.t("midi.stream")
        case .recordToggle: return L10n.t("midi.record")
        case .snapshot: return "Snapshot"
        case .fullscreenToggle: return L10n.t("midi.fullscreen")
        case .highlight: return L10n.t("highlights.midi")
        case .outputsPanel: return L10n.t("outputs.menu")
        case let .preview(n): return L10n.f("midi.preview", n)
        case let .program(n): return L10n.f("midi.cut_direct", n)
        case .previewNext: return L10n.t("shortcut.preview_next")
        case .previewPrevious: return L10n.t("shortcut.preview_previous")
        case let .overlay(n): return "Overlay \(n)"
        case let .overlayPreview(n): return "Overlay \(n) → Preview"
        case let .replay(s): return L10n.f("replay.last", s)
        case .presentationNext: return L10n.t("shortcut.presentation_next")
        case .presentationPrevious: return L10n.t("shortcut.presentation_previous")
        }
    }
}

extension AppModel {
    /// Installs the key monitor once (MainView appears).
    func installShortcutMonitor() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, !self.recordingShortcut, !e.isARepeat else { return e }
            // Typing in a field, or a sheet / alert in front: the key is not a shortcut.
            if let w = NSApp.keyWindow {
                if w.firstResponder is NSText || w.attachedSheet != nil || w.isSheet || w.isModalPanel { return e }
            }
            if NSApp.modalWindow != nil { return e }
            guard let k = ShortcutStore.combo(e), let a = self.shortcuts.action(for: k) else { return e }
            self.runShortcut(a)
            return nil
        }
    }

    func runShortcut(_ a: ShortcutAction) {
        switch a {
        case .cut: cut()
        case .auto: auto()
        case .streamToggle: requestToggleStream()
        case .recordToggle: requestToggleRecord()
        case .snapshot: saveSnapshot()
        case .fullscreenToggle: toggleFullscreen()
        case .highlight: markHighlight()
        case .outputsPanel: showOutputsPanel = true
        case let .preview(n): previewNumber(n)
        case let .program(n): if n >= 1, n <= inputs.count { cutDirect(inputs[n - 1].id) }
        case .previewNext, .previewPrevious:
            guard !inputs.isEmpty else { return }
            let cur = inputs.firstIndex { $0.id == switcher.preview } ?? -1
            let step = a == .previewNext ? 1 : -1
            let next = ((cur + step) % inputs.count + inputs.count) % inputs.count
            previewNumber(next + 1)
        case let .overlay(n): toggleOverlay(n)
        case let .overlayPreview(n): toggleOverlayPreview(n)
        case let .replay(s): replayLast(Double(s))
        case .presentationNext: presentationStep(forward: true)
        case .presentationPrevious: presentationStep(forward: false)
        }
    }

    public func saveShortcuts(_ m: ShortcutMap) { shortcuts = m; ShortcutStore.save(m) }
}

/// Settings › Keyboard: presets, search, and one row per action with a key recorder.
struct ShortcutSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Binding var map: ShortcutMap
    @State private var search = ""
    @State private var recording: ShortcutAction?
    @State private var note = ""
    @State private var monitor: Any?
    @State private var confirmPreset: ShortcutPreset?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(ShortcutPreset.allCases, id: \.self) { p in
                        Button(ShortcutStore.title(p)) { if map.isEmpty { map = p.map } else { confirmPreset = p } }
                    }
                } label: { Label(L10n.t("shortcut.preset"), systemImage: "keyboard.badge.ellipsis") }
                .fixedSize()
                Button(L10n.t("shortcut.clear_all")) { map.clearAll(); note = "" }.disabled(map.isEmpty)
                Spacer()
                TextField(L10n.t("shortcut.search"), text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
            }
            Text(map.isEmpty ? L10n.t("shortcut.empty_hint") : L10n.f("shortcut.count", map.bindings.count))
                .font(.caption).foregroundStyle(Theme.textDim)
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(Theme.warning) }
            List {
                ForEach(ShortcutAction.Group.allCases, id: \.self) { g in
                    let rows = ShortcutAction.all.filter { $0.group == g && matches($0) }
                    if !rows.isEmpty {
                        Section(ShortcutStore.title(g)) {
                            ForEach(rows, id: \.id) { a in row(a) }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .onDisappear { stopRecording() }
        .alert(L10n.t("shortcut.preset_replace"), isPresented: Binding(get: { confirmPreset != nil }, set: { if !$0 { confirmPreset = nil } }),
               presenting: confirmPreset) { p in
            Button(L10n.t("common.ok")) { map = p.map; note = "" }
            Button(L10n.t("settings.cancel"), role: .cancel) {}
        } message: { p in Text(ShortcutStore.title(p)) }
    }

    private func matches(_ a: ShortcutAction) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return ShortcutStore.title(a).lowercased().contains(q) || (map.combo(for: a)?.display.lowercased().contains(q) ?? false)
    }

    private func row(_ a: ShortcutAction) -> some View {
        HStack {
            Text(ShortcutStore.title(a)).lineLimit(1)
            Spacer()
            Button { recording == a ? stopRecording() : startRecording(a) } label: {
                Text(recording == a ? L10n.t("shortcut.press_key") : (map.combo(for: a)?.display ?? "—"))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 110)
                    .padding(.vertical, 3)
                    .background(recording == a ? Theme.accent.opacity(0.35) : Theme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            Button { map.clear(a) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(Theme.textDim)
                .opacity(map.combo(for: a) == nil ? 0 : 1)
                .help(L10n.t("shortcut.clear"))
        }
    }

    private func startRecording(_ a: ShortcutAction) {
        stopRecording()
        recording = a
        model.recordingShortcut = true
        note = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard let target = recording else { return e }
            if e.keyCode == 53 && e.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty { stopRecording(); return nil }
            guard let k = ShortcutStore.combo(e) else { NSSound.beep(); return nil }
            if k.isReserved { note = L10n.f("shortcut.reserved", k.display); NSSound.beep(); return nil }
            if let old = map.bind(k, to: target) { note = L10n.f("shortcut.moved", k.display, ShortcutStore.title(old)) }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = nil
        model.recordingShortcut = false
    }
}
#endif
