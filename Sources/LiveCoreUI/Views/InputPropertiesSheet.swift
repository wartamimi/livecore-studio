#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// One window for an input's settings (0.47.0, vMix "Input Settings"): the device / source,
/// colour, key, AI and PTZ pages that used to be separate items in the input's menu.
struct InputPropertiesSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case source, color, key, ai, ptz
        var id: String { rawValue }
    }

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let input: InputID
    @State var tab: Tab

    init(input: InputID, tab: Tab = .source) {
        self.input = input
        _tab = State(initialValue: tab)
    }

    private var kind: InputKind? { model.inputs.first { $0.id == input }?.kind }

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
        if [.camera, .ndi, .videoFile, .screen, .srt, .decklink].contains(kind) { t.append(.ai) }
        if kind == .camera { t.append(.ptz) }
        return t
    }

    var body: some View {
        let tabs = Self.tabs(for: kind, operatorMode: model.isOperatorMode)
        VStack(spacing: 0) {
            HStack {
                Text(L10n.f("props.title", model.inputs.first { $0.id == input }?.name ?? "")).font(.headline)
                Spacer()
                Button(L10n.t("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], 14)
            if tabs.count > 1 {
                Picker("", selection: $tab) {
                    ForEach(tabs) { Text(L10n.t("props.tab.\($0.rawValue)")).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }
            Divider().padding(.top, 8)
            page(tabs.contains(tab) ? tab : (tabs.first ?? .color))
                .environmentObject(model)
        }
        .frame(minWidth: 520)
    }

    @ViewBuilder
    private func page(_ t: Tab) -> some View {
        switch t {
        case .source:
            switch kind {
            case .camera: CaptureCardSheet(editing: input)
            case .screen: CaptureSheet(editing: input)
            case .ndi: NDIInputSheet(editing: input)
            case .srt: SRTInputSheet(editing: input)
            case .decklink: DeckLinkInputSheet(editing: input)
            default: EmptyView()
            }
        case .color: InputAdjustSheet(input: input)
        case .key: ChromaKeySheet(input: input)
        case .ai: InputAISheet(input: input)
        case .ptz: PTZSheet(input: input)
        }
    }
}
#endif
