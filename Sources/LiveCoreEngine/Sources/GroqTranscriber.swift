#if os(macOS)
import Foundation
import LiveCoreCore

/// Groq Whisper transcription (0.57.0). Groq has no realtime socket, so Program sound is cut into
/// pieces at pauses (`GroqSegmenter`, at most `groqMaxChunk` s) and each piece is uploaded as a WAV
/// to Groq's `/audio/transcriptions`. Uploads go one at a time; when the service is slow or rate
/// limited the oldest waiting pieces are dropped so captions stay close to live.
final class GroqTranscriber {
    enum Status: Equatable { case connecting, live, error(String) }

    /// The newest finished piece of text (for the caption).
    var onText: ((String) -> Void)?
    var onStatus: ((Status) -> Void)?

    private let apiKey: String
    private let languageCode: String?
    private let advanced: TranscriptionAdvanced
    private let sendRate: Int
    private let factor: Int
    private let lock = UnfairLock()
    private var segmenter: GroqSegmenter
    private let queue = DispatchQueue(label: "livecore.groq", qos: .userInitiated)
    private var waiting: [[Float]] = []
    private var busy = false
    private var running = false
    private var failures = 0
    private var pausedUntil = Date.distantPast
    private var reportedLive = false

    init(apiKey: String, languageCode: String?, mixRate: Int, advanced: TranscriptionAdvanced) {
        self.apiKey = apiKey; self.languageCode = languageCode; self.advanced = advanced
        // 16 kHz when the mix rate divides evenly (what Whisper uses anyway), else the mix rate.
        factor = mixRate % 16_000 == 0 ? max(1, mixRate / 16_000) : 1
        sendRate = mixRate / factor
        segmenter = GroqSegmenter(sampleRate: sendRate, maxSecs: min(max(advanced.groqMaxChunk, 3), 30))
    }

    func start() {
        queue.async { [self] in
            running = true; failures = 0; reportedLive = false
            onStatus?(.connecting)
        }
    }

    func stop() {
        let rest: [Float]? = lock.withLock { segmenter.flush() }
        queue.async { [self] in
            if let rest, running { waiting.append(rest); pump() }
            running = false
        }
    }

    /// Program sound (audio thread): downmixed and cut here, uploads happen on `queue`.
    func append(left: [Float], right: [Float]) {
        let n = min(left.count, right.count) / factor
        guard n > 0 else { return }
        var mono = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var acc: Float = 0
            for k in 0..<factor { acc += left[i * factor + k] + right[i * factor + k] }
            mono[i] = acc / Float(2 * factor)
        }
        let pieces = lock.withLock { segmenter.append(mono) }
        guard !pieces.isEmpty else { return }
        queue.async { [self] in
            guard running else { return }
            waiting += pieces
            // Never fall more than 3 pieces behind live.
            if waiting.count > 3 { waiting.removeFirst(waiting.count - 3) }
            pump()
        }
    }

    // MARK: Uploads (on `queue`)

    private func pump() {
        guard !busy, !waiting.isEmpty else { return }
        let wait = pausedUntil.timeIntervalSinceNow
        if wait > 0 {
            busy = true
            queue.asyncAfter(deadline: .now() + wait) { [self] in busy = false; pump() }
            return
        }
        let piece = waiting.removeFirst()
        busy = true
        upload(piece)
    }

    private func upload(_ samples: [Float]) {
        let pcm = samples.map { Int16(min(max($0, -1), 1) * 32767) }
        let boundary = "LiveCore-\(UUID().uuidString)"
        var req = URLRequest(url: GroqTranscription.url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let fields = GroqTranscription.fields(model: advanced.groqModel, languageCode: languageCode,
                                              vocabulary: advanced.cleanVocabulary)
        req.httpBody = GroqTranscription.multipart(boundary: boundary, fields: fields,
                                                   wav: GroqTranscription.wav(pcm: pcm, sampleRate: sendRate))
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                self.busy = false
                self.finished(data: data ?? Data(), response: response as? HTTPURLResponse, error: error)
                if self.running { self.pump() }
            }
        }.resume()
    }

    private func finished(data: Data, response: HTTPURLResponse?, error: Error?) {
        if let error {
            return failed("Cannot reach Groq: \(error.localizedDescription)")
        }
        let code = response?.statusCode ?? 0
        guard code == 200, let text = GroqTranscription.parseText(data) else {
            let detail = GroqTranscription.errorText(data)
            Log.devices.error("groq HTTP \(code): \(detail, privacy: .public)")
            if code == 401 || code == 403 {
                running = false; waiting.removeAll()
                onStatus?(.error("Groq refused the API key (HTTP \(code)): \(detail). Check the key in the Realtime Transcription settings."))
                return
            }
            if code == 429 {
                let after = response?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 5
                pausedUntil = Date().addingTimeInterval(min(max(after, 1), 60))
                return failed("Groq rate limit reached (\(detail)). Waiting \(Int(after)) s…")
            }
            return failed("Groq HTTP \(code): \(detail)")
        }
        failures = 0
        if !reportedLive { reportedLive = true; onStatus?(.live) }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !GroqTranscription.isHallucination(t) else { return }
        onText?(t)
    }

    private func failed(_ why: String) {
        failures += 1
        reportedLive = false
        Log.devices.error("\(why, privacy: .public) (failure \(self.failures))")
        if failures >= 2 { onStatus?(.error(why)) }
        if pausedUntil < Date() { pausedUntil = Date().addingTimeInterval(min(pow(2, Double(failures - 1)), 15)) }
    }
}
#endif
