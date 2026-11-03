#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Settings of a live subtitle input (0.43.0).
struct SubtitleSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let input: InputID
    @State private var style = SubtitleStyle()
    /// ElevenLabs API key (Keychain); empty field = keep the stored key.
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var showAdvanced = false

    private static let languages = [("id-ID", "Bahasa Indonesia"), ("en-US", "English (US)"), ("en-GB", "English (UK)"),
                                    ("ms-MY", "Bahasa Melayu"), ("ar-SA", "العربية")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("transcription.title")).font(.headline)
            Form {
                // Model: Apple speech recognition (on this Mac / Apple servers) or ElevenLabs (0.50.4).
                Picker(L10n.t("transcription.engine"), selection: $style.provider) {
                    Text(L10n.t("transcription.apple")).tag(SubtitleProvider.apple)
                    Text("ElevenLabs (Scribe realtime)").tag(SubtitleProvider.elevenLabs)
                    Text("Groq (Whisper large-v3)").tag(SubtitleProvider.groq)
                }
                .onChange(of: style.provider) { p in
                    if p == .apple && style.locale == "auto" { style.locale = "id-ID" }
                    apiKey = ""
                    hasKey = Self.storedKey(p)
                }
                Picker(L10n.t("subtitles.language"), selection: $style.locale) {
                    if style.provider != .apple { Text(L10n.t("transcription.auto")).tag("auto") }
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                if style.provider == .elevenLabs {
                    SecureField(L10n.t("transcription.key"), text: $apiKey,
                                prompt: Text(hasKey ? L10n.t("transcription.key_stored") : "xi-api-key"))
                } else if style.provider == .groq {
                    SecureField(L10n.t("transcription.groq_key"), text: $apiKey,
                                prompt: Text(hasKey ? L10n.t("transcription.key_stored") : "gsk_…"))
                    Picker(L10n.t("transcription.groq_model"), selection: $style.advanced.groqModel) {
                        ForEach(GroqTranscription.models, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } else {
                    Toggle(L10n.t("subtitles.allow_server"), isOn: $style.allowServer)
                }
                Stepper(L10n.f("subtitles.font", "\(Int(style.fontSize))"), value: $style.fontSize, in: 24...96, step: 4)
                Stepper(L10n.f("subtitles.lines", "\(style.maxLines)"), value: $style.maxLines, in: 1...3)
                HStack { Text(L10n.t("subtitles.box")); Slider(value: $style.boxOpacity, in: 0...1) }
                HStack { Text(L10n.t("subtitles.margin")); Slider(value: $style.bottomMargin, in: 0.02...0.4) }
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    TranscriptionAdvancedView(adv: $style.advanced, provider: style.provider)
                }
            }
            .frame(maxHeight: showAdvanced ? 560 : .infinity)
            if let s = model.subtitleSource(input) {
                Text(statusLine(s)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(noteText).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.t("transcript.open")) { model.transcriptInput = input; openWindow(id: "transcript") }
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.t("settings.apply")) {
                    // "auto" exists only for the online models; Apple needs a real locale.
                    if style.provider == .apple && style.locale == "auto" { style.locale = "id-ID" }
                    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !key.isEmpty, let account = Self.keyAccount(style.provider) {
                        try? KeychainStore.save(streamKey: key, account: account)
                    }
                    let src = model.subtitleSource(input)
                    let restart = !key.isEmpty && src?.style.provider == style.provider && style.provider != .apple
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
            hasKey = Self.storedKey(style.provider)
        }
    }

    private var noteText: String {
        switch style.provider {
        case .apple: return L10n.t("subtitles.note")
        case .elevenLabs: return L10n.t("transcription.note")
        case .groq: return L10n.t("transcription.groq_note")
        }
    }

    private static func keyAccount(_ p: SubtitleProvider) -> String? {
        switch p {
        case .apple: return nil
        case .elevenLabs: return ElevenLabsRealtime.keychainAccount
        case .groq: return GroqTranscription.keychainAccount
        }
    }

    private static func storedKey(_ p: SubtitleProvider) -> Bool {
        guard let a = keyAccount(p) else { return false }
        return ((try? KeychainStore.load(account: a)) ?? nil)?.isEmpty == false
    }

    private struct TranscriptionAdvancedView: View {
        @Binding var adv: TranscriptionAdvanced
        let provider: SubtitleProvider

        var body: some View {
            Group {
                Text("Display").font(.caption.bold())
                if provider == .elevenLabs {
                    Toggle("Show words while speaking (partial text)", isOn: $adv.showPartial)
                }
                Stepper(adv.clearAfter == 0 ? "Clear captions after silence: never"
                        : String(format: "Clear captions after %.0f s of silence", adv.clearAfter),
                        value: $adv.clearAfter, in: 0...30, step: 1)
                Toggle("UPPERCASE text", isOn: $adv.uppercase)
                Text("Custom vocabulary (names, places; one per line)").font(.caption.bold())
                TextEditor(text: Binding(get: { adv.vocabulary.joined(separator: "\n") },
                                         set: { adv.vocabulary = $0.components(separatedBy: "\n") }))
                    .font(.system(size: 12)).frame(height: 60)
                if provider == .apple {
                    Picker("Speech type", selection: $adv.appleTaskHint) {
                        Text("Unspecified").tag(TranscriptionAdvanced.TaskHint.unspecified)
                        Text("Dictation (speeches, talk)").tag(TranscriptionAdvanced.TaskHint.dictation)
                        Text("Search (short phrases)").tag(TranscriptionAdvanced.TaskHint.search)
                        Text("Confirmation (yes/no)").tag(TranscriptionAdvanced.TaskHint.confirmation)
                    }
                    Toggle("Automatic punctuation", isOn: $adv.applePunctuation)
                    Text("Apple uses the vocabulary as preferred words (free).").font(.caption).foregroundStyle(.secondary)
                } else if provider == .groq {
                    Stepper(String(format: "Longest piece sent at once: %.0f s", adv.groqMaxChunk),
                            value: $adv.groqMaxChunk, in: 3...30, step: 1)
                    Text("Groq has no live stream: speech is cut at pauses (or at this length) and each piece is sent to Whisper, so text appears a few seconds after it is spoken. Shorter = quicker text but more requests (free plan: 20 per minute). The vocabulary is sent as a hint prompt.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("Send vocabulary as keyterms (max 50, ElevenLabs charges +20%)", isOn: $adv.elevenKeyterms)
                    Picker("Sentence end", selection: $adv.commitStrategy) {
                        Text("Silence detection (VAD)").tag(TranscriptionAdvanced.CommitStrategy.vad)
                        Text("Turn prediction").tag(TranscriptionAdvanced.CommitStrategy.turnPrediction)
                    }
                    optionalSlider("Silence before sentence ends (s)", $adv.vadSilenceSecs, 0.2...5, 1.5, "%.1f")
                    optionalSlider("Voice sensitivity (lower = more sensitive)", $adv.vadThreshold, 0.05...0.95, 0.4, "%.2f")
                    optionalInt("Min speech length (ms)", $adv.minSpeechMs, 20...2000, 100)
                    optionalInt("Min silence length (ms)", $adv.minSilenceMs, 20...2000, 100)
                    Toggle("Remove filler words (no verbatim)", isOn: $adv.noVerbatim)
                    Toggle("Filter background noise / speech", isOn: $adv.filterBackground)
                    TextField("Other languages expected (codes, e.g. en, ar)",
                              text: Binding(get: { adv.secondaryLanguages.joined(separator: ", ") },
                                            set: { adv.secondaryLanguages = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
                    Text("Unchecked values use ElevenLabs' defaults. Changes reconnect the transcription.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        private func optionalSlider(_ label: String, _ v: Binding<Double?>, _ r: ClosedRange<Double>, _ def: Double, _ fmt: String) -> some View {
            HStack {
                Toggle(label, isOn: Binding(get: { v.wrappedValue != nil }, set: { v.wrappedValue = $0 ? def : nil }))
                if let cur = v.wrappedValue {
                    Slider(value: Binding(get: { cur }, set: { v.wrappedValue = $0 }), in: r).frame(width: 110)
                    Text(String(format: fmt, cur)).monospacedDigit().frame(width: 36)
                }
            }
        }

        private func optionalInt(_ label: String, _ v: Binding<Int?>, _ r: ClosedRange<Int>, _ def: Int) -> some View {
            HStack {
                Toggle(label, isOn: Binding(get: { v.wrappedValue != nil }, set: { v.wrappedValue = $0 ? def : nil }))
                if let cur = v.wrappedValue {
                    Stepper("\(cur)", value: Binding(get: { cur }, set: { v.wrappedValue = $0 }), in: r, step: 20)
                }
            }
        }
    }

    private func statusLine(_ s: SubtitleSource) -> String {
        switch s.status {
        case .live where s.style.provider == .elevenLabs: return L10n.t("transcription.live")
        case .live where s.style.provider == .groq: return L10n.t("transcription.groq_live")
        case .live: return s.onDevice ? L10n.t("subtitles.on_device") : L10n.t("subtitles.server")
        default: return s.status.label
        }
    }
}
#endif
