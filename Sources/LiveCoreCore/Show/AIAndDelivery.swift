import Foundation

/// On-device AI per input (0.43.0): background removal without a green screen and auto-framing.
/// Runs on Apple Silicon only (Neural Engine); on Intel Macs it stays off so the frame rate holds.
public struct InputAI: Codable, Equatable, Sendable {
    public var removeBackground: Bool = false
    public var autoFrame: Bool = false
    /// How far auto-framing zooms in: 1.2 (wide) … 2.5 (tight).
    public var zoom: Double = 1.5
    public init(removeBackground: Bool = false, autoFrame: Bool = false, zoom: Double = 1.5) {
        self.removeBackground = removeBackground; self.autoFrame = autoFrame; self.zoom = zoom
    }
    public var isActive: Bool { removeBackground || autoFrame }
}

public enum AutoFrame {
    /// The `1/zoom` sized crop of a `source` frame centred on (cx, cy) in 0…1 (origin top left),
    /// kept inside the frame. Pixels, origin top left.
    public static func rect(source: PixelSize, zoom: Double, cx: Double, cy: Double)
        -> (x: Double, y: Double, width: Double, height: Double) {
        let z = min(max(zoom, 1), 4)
        let W = Double(source.width), H = Double(source.height)
        let w = W / z, h = H / z
        let x = min(max(cx * W - w / 2, 0), W - w)
        let y = min(max(cy * H - h / 2, 0), H - h)
        return (x, y, w, h)
    }

    /// Where to aim for faces given as (centerX, centerY, height) in 0…1, origin top left: the
    /// faces' middle, with the eyes a little above the centre of the shot (headroom).
    public static func target(faces: [(x: Double, y: Double, height: Double)], zoom: Double) -> (x: Double, y: Double)? {
        guard !faces.isEmpty else { return nil }
        let minX = faces.map(\.x).min()!, maxX = faces.map(\.x).max()!
        let cy = faces.map(\.y).reduce(0, +) / Double(faces.count)
        let h = faces.map(\.height).max()!
        return ((minX + maxX) / 2, min(max(cy + h * 0.35, 0), 1))
    }
}

/// A moment marked during the show: a chapter (rundown segment) or a highlight.
public struct ShowMark: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case chapter, highlight }
    public var kind: Kind
    public var title: String
    public var date: Date
    public init(kind: Kind, title: String, date: Date) { self.kind = kind; self.title = title; self.date = date }
}

/// The client delivery package made after the event (0.43.0): recordings, chapters, highlights.
public enum ClientPackage {
    /// YouTube-style chapter list ("0:00 Title" per line) relative to the recording start. YouTube
    /// needs the first chapter at 0:00 and chapters at least 10 s apart; marks before the start or
    /// after `duration` are dropped.
    public static func chapters(_ marks: [ShowMark], recordingStart: Date, duration: Double,
                                firstTitle: String = "Pembukaan") -> String {
        var list: [(Double, String)] = []
        for m in marks where m.kind == .chapter {
            let t = m.date.timeIntervalSince(recordingStart)
            guard t >= 0, t < duration else { continue }
            if let last = list.last, t - last.0 < 10 { list[list.count - 1] = (last.0, m.title); continue }
            list.append((t, m.title))
        }
        if list.first.map({ $0.0 > 0.5 }) ?? true { list.insert((0, firstTitle), at: 0) } else { list[0].0 = 0 }
        return list.map { "\(timestamp($0.0)) \($0.1)" }.joined(separator: "\n") + "\n"
    }

