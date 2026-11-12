#if os(macOS)
import AppKit
import AVFoundation
import CoreVideo
import LiveCoreCore
import Speech

/// Live subtitles (0.43.0): Apple speech recognition of the Program sound, drawn as captions at
/// the bottom of a transparent full-size picture to put on an overlay. Recognition runs on this
/// Mac when the language has an on-device model; otherwise only if the operator allowed Apple's
/// servers (`SubtitleStyle.allowServer`).
public final class SubtitleSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .subtitles
    public var name = "Subtitle live (AI)"
    public private(set) var status: SourceStatus = .starting
    public var onStatusChange: ((SourceStatus) -> Void)?
    public private(set) var style: SubtitleStyle
    /// True when recognition runs on this Mac (no internet).
    public private(set) var onDevice = false
    var onRemove: (() -> Void)?
    private let outputSize: PixelSize
    private let format: AVAudioFormat
    private let lock = UnfairLock()
    private var frame: CVPixelBuffer?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var text = ""
    private var lastSpeech = Date.distantPast
    private var running = false
    private var clearTimer: Timer?
    private let renderQueue = DispatchQueue(label: "livecore.subtitles", qos: .userInitiated)
    /// ElevenLabs realtime transcription (0.50.0), when `style.provider == .elevenLabs`.
    private var eleven: ElevenLabsTranscriber?
    private let mixRate: Int
    /// Finished sentences for the Transcript window (0.57.0), newest last.
    private var log: [TranscriptLine] = []
    private var revision = 0
    /// Apple: the current request's text, written to the log when the request ends.
    private var applePending = ""

    init(id: InputID, style: SubtitleStyle, outputSize: PixelSize, sampleRate: Double) {
        self.id = id; self.style = style; self.outputSize = outputSize
        mixRate = Int(sampleRate)
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        if style.provider != .apple { name = "Realtime Transcription" }
        render([])
    }

    public var transcript: String { lock.withLock { text } }

    /// Everything said so far (finished sentences) and a counter that changes with every new line.
    public var transcriptLog: (lines: [TranscriptLine], revision: Int) { lock.withLock { (log, revision) } }

    public func clearTranscriptLog() { lock.withLock { log.removeAll(); revision += 1 } }

    private func commit(_ sentence: String) {
        let t = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lock.withLock {
            if log.last?.text == t { return }
            log.append(TranscriptLine(time: Date(), text: t))
            if log.count > 10_000 { log.removeFirst(log.count - 10_000) }
            revision += 1
        }
    }

    public func update(_ s: SubtitleStyle) {
        func engineSide(_ a: TranscriptionAdvanced) -> TranscriptionAdvanced {
            var a = a; a.clearAfter = 0; a.uppercase = false; return a
        }
        let restart = s.locale != style.locale || s.allowServer != style.allowServer || s.provider != style.provider
            || engineSide(s.advanced) != engineSide(style.advanced)
        style = s
        if restart { stop(); start() } else { redraw() }
    }

    private func setStatus(_ s: SourceStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.status != s else { return }
            self.status = s
            self.onStatusChange?(s)
        }
    }

    /// Restarts with a new ElevenLabs API key (stored in the Keychain by the caller).
    public func reconnect() { stop(); start() }

    public func start() {
        running = true
        startClearTimer()
        if style.provider == .elevenLabs { return startElevenLabs() }
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            guard let self, self.running else { return }
            guard auth == .authorized else {
                self.setStatus(.error("Speech recognition not allowed (System Settings › Privacy › Speech Recognition)."))
                return
            }
            DispatchQueue.main.async { self.begin() }
        }
    }

    private func startClearTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.clearTimer?.invalidate()
            self?.clearTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                // Captions disappear after N s of silence (Advanced, default 4; 0 = never).
                let hold = self.style.advanced.clearAfter
                if hold > 0, Date().timeIntervalSince(self.lock.withLock({ self.lastSpeech })) > hold, !self.transcript.isEmpty {
                    self.lock.withLock { self.text = "" }
                    self.lock.withLock({ self.eleven })?.resetText()
                    self.redraw()
                }
            }
        }
    }

    private func startElevenLabs() {
        onDevice = false
        guard let key = (try? KeychainStore.load(account: ElevenLabsRealtime.keychainAccount)) ?? nil, !key.isEmpty else {
            return setStatus(.error("Enter your ElevenLabs API key in this input's settings."))
        }
        guard let t = ElevenLabsTranscriber(apiKey: key, languageCode: style.languageCode, mixRate: mixRate,
                                            advanced: style.advanced) else {
            return setStatus(.error("ElevenLabs cannot take audio at \(mixRate) Hz. Use 48 kHz or 44.1 kHz in Settings › Audio."))
        }
        t.onText = { [weak self] text in
            guard let self else { return }
            self.lock.withLock { self.text = text; self.lastSpeech = Date() }
            self.redraw()
        }
        t.onCommitted = { [weak self] sentence in self?.commit(sentence) }
        t.onStatus = { [weak self] st in
            switch st {
            case .connecting: self?.setStatus(.starting)
            case .live: self?.setStatus(.live)
            case let .error(msg): self?.setStatus(.error(msg))
            }
        }
        lock.withLock { eleven = t }
        t.start()
    }


    private func begin() {
        guard running else { return }
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: style.locale)) else {
            return setStatus(.error("No speech recognition for \(style.locale) on this Mac."))
        }
        onDevice = r.supportsOnDeviceRecognition
        if !onDevice && !style.allowServer {
            return setStatus(.error("\(style.locale) has no on-device speech model on this Mac. Allow Apple's servers (internet) in the subtitle settings, or install the language in System Settings › Keyboard › Dictation."))
        }
        guard r.isAvailable else { return setStatus(.noSignal("Speech recognition is not available right now.")) }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // "Online" (0.45.0): when Apple's servers are allowed they are used, even if the Mac
        // reports an on-device model. The on-device model for Indonesian is often reported but
        // not downloaded, which failed every request and showed no captions.
        let useServer = style.allowServer
        req.requiresOnDeviceRecognition = !useServer
        switch style.advanced.appleTaskHint {
        case .unspecified: req.taskHint = .unspecified
        case .dictation: req.taskHint = .dictation
        case .search: req.taskHint = .search
        case .confirmation: req.taskHint = .confirmation
        }
        req.contextualStrings = style.advanced.cleanVocabulary
        if #available(macOS 13.0, *) { req.addsPunctuation = style.advanced.applePunctuation }
        lock.withLock { request = req; recognizer = r }
        task = r.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.lock.withLock {
                    self.text = result.bestTranscription.formattedString; self.lastSpeech = Date()
                    self.applePending = self.text
                }
                self.redraw()
            }
            // A finished or failed request starts a new one so captions keep coming.
            if let error = error as NSError? {
                self.handle(error, server: useServer)
            } else if result?.isFinal == true {
                self.failures = 0
                DispatchQueue.main.async { [weak self] in self?.restart() }
            } else if result != nil {
                if self.failures > 0 { self.failures = 0; self.setStatus(.live) }
            }
        }
        setStatus(.live)
    }

    private var failures = 0

    /// "No speech" and the server's one-minute limit are normal and restart at once; other
    /// errors are shown on the input and retried with a growing pause (network down, quota).
    private func handle(_ error: NSError, server: Bool) {
        let normal = [1110, 216, 301, 203].contains(error.code)   // no speech / cancelled / retry
        if !normal { failures += 1 }
        let msg = "subtitles (\(server ? "server" : "on-device")) error \(error.domain) \(error.code): \(error.localizedDescription)"
        if !normal { Log.devices.error("\(msg, privacy: .public)") }
        if !normal && failures >= 3 {
            setStatus(.error(server
                ? "Online speech recognition failed (\(error.code)): \(error.localizedDescription). Check the internet connection and that Siri/Dictation is allowed."
                : "On-device speech recognition failed (\(error.code)). Turn on \"Use Apple's servers\" in the subtitle settings."))
        }
        let delay = normal ? 0.0 : min(Double(failures), 10)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.restart() }
    }

    /// The finished Apple request's text goes to the Transcript window.
    private func commitApple() {
        let t: String = lock.withLock { let t = applePending; applePending = ""; return t }
        commit(t)
    }

    private func restart() {
        commitApple()
        guard running else { return }
        task?.cancel()
        task = nil
        lock.withLock { request = nil }
        begin()
    }

    public func stop() {
        running = false
        let e: ElevenLabsTranscriber? = lock.withLock { let e = eleven; eleven = nil; return e }
        e?.stop()
        commitApple()
        task?.cancel()
        task = nil
        lock.withLock { request?.endAudio(); request = nil }
        DispatchQueue.main.async { [weak self] in self?.clearTimer?.invalidate(); self?.clearTimer = nil }
    }

    /// Program sound (audio thread). Mono for the recogniser; long requests are ended so the
    /// running transcript stays short.
    func append(_ chunk: ProgramAudioPump.Chunk) {
        if let e = lock.withLock({ eleven }) { return e.append(left: chunk.left, right: chunk.right) }
        guard let req = lock.withLock({ request }), chunk.frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.frames)) else { return }
        buf.frameLength = AVAudioFrameCount(chunk.frames)
        let dst = buf.floatChannelData![0]
        for i in 0..<chunk.frames { dst[i] = (chunk.left[i] + chunk.right[i]) * 0.5 }
        req.append(buf)
        if transcript.count > 400 { req.endAudio() }
    }

    private func redraw() {
        let t = style.advanced.uppercase ? transcript.uppercased() : transcript
        let charWidth: Double = style.fontSize * Double(outputSize.height) / 1080.0 * 0.52
        let maxChars = max(12, Int(Double(outputSize.width) * 0.8 / max(charWidth, 1)))
        let lines = SubtitleText.page(t, maxChars: maxChars, lines: max(1, style.maxLines))
        renderQueue.async { [weak self] in self?.render(lines) }
    }

    private func render(_ lines: [String]) {
        let s = style, w = outputSize.width, h = outputSize.height
        let pb = PixelBufferFactory.draw(width: w, height: h) { ctx in
            guard !lines.isEmpty else { return }
            let scale = Double(h) / 1080
            let font = NSFont.systemFont(ofSize: s.fontSize * scale, weight: .semibold)
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: p]
            let str = lines.joined(separator: "\n") as NSString
            let maxW = Double(w) * 0.84
            let size = str.boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin], attributes: attrs).size
            let pad = CGFloat(14 * scale)
            let bw: CGFloat = size.width, bh: CGFloat = size.height
            let bx: CGFloat = (CGFloat(w) - bw) / 2 - pad
            let by: CGFloat = CGFloat(s.bottomMargin) * CGFloat(h) - pad / 2
            let box = CGRect(x: bx, y: by, width: bw + 2 * pad, height: bh + pad)
            ctx.setFillColor(CGColor(gray: 0, alpha: s.boxOpacity))
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 10 * scale, cornerHeight: 10 * scale, transform: nil))
            ctx.fillPath()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            str.draw(with: CGRect(x: box.minX + pad, y: box.minY + pad / 2, width: size.width, height: size.height),
                     options: [.usesLineFragmentOrigin], attributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
        lock.withLock { frame = pb }
    }

    public func currentFrame() -> CVPixelBuffer? { lock.withLock { frame } }
}
#endif
