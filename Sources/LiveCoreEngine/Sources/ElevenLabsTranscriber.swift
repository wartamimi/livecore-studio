#if os(macOS)
import Foundation
import LiveCoreCore

/// ElevenLabs realtime speech-to-text over a WebSocket (0.50.0). Program sound goes in as mono
/// 16-bit PCM about every 100 ms; the service commits sentences itself (voice activity), and
/// partial and committed text come back as `onText`. Lost connections reconnect with a growing
/// pause; a wrong key or an empty quota stops with a message instead.
final class ElevenLabsTranscriber: NSObject, URLSessionWebSocketDelegate {
    enum Status: Equatable { case connecting, live, error(String) }

    var onText: ((String) -> Void)?
    var onStatus: ((Status) -> Void)?

    private let apiKey: String
    private let languageCode: String?
    private let mixRate: Int
    private let sendRate: Int
    private let factor: Int
    private let queue = DispatchQueue(label: "livecore.elevenlabs", qos: .userInitiated)
    private let lock = UnfairLock()
    private var pending: [Float] = []          // mono, at the mix rate
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var running = false
    private var ready = false
    private var failures = 0
    private var committed = ""
    private var partial = ""

    init?(apiKey: String, languageCode: String?, mixRate: Int) {
        guard let rate = ElevenLabsRealtime.sendRate(forMixRate: mixRate) else { return nil }
        self.apiKey = apiKey; self.languageCode = languageCode; self.mixRate = mixRate
        sendRate = rate
        factor = max(1, mixRate / rate)
        super.init()
    }

    func start() {
        queue.async { [self] in
            running = true
            connect()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            ready = false
            task?.cancel(with: .normalClosure, reason: nil)
            task = nil
            session?.invalidateAndCancel()
            session = nil
        }
    }

    /// Forgets the text shown so far (captions cleared after silence).
    func resetText() { queue.async { [self] in committed = ""; partial = "" } }

    /// Program sound (audio thread): only copied here; sending happens on `queue`.
    func append(left: [Float], right: [Float]) {
        let n = min(left.count, right.count)
        guard n > 0 else { return }
        let send: [Float]? = lock.withLock {
            for i in 0..<n { pending.append((left[i] + right[i]) * 0.5) }
            // ~100 ms per message; whole groups of `factor` samples only.
            let need = mixRate / 10
            guard pending.count >= need else { return nil }
            let take = pending.count - pending.count % factor
            let out = Array(pending[0..<take])
            pending.removeFirst(take)
            // Never queue more than 2 s while the connection is down.
            if pending.count > mixRate * 2 { pending.removeAll() }
            return out
        }
        guard let send else { return }
        queue.async { [self] in
            guard ready, let task else { return }
            let pcm = ElevenLabsRealtime.downmix(left: send, right: send, factor: factor)
            let msg = ElevenLabsRealtime.audioMessage(pcm: pcm, sampleRate: sendRate)
            task.send(.string(msg)) { _ in }
        }
    }

    // MARK: Connection (on `queue`)

    /// Asks for a single-use token with the API key (a plain HTTPS call whose error text can be
    /// shown), then opens the WebSocket with that token (0.50.1).
    private func connect() {
        guard running else { return }
        onStatus?(.connecting)
        var req = URLRequest(url: ElevenLabsRealtime.tokenURL)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard self.running, self.task == nil else { return }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let error {
                    return self.dropped("Cannot reach ElevenLabs: \(error.localizedDescription)")
                }
                let body = data ?? Data()
                guard code == 200, let token = ElevenLabsRealtime.parseToken(body) else {
                    let detail = ElevenLabsRealtime.errorText(body)
                    Log.devices.error("elevenlabs token HTTP \(code): \(detail, privacy: .public)")
                    if code == 401 || code == 403 {
                        self.running = false
                        self.onStatus?(.error("ElevenLabs refused the API key (HTTP \(code)): \(detail). The key needs Speech to Text = Access."))
                        return
                    }
                    return self.dropped("ElevenLabs token HTTP \(code): \(detail)")
                }
                self.open(token: token)
            }
        }.resume()
    }

    private func open(token: String) {
        guard running, let url = ElevenLabsRealtime.url(sampleRate: sendRate, languageCode: languageCode, token: token) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let t = s.webSocketTask(with: req)
        session = s; task = t
        t.resume()
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.task === t else { return }
                switch result {
                case let .success(msg):
                    if case let .string(text) = msg { self.handle(ElevenLabsRealtime.parse(text)) }
                    else if case let .data(d) = msg { self.handle(ElevenLabsRealtime.parse(String(decoding: d, as: UTF8.self))) }
                    if self.task === t { self.receive(t) }
                case let .failure(err):
                    self.dropped("Connection to ElevenLabs lost: \(err.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ e: ElevenLabsRealtime.Event) {
        switch e {
        case .started:
            ready = true
            failures = 0
            onStatus?(.live)
        case let .partial(text):
            partial = text
            publish()
        case let .committed(text):
            partial = ""
            let t = text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { committed = committed.isEmpty ? t : committed + " " + t }
            if committed.count > 600 { committed = String(committed.suffix(400)) }
            publish()
        case let .error(type, message, fatal):
            Log.devices.error("elevenlabs \(type, privacy: .public): \(message, privacy: .public)")
            if fatal {
                running = false
                ready = false
                task?.cancel(with: .normalClosure, reason: nil)
                task = nil
                onStatus?(.error(Self.explain(type, message)))
            } else if ["session_time_limit_exceeded", "transcriber_error", "resource_exhausted", "queue_overflow", "rate_limited"].contains(type) {
                dropped("ElevenLabs: \(message)")
            }
        case .other:
            break
        }
    }

    private func publish() {
        let text = partial.isEmpty ? committed : (committed.isEmpty ? partial : committed + " " + partial)
        onText?(text)
    }

    private func dropped(_ why: String) {
        ready = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        guard running else { return }
        failures += 1
        Log.devices.error("\(why, privacy: .public) (retry \(self.failures))")
        if failures >= 3 { onStatus?(.error(why + " Retrying…")) }
        let delay = min(pow(2, Double(failures - 1)), 15)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.task == nil else { return }
            self.connect()
        }
    }

    private static func explain(_ type: String, _ message: String) -> String {
        switch type {
        case "auth_error": return "ElevenLabs refused the API key. Check the key in the Realtime Transcription settings."
        case "quota_exceeded": return "Your ElevenLabs quota is used up (\(message))."
        case "unaccepted_terms": return "Accept the ElevenLabs terms in your ElevenLabs account first."
        default: return "ElevenLabs: \(message)"
        }
    }

    // A refused handshake (HTTP 401/403) arrives here, not as a message.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { [weak self] in
            guard let self, let ws = self.task, ws === task else { return }
            if let http = task.response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                self.running = false
                self.task = nil
                self.onStatus?(.error("ElevenLabs refused the realtime connection (HTTP \(http.statusCode)). The key needs Speech to Text = Access."))
            } else if error != nil {
                self.dropped("Connection to ElevenLabs failed: \(error?.localizedDescription ?? "")")
            }
        }
    }
}
#endif
