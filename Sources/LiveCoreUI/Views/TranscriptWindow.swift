#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LiveCoreCore
import LiveCoreEngine

/// Transcript window (0.57.0): every finished sentence of a Realtime Transcription input collects
/// here while it runs, so the operator can select, copy or save the text (for notes or a summary).
struct TranscriptWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var lines: [TranscriptLine] = []
    @State private var revision = -1
    @State private var timestamps = false
    @State private var follow = true
    @State private var copied = false
    @Environment(\.openWindow) private var openWindow
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var transcriptionInputs: [ProductionEngine.InputInfo] { model.inputs.filter { $0.kind == .subtitles } }
    private var current: InputID? { model.transcriptInput ?? transcriptionInputs.first?.id }
    private var text: String { TranscriptLine.join(lines, timestamps: timestamps) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if transcriptionInputs.count > 1 {
                    Picker("", selection: Binding(get: { current }, set: { model.transcriptInput = $0; revision = -1 })) {
                        ForEach(transcriptionInputs, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden().frame(maxWidth: 200)
                }
                Toggle(L10n.t("transcript.timestamps"), isOn: $timestamps)
                Toggle(L10n.t("transcript.follow"), isOn: $follow)
                Spacer()
                Text(L10n.f("transcript.count", "\(lines.count)")).font(.caption).foregroundStyle(Theme.textDim)
            }
            TranscriptTextView(text: text, follow: follow)
                .overlay {
                    if lines.isEmpty {
                        Text(current == nil ? L10n.t("transcript.no_input") : L10n.t("transcript.empty"))
                            .foregroundStyle(Theme.textDim).multilineTextAlignment(.center).padding()
                    }
                }
            HStack {
                Button(L10n.t("transcript.clear")) {
                    if let id = current { model.subtitleSource(id)?.clearTranscriptLog() }
                    refresh()
                }
                .disabled(lines.isEmpty)
                Spacer()
                if copied { Text(L10n.t("transcript.copied")).font(.caption).foregroundStyle(Theme.textDim) }
                // 0.71.0: summary, minutes and YouTube chapters by the AI Assistant's provider.
                Menu(L10n.t("transcript.ai")) {
                    ForEach(AIAgent.SummaryKind.allCases, id: \.self) { k in
                        Button(L10n.t("transcript.ai.\(k.rawValue)")) {
                            model.aiAgent.send(AIAgent.summaryCommand(k, transcript: TranscriptLine.join(lines, timestamps: true)),
                                               shown: L10n.t("transcript.ai.\(k.rawValue)") + " (\(lines.count) " + L10n.t("transcript.lines") + ")")
                            openWindow(id: "ai-assistant")
                        }
                    }
                }
                .fixedSize()
                .disabled(lines.isEmpty)
                Button(L10n.t("transcript.save")) { save() }.disabled(lines.isEmpty)
                Button(L10n.t("transcript.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(lines.isEmpty)
            }
        }
        .padding(12)
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        guard let id = current, let src = model.subtitleSource(id) else {
            if !lines.isEmpty { lines = [] }
            return
        }
        let log = src.transcriptLog
        guard log.revision != revision else { return }
        revision = log.revision
        lines = log.lines
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        panel.nameFieldStringValue = "Transcript \(f.string(from: Date())).txt"
        let body = text
        if panel.runModal() == .OK, let url = panel.url {
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Read-only, selectable text that keeps the newest line in view while `follow` is on.
private struct TranscriptTextView: NSViewRepresentable {
    let text: String
    let follow: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = false
            tv.font = .systemFont(ofSize: 14)
            tv.textContainerInset = NSSize(width: 6, height: 6)
            tv.backgroundColor = NSColor(Theme.panel)
            tv.textColor = .white
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        // Keep the operator's selection when new lines arrive below it.
        let sel = tv.selectedRanges
        tv.string = text
        let len = (text as NSString).length
        let kept = sel.filter { NSMaxRange($0.rangeValue) <= len }
        tv.selectedRanges = kept.isEmpty ? [NSValue(range: NSRange(location: len, length: 0))] : kept
        // Not while the operator is selecting text.
        if follow && kept.allSatisfy({ $0.rangeValue.length == 0 }) { tv.scrollToEndOfDocument(nil) }
    }
}
#endif
