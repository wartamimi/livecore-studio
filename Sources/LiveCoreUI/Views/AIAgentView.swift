#if os(macOS)
import LiveCoreCore
import LiveCoreEngine
import SwiftUI

/// Production ▸ AI Assistant (0.66.0): type a command, Claude carries it out with the app's tools.
/// Every action it runs is listed (blue lines) so the operator sees exactly what happened.
struct AIAgentWindow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: AIAgentSession
    @AppStorage(AIAgentSession.providerKey) private var providerRaw = AIProvider.anthropic.rawValue
    @AppStorage(AIAgentSession.ollamaURLKey) private var ollamaURL = "http://localhost:11434"
    @State private var modelID = ""
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
        .onAppear(perform: loadProvider)
        .onChange(of: providerRaw) { _ in loadProvider() }

    }

    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .anthropic }

    private var settings: some View {
        Form {
            Picker(L10n.t("ai.provider"), selection: $providerRaw) {
                ForEach(AIProvider.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
            }
            HStack {
                TextField(L10n.t("ai.model"), text: $modelID, prompt: Text(provider.defaultModel))
                    .onChange(of: modelID) { v in
                        UserDefaults.standard.set(v.trimmingCharacters(in: .whitespaces), forKey: AIAgentSession.modelKey(provider))
                    }
                Menu(L10n.t("ai.models")) {
                    ForEach(provider.models, id: \.0) { m in Button(m.1) { modelID = m.0 } }
                }
                .fixedSize()
            }
            if provider.keychainAccount != nil {
                HStack {
                    SecureField(provider.displayName + " " + L10n.t("ai.key"), text: $apiKey,
                                prompt: Text(hasKey ? L10n.t("transcription.key_stored") : provider.keyHint))
                        .onSubmit(saveKey)
                    Button(L10n.t("ai.save_key"), action: saveKey).disabled(apiKey.isEmpty)
                }
            } else {
                TextField(L10n.t("ai.ollama_url"), text: $ollamaURL)
            }
            Toggle(L10n.t("ai.allow_outputs"), isOn: $allowOutputs)
            Text(L10n.t(provider == .ollama ? "ai.note_local" : "ai.note")).font(.caption).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadProvider() {
        let p = provider
        modelID = UserDefaults.standard.string(forKey: AIAgentSession.modelKey(p)) ?? ""
        apiKey = ""
        hasKey = p.keychainAccount.flatMap { a in (try? KeychainStore.load(account: a)) ?? nil }?.isEmpty == false
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
        guard let account = provider.keychainAccount else { return }
        try? KeychainStore.save(streamKey: k, account: account)
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
