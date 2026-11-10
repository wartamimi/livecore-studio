#if os(macOS)
import LiveCoreCore
import LiveCoreEngine
import SwiftUI

/// Production ▸ AI Assistant (0.66.0): type a command, Claude carries it out with the app's tools.
/// Every action it runs is listed (blue lines) so the operator sees exactly what happened.
struct AIAgentWindow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: AIAgentSession
    @AppStorage(AIAgentSession.modelKey) private var modelID = AIAgent.defaultModel
    @AppStorage(AIAgentSession.allowOutputsKey) private var allowOutputs = false
    @State private var command = ""
    @State private var apiKey = ""
    @State private var hasKey = false

    var body: some View {
        VStack(spacing: 0) {
            settings.padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if session.lines.isEmpty {
                            Text(L10n.t("ai.hint")).font(.callout).foregroundStyle(Theme.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(session.lines) { line in row(line).id(line.id) }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.lines.count) { _ in
                    if let last = session.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField(L10n.t("ai.placeholder"), text: $command)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                    .disabled(session.busy)
                if session.busy {
                    ProgressView().controlSize(.small)
                    Button(L10n.t("ai.stop")) { session.stop() }
                } else {
                    Button(L10n.t("ai.send"), action: send).keyboardShortcut(.return, modifiers: [.command])
                        .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button(L10n.t("ai.clear")) { session.clear() }.disabled(session.lines.isEmpty)
            }
            .padding(10)
        }
        .onAppear { hasKey = ((try? KeychainStore.load(account: AIAgent.keychainAccount)) ?? nil)?.isEmpty == false }
    }

    private var settings: some View {
        Form {
            Picker(L10n.t("ai.model"), selection: $modelID) {
                ForEach(AIAgent.models, id: \.0) { Text($0.1).tag($0.0) }
            }
            HStack {
                SecureField(L10n.t("ai.key"), text: $apiKey,
                            prompt: Text(hasKey ? L10n.t("transcription.key_stored") : "sk-ant-…"))
                    .onSubmit(saveKey)
                Button(L10n.t("ai.save_key"), action: saveKey).disabled(apiKey.isEmpty)
            }
            Toggle(L10n.t("ai.allow_outputs"), isOn: $allowOutputs)
            Text(L10n.t("ai.note")).font(.caption).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ line: AIAgentSession.Line) -> some View {
        let (icon, color): (String, Color) = {
            switch line.role {
            case .user: return ("person.fill", Theme.text)
            case .assistant: return ("sparkles", Theme.text)
            case .action: return ("bolt.fill", Theme.accent)
            case .error: return ("exclamationmark.triangle.fill", .orange)
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            Text(line.text).foregroundStyle(color).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(line.role == .action ? .system(size: 12, design: .monospaced) : .system(size: 13))
    }

    private func saveKey() {
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        try? KeychainStore.save(streamKey: k, account: AIAgent.keychainAccount)
        apiKey = ""
        hasKey = true
    }

    private func send() {
        guard !session.busy else { return }
        session.send(command)
        command = ""
    }
}
#endif