    public static func timestamp(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Highlight clip ranges (seconds in the recording): `before` seconds before each mark and
    /// `after` after it, inside the recording; overlapping clips are merged.
    public static func highlightRanges(_ marks: [ShowMark], recordingStart: Date, duration: Double,
                                       before: Double = 20, after: Double = 10) -> [ClosedRange<Double>] {
        let raw = marks.filter { $0.kind == .highlight }
            .map { $0.date.timeIntervalSince(recordingStart) }
            .filter { $0 >= 0 && $0 <= duration }
            .sorted()
            .map { max(0, $0 - before)...min(duration, $0 + after) }
        var out: [ClosedRange<Double>] = []
        for r in raw {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out.filter { $0.upperBound - $0.lowerBound >= 1 }
    }
}

/// Live subtitles input (0.43.0): speech of the Program sound turned into captions.
public struct SubtitleStyle: Codable, Equatable, Sendable {
    public var locale: String = "id-ID"
    /// Apple's speech recognition on this Mac only; when the language has no on-device model the
    /// operator may allow Apple's servers (internet) instead.
    public var allowServer: Bool = false
    public var fontSize: Double = 44        // at 1080p
    public var maxLines: Int = 2
    public var boxOpacity: Double = 0.6
    /// Bottom margin, fraction of the output height.
    public var bottomMargin: Double = 0.08
    /// Who turns speech into text (0.50.0): Apple speech recognition or ElevenLabs realtime
    /// speech-to-text (internet, the operator's own API key).
    public var provider: SubtitleProvider = .apple
    /// Advanced settings (0.51.0).
    public var advanced = TranscriptionAdvanced()
    public init() {}

    /// A "Realtime Transcription" input: ElevenLabs, language detected automatically.
    public static var elevenLabs: SubtitleStyle {
        var s = SubtitleStyle()
        s.provider = .elevenLabs
        s.locale = "auto"
        return s
    }

    /// ElevenLabs `language_code` for `locale` ("id-ID" → "id"); nil = detect automatically.
    public var languageCode: String? {
        let code = locale.split(separator: "-").first.map(String.init)?.lowercased() ?? ""
        return code.isEmpty || code == "auto" ? nil : code
    }

    // Older projects have no `provider`: every field is optional when decoding.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? locale
        allowServer = try c.decodeIfPresent(Bool.self, forKey: .allowServer) ?? allowServer
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        maxLines = try c.decodeIfPresent(Int.self, forKey: .maxLines) ?? maxLines
        boxOpacity = try c.decodeIfPresent(Double.self, forKey: .boxOpacity) ?? boxOpacity
        bottomMargin = try c.decodeIfPresent(Double.self, forKey: .bottomMargin) ?? bottomMargin
        provider = (try? c.decodeIfPresent(SubtitleProvider.self, forKey: .provider)) ?? .apple
        advanced = (try? c.decodeIfPresent(TranscriptionAdvanced.self, forKey: .advanced)) ?? TranscriptionAdvanced()
    }
}

/// Advanced Realtime Transcription settings (0.51.0). Optional numbers left nil use the
/// service's own default, so nothing changes for operators who never open this section.
public struct TranscriptionAdvanced: Codable, Equatable, Sendable {
    // Display (both models)
    /// Show words while still being recognised; off = only finished sentences.
    public var showPartial = true
    /// Captions disappear after this many seconds of silence (0 = never).
    public var clearAfter: Double = 4
    public var uppercase = false

    // Apple
    public enum TaskHint: Int, Codable, Sendable, CaseIterable { case unspecified = 0, dictation = 1, search = 2, confirmation = 3 }
    public var appleTaskHint: TaskHint = .dictation
    public var applePunctuation = true
    /// Words the recogniser should prefer (names, places, brands), one per line in the UI.
    public var vocabulary: [String] = []

    // ElevenLabs (query parameters of the realtime WebSocket)
    public enum CommitStrategy: String, Codable, Sendable, CaseIterable { case vad, turnPrediction = "turn_prediction" }
    public var commitStrategy: CommitStrategy = .vad
    public var vadThreshold: Double?
    public var vadSilenceSecs: Double?
    public var minSpeechMs: Int?
    public var minSilenceMs: Int?
    /// Removes filler words and false starts.
    public var noVerbatim = false
    /// Fewer false triggers from background noise and speech.
    public var filterBackground = false
    /// Extra languages expected besides the main one (ISO codes).
    public var secondaryLanguages: [String] = []
    /// Send `vocabulary` as keyterms (max 50; ElevenLabs charges 20 % more).
    public var elevenKeyterms = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TranscriptionAdvanced()
        showPartial = (try? c.decodeIfPresent(Bool.self, forKey: .showPartial)) ?? d.showPartial
        clearAfter = (try? c.decodeIfPresent(Double.self, forKey: .clearAfter)) ?? d.clearAfter
        uppercase = (try? c.decodeIfPresent(Bool.self, forKey: .uppercase)) ?? d.uppercase
        appleTaskHint = (try? c.decodeIfPresent(TaskHint.self, forKey: .appleTaskHint)) ?? d.appleTaskHint
        applePunctuation = (try? c.decodeIfPresent(Bool.self, forKey: .applePunctuation)) ?? d.applePunctuation
        vocabulary = (try? c.decodeIfPresent([String].self, forKey: .vocabulary)) ?? []
        commitStrategy = (try? c.decodeIfPresent(CommitStrategy.self, forKey: .commitStrategy)) ?? d.commitStrategy
        vadThreshold = try? c.decodeIfPresent(Double.self, forKey: .vadThreshold)
        vadSilenceSecs = try? c.decodeIfPresent(Double.self, forKey: .vadSilenceSecs)
        minSpeechMs = try? c.decodeIfPresent(Int.self, forKey: .minSpeechMs)
        minSilenceMs = try? c.decodeIfPresent(Int.self, forKey: .minSilenceMs)
        noVerbatim = (try? c.decodeIfPresent(Bool.self, forKey: .noVerbatim)) ?? false
        filterBackground = (try? c.decodeIfPresent(Bool.self, forKey: .filterBackground)) ?? false
        secondaryLanguages = (try? c.decodeIfPresent([String].self, forKey: .secondaryLanguages)) ?? []
        elevenKeyterms = (try? c.decodeIfPresent(Bool.self, forKey: .elevenKeyterms)) ?? false
    }

