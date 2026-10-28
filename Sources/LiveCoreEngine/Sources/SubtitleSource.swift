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

    init(id: InputID, style: SubtitleStyle, outputSize: PixelSize, sampleRate: Double) {
        self.id = id; self.style = style; self.outputSize = outputSize
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        render([])
    }

    public var transcript: String { lock.withLock { text } }

    public func update(_ s: SubtitleStyle) {
        let restart = s.locale != style.locale || s.allowServer != style.allowServer
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

    public func start() {
        running = true
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            guard let self, self.running else { return }
            guard auth == .authorized else {
                self.setStatus(.error("Speech recognition not allowed (System Settings › Privacy › Speech Recognition)."))
                return
            }
            DispatchQueue.main.async { self.begin() }
        }
        DispatchQueue.main.async { [weak self] in
            self?.clearTimer?.invalidate()
            self?.clearTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                // Captions disappear after 4 s of silence.
                if Date().timeIntervalSince(self.lock.withLock({ self.lastSpeech })) > 4, !self.transcript.isEmpty {
                    self.lock.withLock { self.text = "" }
                    self.redraw()
                }
            }
        }
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
        req.requiresOnDeviceRecognition = onDevice
        if #available(macOS 13.0, *) { req.addsPunctuation = true }
        lock.withLock { request = req; recognizer = r }
        task = r.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.lock.withLock { self.text = result.bestTranscription.formattedString; self.lastSpeech = Date() }
                self.redraw()
            }
            // A finished or failed request starts a new one so captions keep coming.
            if error != nil || result?.isFinal == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + (error == nil ? 0 : 1)) { [weak self] in self?.restart() }
            }
        }
        setStatus(.live)
    }

    private func restart() {
        guard running else { return }
        task?.cancel()
        task = nil
        lock.withLock { request = nil }
        begin()
    }

    public func stop() {
        running = false
        task?.cancel()
        task = nil
        lock.withLock { request?.endAudio(); request = nil }
        DispatchQueue.main.async { [weak self] in self?.clearTimer?.invalidate(); self?.clearTimer = nil }
    }

    /// Program sound (audio thread). Mono for the recogniser; long requests are ended so the
    /// running transcript stays short.
    func append(_ chunk: ProgramAudioPump.Chunk) {
        guard let req = lock.withLock({ request }), chunk.frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.frames)) else { return }
        buf.frameLength = AVAudioFrameCount(chunk.frames)
        let dst = buf.floatChannelData![0]
        for i in 0..<chunk.frames { dst[i] = (chunk.left[i] + chunk.right[i]) * 0.5 }
        req.append(buf)
        if transcript.count > 400 { req.endAudio() }
    }

    private func redraw() {
        let t = transcript
        let maxChars = max(12, Int(Double(outputSize.width) * 0.8 / (style.fontSize * Double(outputSize.height) / 1080 * 0.52)))
        let lines = SubtitleText.tail(t, maxChars: maxChars, lines: max(1, style.maxLines))
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
            let pad = 14 * scale
            let box = CGRect(x: (Double(w) - size.width) / 2 - pad, y: s.bottomMargin * Double(h) - pad / 2,
                             width: size.width + 2 * pad, height: size.height + pad)
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
