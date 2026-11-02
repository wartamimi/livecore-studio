#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Settings of a live subtitle input (0.43.0).
struct SubtitleSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let input: InputID
    @State private var style = SubtitleStyle()

    private static let languages = [("id-ID", "Bahasa Indonesia"), ("en-US", "English (US)"), ("en-GB", "English (UK)"),
                                    ("ms-MY", "Bahasa Melayu"), ("ar-SA", "العربية")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("subtitles.title")).font(.headline)
            Form {
                Picker(L10n.t("subtitles.language"), selection: $style.locale) {
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle(L10n.t("subtitles.allow_server"), isOn: $style.allowServer)
                Stepper(L10n.f("subtitles.font", "\(Int(style.fontSize))"), value: $style.fontSize, in: 24...96, step: 4)
                Stepper(L10n.f("subtitles.lines", "\(style.maxLines)"), value: $style.maxLines, in: 1...3)
                HStack { Text(L10n.t("subtitles.box")); Slider(value: $style.boxOpacity, in: 0...1) }
                HStack { Text(L10n.t("subtitles.margin")); Slider(value: $style.bottomMargin, in: 0.02...0.4) }
            }
            if let s = model.subtitleSource(input) {
                Text(statusLine(s)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.t("subtitles.note")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.t("settings.apply")) {
                    model.subtitleSource(input)?.update(style)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear { if let s = model.subtitleSource(input) { style = s.style } }
    }

    private func statusLine(_ s: SubtitleSource) -> String {
        switch s.status {
        case .live: return s.onDevice ? L10n.t("subtitles.on_device") : L10n.t("subtitles.server")
        default: return s.status.label
        }
    }
}
#endif