    /// Cleaned vocabulary: trimmed, no empties or duplicates, at most 50 (ElevenLabs limit).
    public var cleanVocabulary: [String] {
        var seen = Set<String>(), out: [String] = []
        for w in vocabulary {
            let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            out.append(String(t.prefix(50)))
            if out.count == 50 { break }
        }
        return out
    }

    /// Extra WebSocket query items for ElevenLabs.
    public var elevenLabsQuery: [URLQueryItem] {
        var q: [URLQueryItem] = []
        if commitStrategy != .vad { q.append(URLQueryItem(name: "commit_strategy", value: commitStrategy.rawValue)) }
        if let v = vadThreshold { q.append(URLQueryItem(name: "vad_threshold", value: String(format: "%.2f", min(max(v, 0.05), 0.95)))) }
        if let v = vadSilenceSecs { q.append(URLQueryItem(name: "vad_silence_threshold_secs", value: String(format: "%.2f", min(max(v, 0.2), 5)))) }
        if let v = minSpeechMs { q.append(URLQueryItem(name: "min_speech_duration_ms", value: String(min(max(v, 20), 2000)))) }
        if let v = minSilenceMs { q.append(URLQueryItem(name: "min_silence_duration_ms", value: String(min(max(v, 20), 2000)))) }
        if noVerbatim { q.append(URLQueryItem(name: "no_verbatim", value: "true")) }
        if filterBackground { q.append(URLQueryItem(name: "filter_background_audio", value: "true")) }
        for l in secondaryLanguages {
            let code = l.trimmingCharacters(in: .whitespaces).lowercased()
            if !code.isEmpty { q.append(URLQueryItem(name: "secondary_languages", value: code)) }
        }
        if elevenKeyterms { for k in cleanVocabulary { q.append(URLQueryItem(name: "keyterms", value: k)) } }
        return q
    }
}

public enum SubtitleProvider: String, Codable, Sendable, CaseIterable {
    case apple
    case elevenLabs
    // Groq Whisper (0.57.0) was removed in 0.66.0; projects that chose it decode as Apple.
}

/// ElevenLabs realtime speech-to-text protocol (0.50.0): the WebSocket URL, the audio message and
/// the server messages. Pure logic so it is tested on Linux.
public enum ElevenLabsRealtime {
    public static let host = "api.elevenlabs.io"
    public static let keychainAccount = "elevenlabs-api-key"

    /// Formats the service accepts as raw 16-bit PCM.
    public static let sampleRates = [8_000, 16_000, 22_050, 24_000, 44_100, 48_000]

    /// The rate sent for audio mixed at `mixRate`: 16 kHz when it divides evenly (smaller upload),
    /// else the mix rate itself when the service accepts it.
    public static func sendRate(forMixRate mixRate: Int) -> Int? {
        if mixRate % 16_000 == 0 { return 16_000 }
        return sampleRates.contains(mixRate) ? mixRate : nil
    }

    /// Single-use token for one WebSocket session (expires after 15 minutes, consumed on use).
    public static var tokenURL: URL { URL(string: "https://\(host)/v1/single-use-token/realtime_scribe")! }

    /// `token` from the token endpoint's JSON, or the service's error text.
    public static func parseToken(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["token"] as? String
    }

    /// Readable error from an HTTP error body ({"detail": {"message": …}} or {"detail": "…"}).
    public static func errorText(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let d = obj["detail"] as? [String: Any] { return (d["message"] as? String) ?? (d["status"] as? String) ?? "" }
            if let d = obj["detail"] as? String { return d }
            if let list = obj["detail"] as? [[String: Any]] { return list.compactMap { $0["msg"] as? String }.joined(separator: "; ") }
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }

    public static func url(sampleRate: Int, languageCode: String?, token: String? = nil,
                           advanced: TranscriptionAdvanced = TranscriptionAdvanced()) -> URL? {
        var c = URLComponents()
        c.scheme = "wss"; c.host = host; c.path = "/v1/speech-to-text/realtime"
        var q = [URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
                 URLQueryItem(name: "audio_format", value: "pcm_\(sampleRate)"),
                 URLQueryItem(name: "commit_strategy", value: "vad")]
        let extra = advanced.elevenLabsQuery
        if extra.contains(where: { $0.name == "commit_strategy" }) { q.removeAll { $0.name == "commit_strategy" } }
        q += extra
        if let languageCode { q.append(URLQueryItem(name: "language_code", value: languageCode)) }
        if let token { q.append(URLQueryItem(name: "token", value: token)) }
        c.queryItems = q
        return c.url
    }

