#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore

/// Teleprompter state (0.71.0). Owned by AppModel; scrolling publishes only here.
public final class TeleprompterModel: ObservableObject {
    @Published public var script = TeleprompterScript() { didSet { if script.text != oldValue.text { rev += 1 } } }
    @Published public var position: Double = 0
    @Published public var running = false
    /// Changes whenever the text changes (the Web Controller fetches the text again).
    public private(set) var rev = 0
    private var lastTick: CFTimeInterval = 0

    public init() {}

    func load(_ s: TeleprompterScript) {
        running = false
        script = s
        position = 0
        rev += 1
    }

    /// Called 30 times a second while running.
    func tick() {
        let now = CACurrentMediaTime()
        let dt = lastTick == 0 ? 0 : min(now - lastTick, 0.25)
        lastTick = now
        position = script.advanced(position, by: dt)
        if position >= 1 { running = false; lastTick = 0 }
    }

    public func perform(_ c: TeleprompterCommand) {
        switch c {
        case .play: start()
        case .pause: running = false; lastTick = 0
        case .toggle: if running { perform(.pause) } else { start() }
        case .restart: position = 0
        case .faster: script.wpm = min(script.clampedWPM + 10, TeleprompterScript.wpmRange.upperBound)
        case .slower: script.wpm = max(script.clampedWPM - 10, TeleprompterScript.wpmRange.lowerBound)
        case .back: position = script.jumped(position, seconds: -5)
        case .forward: position = script.jumped(position, seconds: 5)
        case .bigger: script.fontSize = min(script.fontSize + 6, TeleprompterScript.fontRange.upperBound)
        case .smaller: script.fontSize = max(script.fontSize - 6, TeleprompterScript.fontRange.lowerBound)
        case .mirror: script.mirror.toggle()
        }
    }

    private func start() {
        if position >= 1 { position = 0 }
        lastTick = 0
        running = true
    }
}

/// Production ▸ Teleprompter: drag the window to the presenter's screen and go full screen.
/// Space = play / pause, ↑ ↓ = back / forward, ← → = slower / faster, Home = top.
public struct TeleprompterWindow: View {
    @EnvironmentObject var model: AppModel

    public init() {}

    public var body: some View {
        TeleprompterBody(p: model.prompter)
    }
}

private struct TeleprompterBody: View {
    @ObservedObject var p: TeleprompterModel
    @State private var editing = false
    @State private var contentHeight: CGFloat = 1
    @State private var showControls = true

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black
                Text(p.script.text.isEmpty ? L10n.t("prompter.empty") : p.script.text)
                    .font(.system(size: p.script.fontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineSpacing(p.script.fontSize * 0.25)
                    .frame(width: geo.size.width * 0.84, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
                    .offset(y: geo.size.height * 0.33 - CGFloat(p.position) * contentHeight)
                    .scaleEffect(x: p.script.mirror ? -1 : 1, y: 1)
                // Reading line.
                Rectangle().fill(Color.yellow.opacity(0.35)).frame(height: 2)
                    .offset(y: geo.size.height * 0.33 - 4)
            }
            .clipped()
            .onPreferenceChange(HeightKey.self) { contentHeight = max($0, 1) }
            .overlay(alignment: .bottom) { if showControls { controls.padding(10) } }
        }
        .background(KeyCatcher { key in handleKey(key) })
        .sheet(isPresented: $editing) { editor }
        .onTapGesture(count: 2) { showControls.toggle() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { p.perform(.restart) } label: { Image(systemName: "backward.end.fill") }
            Button { p.perform(.back) } label: { Image(systemName: "gobackward.5") }
            Button { p.perform(.toggle) } label: { Image(systemName: p.running ? "pause.fill" : "play.fill") }
                .keyboardShortcut(.space, modifiers: [])
            Button { p.perform(.forward) } label: { Image(systemName: "goforward.5") }
            Divider().frame(height: 18)
            Button { p.perform(.slower) } label: { Image(systemName: "tortoise.fill") }
            Text("\(Int(p.script.clampedWPM)) \(L10n.t("prompter.wpm"))").monospacedDigit().frame(minWidth: 90)
            Button { p.perform(.faster) } label: { Image(systemName: "hare.fill") }
            Divider().frame(height: 18)
            Button { p.perform(.smaller) } label: { Image(systemName: "textformat.size.smaller") }
            Button { p.perform(.bigger) } label: { Image(systemName: "textformat.size.larger") }
            Toggle(L10n.t("prompter.mirror"), isOn: $p.script.mirror).toggleStyle(.button)
            Divider().frame(height: 18)
            Button(L10n.t("prompter.edit")) { p.running = false; editing = true }
            Text(String(format: "%.0f%%", p.position * 100)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .preferredColorScheme(.dark)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("prompter.edit_title")).font(.headline)
            TextEditor(text: $p.script.text).font(.system(size: 14)).frame(minWidth: 560, minHeight: 360)
            HStack {
                Text(L10n.f("prompter.words", p.script.wordCount, Int((p.script.readingSeconds / 60).rounded(.up))))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.t("prompter.done")) { editing = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func handleKey(_ key: UInt16) -> Bool {
        switch key {
        case 126: p.perform(.back); return true       // ↑
        case 125: p.perform(.forward); return true    // ↓
        case 123: p.perform(.slower); return true     // ←
        case 124: p.perform(.faster); return true     // →
        case 115: p.perform(.restart); return true    // Home
        default: return false
        }
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Arrow keys for the prompter window (only while it is the key window).
private struct KeyCatcher: NSViewRepresentable {
    let onKey: (UInt16) -> Bool

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let c = context.coordinator
        c.onKey = onKey
        c.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak v, weak c] e in
            guard let w = v?.window, w.isKeyWindow, !(w.firstResponder is NSTextView), let c else { return e }
            return c.onKey(e.keyCode) ? nil : e
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.onKey = onKey }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var monitor: Any?
        var onKey: (UInt16) -> Bool = { _ in false }
    }
}
#endif
