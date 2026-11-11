#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// One window for an input's settings (0.47.0, vMix "Input Settings"): source, colour, key,
/// animation, AI and PTZ pages. 0.62.0: sized from the screen it opens on (small MacBook screens
/// get a smaller window, external monitors a larger one), a sidebar of pages when there is room
/// and a compact page menu when there is not, and LUT / Mask / Wave / motion on their own
/// Animation page.
struct InputPropertiesSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case source, color, key, animation, ai, ptz
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .source: return "video"
            case .color: return "paintpalette"
            case .key: return "wand.and.rays"
            case .animation: return "sparkles"
            case .ai: return "brain"
            case .ptz: return "arrow.up.and.down.and.arrow.left.and.right"
            }
        }
    }

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let input: InputID
    @State var tab: Tab

    init(input: InputID, tab: Tab = .source) {
        self.input = input
        _tab = State(initialValue: tab)
    }

    private var info: ProductionEngine.InputInfo? { model.inputs.first { $0.id == input } }
    private var kind: InputKind? { info?.kind }

    /// Header colour and text follow the input's tally state.
    private var tally: (color: Color, label: String) {
        if model.switcher.program == input { return (Theme.program, L10n.t("monitor.program")) }
        if model.switcher.preview == input { return (Theme.preview, L10n.t("monitor.preview")) }
        return (Theme.accent, info?.status.label ?? "")
    }

    /// Pages that apply to this kind of input, in order.
    static func tabs(for kind: InputKind?, operatorMode: Bool) -> [Tab] {
        guard let kind else { return [] }
        var t: [Tab] = []
        switch kind {
        case .camera: if !operatorMode { t.append(.source) }
        case .screen, .ndi, .srt, .decklink: t.append(.source)
        default: break
        }
        if kind != .scene { t.append(.color) }
        if [.camera, .videoFile, .image, .ndi, .srt, .decklink].contains(kind) { t.append(.key) }
        if kind != .scene { t.append(.animation) }
        if [.camera, .ndi, .videoFile, .screen, .srt, .decklink].contains(kind) { t.append(.ai) }
        if kind == .camera { t.append(.ptz) }
        return t
    }

    /// Window size from the screen: about 60 % × 80 % of it, within sensible limits.
    private static var size: CGSize {
        let v = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: min(max(v.width * 0.6, 560), 940), height: min(max(v.height * 0.8, 460), 820))
    }

    var body: some View {
        let tabs = Self.tabs(for: kind, operatorMode: model.isOperatorMode)
        let current = tabs.contains(tab) ? tab : (tabs.first ?? .color)
        let s = Self.size
        let state = tally
        VStack(spacing: 0) {
            DialogHeader(icon: kind?.symbol ?? "slider.horizontal.3",
                         title: L10n.f("props.title", info?.name ?? ""),
                         subtitle: info.map { "\($0.number) · \(state.label)" },
                         color: state.color, close: { dismiss() }) {
                if tabs.count > 1 && s.width < 700 {
                    Picker("", selection: $tab) {
                        ForEach(tabs) { Label(L10n.t("props.tab.\($0.rawValue)"), systemImage: $0.icon).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            HStack(spacing: 0) {
                if tabs.count > 1 && s.width >= 700 {
                    VStack(spacing: 3) {
                        ForEach(tabs) { t in
                            SidebarRow(title: L10n.t("props.tab.\(t.rawValue)"), icon: t.icon, selected: current == t) { tab = t }
                        }
                        Spacer()
                    }
                    .padding(8)
                    .frame(width: 180)
                    .background(Theme.panel)
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
                }
                page(current)
                    .environmentObject(model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // The sheet opened at its minimum width while the sidebar (168) + a 500-wide source page
        // need more, so both sides were cut off (0.63.2): open at the computed size.
        .frame(minWidth: s.width, idealWidth: s.width, maxWidth: .infinity, minHeight: s.height, idealHeight: s.height, maxHeight: .infinity)
    }

    @ViewBuilder
    private func page(_ t: Tab) -> some View {
        switch t {
        case .source:
            Group {
                switch kind {
                case .camera: CaptureCardSheet(editing: input)
                case .screen: CaptureSheet(editing: input)
                case .ndi: NDIInputSheet(editing: input)
                case .srt: SRTInputSheet(editing: input)
                case .decklink: DeckLinkInputSheet(editing: input)
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        case .color: InputAdjustSheet(input: input, embedded: true)
        case .key: ScrollView { ChromaKeySheet(input: input).frame(maxWidth: .infinity) }
        case .animation: InputAnimationPage(input: input)
        case .ai: ScrollView { InputAISheet(input: input).frame(maxWidth: .infinity) }
        case .ptz: ScrollView { PTZSheet(input: input).frame(maxWidth: .infinity) }
        }
    }
}

/// Properties › Animation (0.62.0): LUT, mask, waving flag and looping motion of one input.
struct InputAnimationPage: View {
    @EnvironmentObject var model: AppModel
    let input: InputID
    @State private var a = InputAdjust()

    var body: some View {
        Form {
            MotionSection(adjust: Binding(get: { a }, set: { a = $0; model.setAdjust(input, $0) }))
            MaskWaveSection(adjust: Binding(get: { a }, set: { a = $0; model.setAdjust(input, $0) }))
            LUTSection(input: input, adjust: $a)
        }
        .formStyle(.grouped)
        .onAppear {
            a = model.adjust(of: input)
            model.preview(input)
        }
    }
}

/// Looping motion of an input (0.62.0).
struct MotionSection: View {
    @Binding var adjust: InputAdjust

    var body: some View {
        Section(L10n.t("motion.title")) {
            Picker(L10n.t("motion.kind"), selection: Binding(get: { adjust.motion.kind }, set: { k in
                if k != adjust.motion.kind { adjust.motion.speed = InputMotion.defaultSpeed(k) }
                adjust.motion.kind = k
            })) {
                ForEach(InputMotion.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if adjust.motion.kind != .none {
                LabeledContent(L10n.t("motion.amount")) {
                    Slider(value: $adjust.motion.amount, in: 0...1)
                    Text("\(Int((adjust.motion.amount * 100).rounded()))%").monospacedDigit().frame(width: 46, alignment: .trailing)
                }
                LabeledContent(L10n.t("motion.speed")) {
                    Slider(value: $adjust.motion.speed, in: 0.05...4)
                    Text(String(format: "%.2f/s", adjust.motion.speed)).monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                Button(L10n.t("motion.off")) { adjust.motion = InputMotion() }
            }
            Text(L10n.t("motion.hint")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
        }
    }
}
#endif