    /// One `input_audio_chunk` message with little-endian 16-bit PCM.
    public static func audioMessage(pcm: [Int16], sampleRate: Int) -> String {
        let data = pcm.withUnsafeBufferPointer { b -> Data in
            var d = Data(capacity: b.count * 2)
            for v in b { let u = UInt16(bitPattern: v); d.append(UInt8(u & 0xff)); d.append(UInt8(u >> 8)) }
            return d
        }
        return "{\"message_type\":\"input_audio_chunk\",\"audio_base_64\":\"\(data.base64EncodedString())\",\"commit\":false,\"sample_rate\":\(sampleRate)}"
    }

    public enum Event: Equatable, Sendable {
        case started
        case partial(String)
        case committed(String)
        /// `fatal` errors (bad key, no quota, terms not accepted) are not retried.
        case error(type: String, message: String, fatal: Bool)
        case other
    }

    public static func parse(_ text: String) -> Event {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = obj["message_type"] as? String else { return .other }
        switch type {
        case "session_started": return .started
        case "partial_transcript": return .partial(obj["text"] as? String ?? "")
        case "committed_transcript", "committed_transcript_with_timestamps": return .committed(obj["text"] as? String ?? "")
        case "warning": return .other
        default:
            guard let err = obj["error"] as? String ?? obj["message"] as? String else { return .other }
            let fatal = ["auth_error", "quota_exceeded", "unaccepted_terms", "invalid_request"].contains(type)
            return .error(type: type, message: err, fatal: fatal)
        }
    }

    /// Mono 16-bit PCM from stereo float samples, averaging `factor` input samples per output one.
    public static func downmix(left: [Float], right: [Float], factor: Int) -> [Int16] {
        let f = max(1, factor), n = min(left.count, right.count) / f
        var out = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            var acc: Float = 0
            for k in 0..<f { acc += left[i * f + k] + right[i * f + k] }
            let v = min(max(acc / Float(2 * f), -1), 1)
            out[i] = Int16(v * 32767)
        }
        return out
    }
}

/// The running transcript shown in the Transcript window (0.57.0): finished sentences with the
/// time they arrived, for copying or saving as text.
public struct TranscriptLine: Equatable, Sendable {
    public let time: Date
    public let text: String
    public init(time: Date, text: String) { self.time = time; self.text = text }

    public static func join(_ lines: [TranscriptLine], timestamps: Bool, calendar: Calendar = .current) -> String {
        lines.map { l in
            guard timestamps else { return l.text }
            let c = calendar.dateComponents([.hour, .minute, .second], from: l.time)
            return String(format: "[%02d:%02d:%02d] ", c.hour ?? 0, c.minute ?? 0, c.second ?? 0) + l.text
        }.joined(separator: "\n")
    }
}

public enum SubtitleText {
    /// Broadcast-style captions (0.50.2): the text is wrapped from its start into lines of
    /// `maxChars` and cut into pages of `lines`; the last page is shown. Words stay on their line
    /// while the sentence grows, and a full page is replaced by a fresh one instead of scrolling.
    public static func page(_ text: String, maxChars: Int, lines: Int) -> [String] {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var all: [String] = []
        var line = ""
        for w in words {
            let candidate = line.isEmpty ? w : line + " " + w
            if candidate.count <= maxChars || line.isEmpty { line = candidate } else { all.append(line); line = w }
        }
        if !line.isEmpty { all.append(line) }
        guard !all.isEmpty else { return [] }
        let n = max(1, lines)
        let start = (all.count - 1) / n * n
        return Array(all[start...])
    }

    /// The last words of a running transcript that fit `maxChars` per line on `lines` lines,
    /// broken at spaces (a caption shows what is being said now, not the whole speech).
    public static func tail(_ transcript: String, maxChars: Int, lines: Int) -> [String] {
        let words = transcript.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var out: [String] = []
        var line = ""
        for w in words.reversed() {
            let candidate = line.isEmpty ? w : w + " " + line
            if candidate.count <= maxChars || line.isEmpty {
                line = candidate
            } else {
                out.insert(line, at: 0)
                if out.count == lines { return out }
                line = w
            }
        }
        if !line.isEmpty { out.insert(line, at: 0) }
        return Array(out.suffix(lines))
    }
}
