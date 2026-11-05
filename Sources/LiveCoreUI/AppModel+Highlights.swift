#if os(macOS)
import AppKit
import Foundation
import UniformTypeIdentifiers
import LiveCoreCore
import LiveCoreEngine
import LiveCoreServices

/// The recording a highlight video is made from, with its marks (0.58.0).
public struct HighlightSession: Equatable {
    public var recording: URL
    public var start: Date
    public var marks: [HighlightMark]
}

extension HighlightSettings {
    static func saved() -> HighlightSettings {
        guard let d = UserDefaults.standard.data(forKey: "highlightSettings"),
              let s = try? JSONDecoder().decode(HighlightSettings.self, from: d) else { return HighlightSettings() }
        return s
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "highlightSettings") }
    }
}

/// Automatic highlights (0.58.0): ★ marks during the show (⇧⌘H, buttons, web controller, MIDI)
/// are saved next to the recording, then turned into one highlight video.
extension AppModel {
    public var highlightCount: Int { showMarks.filter { $0.kind == .highlight }.count }

    /// Marks this moment. While recording, the mark is also written next to the file, so the
    /// highlight video can be made after the app was closed.
    public func markHighlight(title: String = "") {
        let now = Date()
        showMarks.append(ShowMark(kind: .highlight, title: title, date: now))
        FileLog.shared.info("highlight marked")
        guard isRecording, let e = engine, let start = e.recordingStartDate, let file = e.recorder.lastFileURL else { return }
        let mark = HighlightMark(offset: now.timeIntervalSince(start), title: title)
        var side = Self.readSidecar(file) ?? HighlightSidecar(recordingStart: start)
        side.marks.append(mark)
        Self.writeSidecar(side, for: file)
        if highlightSession?.recording == file { highlightSession?.marks = side.marks }
    }

    static func readSidecar(_ recording: URL) -> HighlightSidecar? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: HighlightSidecar.url(for: recording))).flatMap { try? dec.decode(HighlightSidecar.self, from: $0) }
    }

    static func writeSidecar(_ s: HighlightSidecar, for recording: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try enc.encode(s).write(to: HighlightSidecar.url(for: recording), options: .atomic) } catch {
            FileLog.shared.error("highlight marks not saved: \(error.localizedDescription)")
        }
    }

    /// The current / last recording of this session (marks from its file, else from memory).
    public func loadLastRecordingHighlights() {
        guard let e = engine, let file = e.recorder.lastFileURL, let start = e.recordingStartDate else { highlightSession = nil; return }
        let marks = Self.readSidecar(file)?.marks
            ?? HighlightPlan.marks(showMarks, recordingStart: start).filter { $0.offset >= -5 }
        highlightSession = HighlightSession(recording: file, start: start, marks: marks)
    }

    /// Opens another recording and the marks saved next to it.
    public func openHighlightRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.message = L10n.t("highlights.open_message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let side = Self.readSidecar(url) {
            highlightSession = HighlightSession(recording: url, start: side.recordingStart, marks: side.marks)
        } else {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            highlightSession = HighlightSession(recording: url, start: created, marks: [])
            report(L10n.t("highlights.no_marks_file"))
        }
    }

    /// Saves edits (titles, ticks, removed marks) back next to the recording.
    public func saveHighlightSession() {
        guard let s = highlightSession else { return }
        Self.writeSidecar(HighlightSidecar(recordingStart: s.start, marks: s.marks), for: s.recording)
    }

    public var highlightRecordingBusy: Bool {
        guard let s = highlightSession, isRecording else { return false }
        return engine?.recorder.lastFileURL == s.recording
    }

    /// Asks where to save, then builds the highlight video (and the separate clips if wanted).
    public func makeHighlightVideo() {
        guard let session = highlightSession else { return }
        guard !highlightRecordingBusy else { report(L10n.t("highlights.stop_first")); return }
        guard session.marks.contains(where: \.enabled) else { report(L10n.t("highlights.none")); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = session.recording.deletingLastPathComponent()
        panel.nameFieldStringValue = session.recording.deletingPathExtension().lastPathComponent + " - Highlight.mp4"
        guard panel.runModal() == .OK, let out = panel.url else { return }
        let settings = highlightSettings
        highlightProgress = L10n.t("highlights.making")
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let len = try await HighlightReel.build(recording: session.recording, marks: session.marks, settings: settings, to: out) { p in
                    Task { @MainActor in self?.highlightProgress = L10n.f("highlights.progress", "\(Int(p * 100))") }
                }
                var clips = 0
                if settings.separateClips {
                    let folder = out.deletingPathExtension()
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    var one = settings
                    one.fadeEnds = false
                    for (i, m) in session.marks.filter(\.enabled).sorted(by: { $0.offset < $1.offset }).enumerated() {
                        Task { @MainActor in self?.highlightProgress = L10n.f("package.highlight", "\(i + 1)", "\(session.marks.count)") }
                        let file = folder.appendingPathComponent(String(format: "Highlight %02d.mp4", i + 1))
                        if (try? await HighlightReel.build(recording: session.recording, marks: [m], settings: one, to: file)) != nil { clips += 1 }
                    }
                }
                await MainActor.run {
                    self?.highlightProgress = nil
                    self?.report(L10n.f("highlights.done", ClientPackage.timestamp(len), "\(clips)"))
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
            } catch {
                await MainActor.run {
                    self?.highlightProgress = nil
                    self?.report(L10n.f("highlights.failed", error.localizedDescription))
                }
            }
        }
    }
}
#endif
