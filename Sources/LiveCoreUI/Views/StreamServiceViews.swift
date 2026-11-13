#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Service picker for one stream destination (0.75.0, like OBS): fills the name and servers,
/// opens the platform's stream-key page, and for YouTube / Twitch logs in and fetches the key.
struct StreamServiceRow: View {
    @EnvironmentObject var model: AppModel
    @Binding var name: String
    @Binding var server: String
    @Binding var backup: String
    @Binding var key: String
    @State private var login: StreamService.Login?

    private var service: StreamService? { StreamService.match(server) }

    var body: some View {
        HStack {
            Menu {
                ForEach(StreamService.all) { s in Button(s.name) { apply(s) } }
                Divider()
                Button(L10n.t("stream.service_custom")) { server = ""; backup = "" }
            } label: {
                Label(service?.name ?? L10n.t("stream.service_custom"), systemImage: "dot.radiowaves.left.and.right")
            }
            .fixedSize()
            Spacer()
            if let s = service ?? StreamService.all.first(where: { $0.name == name }) {
                Button { open(s.keyPage) } label: { Label(L10n.t("stream.get_key"), systemImage: "key") }
                if let l = s.login {
                    Button { login = l } label: { Label(L10n.t("stream.login"), systemImage: "person.badge.key") }
                }
            }
        }
        .dialog(item: $login, model) { l in
            StreamLoginSheet(login: l) { srv, k in server = srv; key = k }
        }
    }

    private func apply(_ s: StreamService) {
        name = s.name; server = s.server; backup = s.backup
        if s.server.isEmpty { open(s.keyPage) }   // per-account server: copy it from the platform
    }
}

extension StreamService.Login: Identifiable { public var id: String { rawValue } }

private func open(_ url: String) { URL(string: url).map { _ = NSWorkspace.shared.open($0) } }

/// Device login (OAuth 2.0 device flow): shows the code, opens the platform's page, waits for
/// the operator to approve, then reads the server and stream key from the platform's API.
/// Needs the operator's own client ID (Google Cloud / Twitch developer console); LiveCore ships none.
private struct StreamLoginSheet: View {
    let login: StreamService.Login
    let done: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var secret = ""
    @State private var code: StreamLoginAPI.DeviceCode?
    @State private var status = ""
    @State private var task: Task<Void, Never>?

    private var api: StreamLoginAPI.Endpoints { StreamLoginAPI.endpoints(login) }
    private var account: String { "oauth-\(login.rawValue)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DialogTitle("person.badge.key", L10n.f("stream.login_title", login == .youtube ? "YouTube" : "Twitch"))
            Text(L10n.t("stream.login_help_\(login.rawValue)")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.t("stream.login_console")) { open(api.consolePage) }
            TextField("Client ID", text: $clientID)
            if api.needsSecret { SecureField("Client secret", text: $secret) }
            if let code {
                HStack {
                    Text(code.userCode).font(.system(size: 22, weight: .bold, design: .monospaced)).textSelection(.enabled)
                    Button(L10n.t("stream.login_open")) { open(code.verificationURL) }
                }
            }
            if !status.isEmpty { Text(status).font(.system(size: 11)).foregroundStyle(Theme.warning) }
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { task?.cancel(); dismiss() }
                Button(L10n.t("stream.login")) { start() }
                    .disabled(clientID.isEmpty || (api.needsSecret && secret.isEmpty) || task != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear {
            clientID = (try? KeychainStore.load(account: account + "-id")) ?? ""
            secret = (try? KeychainStore.load(account: account + "-secret")) ?? ""
        }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        try? KeychainStore.save(streamKey: clientID, account: account + "-id")
        if !secret.isEmpty { try? KeychainStore.save(streamKey: secret, account: account + "-secret") }
        status = ""
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let (srv, key) = try await run()
                done(srv, key)
                dismiss()
            } catch is CancellationError {
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func run() async throws -> (String, String) {
        let dc = try await post(api.device, StreamLoginAPI.deviceRequest(login, clientID: clientID))
        guard let c = StreamLoginAPI.parseDeviceCode(dc) else { throw LoginError(String(decoding: dc, as: UTF8.self)) }
        code = c
        open(c.verificationURL)
        var wait = c.interval
        while true {
            try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            let body = StreamLoginAPI.tokenRequest(login, clientID: clientID, secret: secret, deviceCode: c.deviceCode)
            switch StreamLoginAPI.parseToken(try await post(api.token, body)) {
            case .pending: continue
            case .slowDown: wait += 5
            case let .failed(e): throw LoginError(e)
            case let .token(t): return try await streamTarget(token: t)
            }
        }
    }

    private func streamTarget(token: String) async throws -> (String, String) {
        switch login {
        case .youtube:
            let base = "https://www.googleapis.com/youtube/v3/liveStreams?part=snippet,cdn"
            if let r = StreamLoginAPI.parseYouTubeStream(try await get(base + "&mine=true", token)) { return r }
            var req = request(base, token)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = StreamLoginAPI.youTubeNewStream
            let d = try await send(req)
            guard let r = StreamLoginAPI.parseYouTubeStream(d) else { throw LoginError(String(decoding: d, as: UTF8.self)) }
            return r
        case .twitch:
            let user = try await get("https://api.twitch.tv/helix/users", token)
            guard let id = StreamLoginAPI.parseTwitch(user, field: "id") else { throw LoginError(String(decoding: user, as: UTF8.self)) }
            let k = try await get("https://api.twitch.tv/helix/streams/key?broadcaster_id=\(id)", token)
            guard let key = StreamLoginAPI.parseTwitch(k, field: "stream_key") else { throw LoginError(String(decoding: k, as: UTF8.self)) }
            return (StreamService.all.first { $0.login == .twitch }!.server, key)
        }
    }

    private func request(_ url: String, _ token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if login == .twitch { r.setValue(clientID, forHTTPHeaderField: "Client-Id") }
        return r
    }

    private func get(_ url: String, _ token: String) async throws -> Data { try await send(request(url, token)) }

    private func post(_ url: URL, _ body: Data) async throws -> Data {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        return try await send(r)
    }

    private func send(_ r: URLRequest) async throws -> Data { try await URLSession.shared.data(for: r).0 }
}

private struct LoginError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = String(s.prefix(300)) }
}
#endif
