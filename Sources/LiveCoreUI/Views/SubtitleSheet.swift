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
    /// ElevenLabs API key (Keychain); empty field = keep the stored key.
    @State private var apiKey = ""
    @State private var hasKey = false

    private static let languages = [("id-ID", "Bahasa Indonesia"), ("en-US", "English (US)"), ("en-GB", "English (UK)"),
                                    ("ms-MY", "Bahasa Melayu"), ("ar-SA", "العربية")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(style.provider == .elevenLabs ? L10n.t("transcription.title") : L10n.t("subtitles.title")).font(.headline)
            Form {
                // Live subtitles (AI) left the input menu in 0.50.3; only inputs from older projects
                // still offer the Apple engine.
                if model.subtitleSource(input)?.style.provider == .apple {
                Picker(L10n.t("transcription.engine"), selection: $style.provider) {
                    Text(L10n.t("transcription.apple")).tag(SubtitleProvider.apple)
                    Text("ElevenLabs (Scribe realtime)").tag(SubtitleProvider.elevenLabs)
                }
                }
                Picker(L10n.t("subtitles.language"), selection: $style.locale) {
                    if style.provider == .elevenLabs { Text(L10n.t("transcription.auto")).tag("auto") }
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                if style.provider == .elevenLabs {
                    SecureField(L10n.t("transcription.key"), text: $apiKey,
                                prompt: Text(hasKey ? L10n.t("transcription.key_stored") : "xi-api-key"))
                } else {
                    Toggle(L10n.t("subtitles.allow_server"), isOn: $style.allowServer)
                }
                Stepper(L10n.f("subtitles.font", "\(Int(style.fontSize))"), value: $style.fontSize, in: 24...96, step: 4)
                Stepper(L10n.f("subtitles.lines", "\(style.maxLines)"), value: $style.maxLines, in: 1...3)
                HStack { Text(L10n.t("subtitles.box")); Slider(value: $style.boxOpacity, in: 0...1) }
                HStack { Text(L10n.t("subtitles.margin")); Slider(value: $style.bottomMargin, in: 0.02...0.4) }
            }
            if let s = model.subtitleSource(input) {
                Text(statusLine(s)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(style.provider == .elevenLabs ? L10n.t("transcription.note") : L10n.t("subtitles.note")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.t("settings.apply")) {
                    // "auto" exists only for ElevenLabs; Apple needs a real locale.
                    if style.provider == .apple && style.locale == "auto" { style.locale = "id-ID" }
                    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !key.isEmpty { try? KeychainStore.save(streamKey: key, account: ElevenLabsRealtime.keychainAccount) }
                    let src = model.subtitleSource(input)
                    let restart = !key.isEmpty && src?.style.provider == .elevenLabs && style.provider == .elevenLabs
                    src?.update(style)
                    if restart { src?.reconnect() }
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear {
            if let s = model.subtitleSource(input) { style = s.style }
            hasKey = ((try? KeychainStore.load(account: ElevenLabsRealtime.keychainAccount)) ?? nil)?.isEmpty == false
        }
    }

    private func statusLine(_ s: SubtitleSource) -> String {
        switch s.status {
        case .live where s.style.provider == .elevenLabs: return L10n.t("transcription.live")
        case .live: return s.onDevice ? L10n.t("subtitles.on_device") : L10n.t("subtitles.server")
        default: return s.status.label
        }
    }
}
#endif
