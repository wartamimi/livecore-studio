#if os(macOS)
import LiveCoreCore
import LiveCoreEngine
import SwiftUI

/// Production ▸ AI Assistant (0.66.0, new look 0.68.0): a chat with the assistant. Commands are
/// bubbles on the right, answers on the left, every action it ran is a small ⚡ pill, and
/// suggestion chips start common jobs with one click. Provider settings fold away under ⚙︎.
struct AIAgentWindow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: AIAgentSession
    @AppStorage(AIAgentSession.providerKey) private var providerRaw = AIProvider.anthropic.rawValue
    @AppStorage(AIAgentSession.ollamaURLKey) private var ollamaURL = "http://localhost:11434"
    @AppStorage(AIAgentSession.allowOutputsKey) private var allowOutputs = false
    @State private var modelID = ""
    @State private var command = ""
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool

    private static let gradient = LinearGradient(colors: [Color(red: 0.55, green: 0.36, blue: 1), Color(red: 0.2, green: 0.6, blue: 1),
                                                          Color(red: 1, green: 0.45, blue: 0.6)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        VStack(spacing: 0) {
            header
            if showSettings {
                settings
                    .padding(12)
                    .background(Theme.panelRaised)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Divider()
            conversation
            chips
            inputBar
        }
        .background(Theme.background)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showSettings)
        .onAppear {
            loadProvider()
            if provider.keychainAccount != nil && !hasKey { showSettings = true }
            inputFocused = true
        }
        .onChange(of: providerRaw) { _ in loadProvider() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Self.gradient).frame(width: 30, height: 30)
                Image(systemName: "sparkles").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .rotationEffect(.degrees(session.busy ? 360 : 0))
                    .animation(session.busy ? .linear(duration: 2).repeatForever(autoreverses: false) : .default, value: session.busy)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t("ai.title")).font(.system(size: 14, weight: .bold))
                Text("\(provider.displayName) · \(modelID.isEmpty ? provider.defaultModel : modelID)")
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if allowOutputs {
                Label("Stream/Rec", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.program.opacity(0.25))).foregroundStyle(Theme.program)
                    .help(L10n.t("ai.allow_outputs"))
            }
            iconButton("trash", help: L10n.t("ai.clear")) { withAnimation { session.clear() } }
                .disabled(session.lines.isEmpty)
            iconButton(showSettings ? "gearshape.fill" : "gearshape", help: L10n.t("ai.settings")) { showSettings.toggle() }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 13)).frame(width: 28, height: 28)
                .background(Circle().fill(Theme.panelRaised))
        }
        .buttonStyle(.plain).help(help)
    }

    // MARK: Settings

    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .anthropic }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.t("ai.provider"), selection: $providerRaw) {
                ForEach(AIProvider.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
            }
            HStack {
                TextField(L10n.t("ai.model"), text: $modelID, prompt: Text(provider.defaultModel))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: modelID) { v in
                        UserDefaults.standard.set(v.trimmingCharacters(in: .whitespaces), forKey: AIAgentSession.modelKey(provider))
                    }
                Menu(L10n.t("ai.models")) {
                    let live = session.liveModels[provider] ?? []
                    if live.isEmpty {
                        ForEach(provider.models, id: \.0) { m in Button(m.1) { modelID = m.0 } }
                    } else {
                        ForEach(live, id: \.self) { m in Button(m) { modelID = m } }
                    }
                    Divider()
                    Button(L10n.t("ai.refresh_models")) { session.refreshModels() }
                }
                .fixedSize()
            }
            if !session.modelsNote.isEmpty {
                Text(session.modelsNote).font(.caption).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if provider.keychainAccount != nil {
                HStack {
                    SecureField(provider.displayName + " " + L10n.t("ai.key"), text: $apiKey,
                                prompt: Text(hasKey ? L10n.t("transcription.key_stored") : provider.keyHint))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    Button(L10n.t("ai.save_key"), action: saveKey).disabled(apiKey.isEmpty)
                }
            } else {
                TextField(L10n.t("ai.ollama_url"), text: $ollamaURL).textFieldStyle(.roundedBorder)
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

    private func saveKey() {
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, let account = provider.keychainAccount else { return }
        try? KeychainStore.save(streamKey: k, account: account)
        apiKey = ""
        hasKey = true
        session.refreshModels()
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if session.lines.isEmpty { emptyState }
                    ForEach(session.lines) { line in
                        bubble(line).id(line.id)
                            .transition(.asymmetric(insertion: .scale(scale: 0.85, anchor: line.role == .user ? .bottomTrailing : .bottomLeading)
                                                        .combined(with: .opacity),
                                                    removal: .opacity))
                    }
                    if session.busy { ThinkingDots().id("thinking").transition(.opacity) }
                }
                .padding(12)
                .animation(.spring(response: 0.4, dampingFraction: 0.75), value: session.lines.count)
                .animation(.easeInOut(duration: 0.2), value: session.busy)
            }
            .onChange(of: session.lines.count) { _ in scrollDown(proxy) }
            .onChange(of: session.busy) { _ in scrollDown(proxy) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            if session.busy { proxy.scrollTo("thinking", anchor: .bottom) }
            else if let last = session.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Self.gradient).frame(width: 64, height: 64).blur(radius: 14).opacity(0.7)
                Image(systemName: "wand.and.stars").font(.system(size: 30, weight: .semibold)).foregroundStyle(Self.gradient)
            }
            .padding(.top, 18)
            Text(L10n.t("ai.welcome")).font(.system(size: 16, weight: .bold))
            Text(L10n.t("ai.welcome_sub")).font(.callout).foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func bubble(_ line: AIAgentSession.Line) -> some View {
        switch line.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(line.text).font(.system(size: 13)).foregroundStyle(.white).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.accent))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle().fill(Self.gradient).frame(width: 24, height: 24)
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                }
                Text(line.text).font(.system(size: 13)).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panelRaised))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 40)
            }
        case .action:
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(.yellow)
                Text(line.text).font(.system(size: 11, design: .monospaced)).lineLimit(3).textSelection(.enabled)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Theme.preview.opacity(0.15)))
            .overlay(Capsule().stroke(Theme.preview.opacity(0.35), lineWidth: 1))
            .padding(.leading, 32)
        case .error:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(line.text).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
            .padding(.leading, 32)
        }
    }

    // MARK: Chips and input

    private var suggestions: [(String, String)] {
        [("camera.fill", L10n.t("ai.chip_switch")), ("textformat", L10n.t("ai.chip_title")),
         ("text.alignleft", L10n.t("ai.chip_ticker")), ("slider.horizontal.3", L10n.t("ai.chip_audio")),
         ("list.bullet.rectangle", L10n.t("ai.chip_macro")), ("doc.text", L10n.t("ai.chip_script"))]
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.1) { icon, text in
                    Button { command = text; inputFocused = true } label: {
                        Label(text, systemImage: icon).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Theme.panelRaised))
                            .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(ChipStyle())
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(L10n.t("ai.placeholder"), text: $command, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit(send)
                .disabled(session.busy)
            if session.busy {
                Button { session.stop() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(Circle().fill(Theme.program))
                }
                .buttonStyle(.plain).help(L10n.t("ai.stop"))
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(canSend ? AnyShapeStyle(Self.gradient) : AnyShapeStyle(Theme.panelHover)))
                }
                .buttonStyle(ChipStyle()).disabled(!canSend).help(L10n.t("ai.send"))
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(inputFocused ? AnyShapeStyle(Self.gradient) : AnyShapeStyle(Theme.border), lineWidth: inputFocused ? 1.5 : 1))
        .padding(.horizontal, 12).padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.15), value: inputFocused)
    }

    private var canSend: Bool { !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard !session.busy, canSend else { return }
        session.send(command)
        command = ""
    }
}

/// Buttons that pop a little when pressed.
private struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Three dots bouncing while the model thinks.
private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { k in
                    Circle().fill(Theme.textDim).frame(width: 7, height: 7)
                        .offset(y: -4 * max(0, sin((t * 6) - Double(k) * 0.8)))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panelRaised))
            .padding(.leading, 32)
        }
    }
}
#endif
