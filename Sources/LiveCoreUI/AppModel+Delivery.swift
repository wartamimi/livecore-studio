#if os(macOS)
import AppKit
import AVFoundation
import LiveCoreCore
import LiveCoreEngine
import LiveCoreServices

/// Client delivery package after the event (0.43.0): the Program, ISO and vertical files of the
/// last recording, YouTube chapters from the rundown, and vertical 9:16 highlight clips around
/// the moments marked with ★ HIGHLIGHT.
extension AppModel {
    public func markHighlight() {
        showMarks.append(ShowMark(kind: .highlight, title: "", date: Date()))
        FileLog.shared.info("highlight marked")
    }

    public var highlightCount: Int { showMarks.filter { $0.kind == .highlight }.count }

    public func makeClientPackage() {
        guard let e = engine else { return }
        guard !isRecording else { report(L10n.t("package.stop_first")); return }
        guard let start = e.recordingStartDate, let program = e.recorder.lastFileURL else {
            report(L10n.t("package.no_recording")); return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.t("package.choose")
        panel.message = L10n.t("package.choose_message")
        panel.directoryURL = program.deletingLastPathComponent()
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let marks = showMarks.filter { $0.date >= start.addingTimeInterval(-5) }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        let folder = parent.appendingPathComponent(L10n.f("package.folder", stamp.string(from: start)), isDirectory: true)
        packageProgress = L10n.t("package.copying")
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = await Self.buildPackage(folder: folder, program: program, start: start, marks: marks) { msg in
                Task { @MainActor in self?.packageProgress = msg }
            }
            await MainActor.run {
                self?.packageProgress = nil
                switch result {
                case let .success(n):
                    self?.report(L10n.f("package.done", "\(n)"))
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                case let .failure(err):
                    self?.report(L10n.f("package.failed", err.localizedDescription))
                }
            }
        }
    }

    /// Recordings from this session: the Program file and the files written next to it since the
    /// recording started ("… - ISO …", "… - Vertical").
    static func sessionFiles(program: URL, start: Date) -> [URL] {
        let dir = program.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let base = program.deletingPathExtension().lastPathComponent
        return files.filter { u in
            guard ["mov", "mp4"].contains(u.pathExtension.lowercased()) else { return false }
            if u == program { return true }
            let created = (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return created >= start.addingTimeInterval(-10) && u.lastPathComponent.hasPrefix(String(base.prefix(10)))
        }
    }

    static func buildPackage(folder: URL, program: URL, start: Date, marks: [ShowMark],
                                         progress: @escaping (String) -> Void) async -> Result<Int, Error> {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let rec = folder.appendingPathComponent("Rekaman", isDirectory: true)
            try fm.createDirectory(at: rec, withIntermediateDirectories: true)
            var count = 0
            let files = sessionFiles(program: program, start: start)
            for f in files {
                progress(L10n.f("package.copying_file", f.lastPathComponent))
                let dest = rec.appendingPathComponent(f.lastPathComponent)
                if fm.fileExists(atPath: dest.path) { continue }
                // Same disk: a hard link is instant and takes no space; otherwise a copy.
                do { try fm.linkItem(at: f, to: dest) } catch { try fm.copyItem(at: f, to: dest) }
                count += 1
            }
            let duration = (try? await AVURLAsset(url: program).load(.duration).seconds) ?? 0
            let chapters = ClientPackage.chapters(marks, recordingStart: start, duration: duration)
            try chapters.write(to: folder.appendingPathComponent("Bab (chapters YouTube).txt"), atomically: true, encoding: .utf8)
            count += 1
            // Highlights: vertical file when there is one, else a centre 9:16 crop of Program.
            let ranges = ClientPackage.highlightRanges(marks, recordingStart: start, duration: duration)
            if !ranges.isEmpty {
                let hl = folder.appendingPathComponent("Highlight 9x16", isDirectory: true)
                try fm.createDirectory(at: hl, withIntermediateDirectories: true)
                let vertical = files.first { $0.lastPathComponent.contains("Vertical") }
                for (i, r) in ranges.enumerated() {
                    progress(L10n.f("package.highlight", "\(i + 1)", "\(ranges.count)"))
                    let out = hl.appendingPathComponent(String(format: "Highlight %02d.mp4", i + 1))
                    try await exportClip(from: vertical ?? program, range: r, cropToVertical: vertical == nil, to: out)
                    count += 1
                }
            }
            let readme = L10n.f("package.readme", ClientPackage.timestamp(duration), "\(files.count)", "\(ranges.count)")
            try readme.write(to: folder.appendingPathComponent("BACA SAYA.txt"), atomically: true, encoding: .utf8)
            return .success(count)
        } catch {
            return .failure(error)
        }
    }

    static func exportClip(from url: URL, range: ClosedRange<Double>, cropToVertical: Bool, to out: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "LiveCore", code: 40, userInfo: [NSLocalizedDescriptionKey: "Cannot export \(url.lastPathComponent)"])
        }
        export.outputURL = out
        export.outputFileType = .mp4
        export.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                       end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
        if cropToVertical, let track = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await track.load(.naturalSize)
            let render = CGSize(width: 720, height: 1280)
            let scale = render.height / size.height
            let comp = AVMutableVideoComposition()
            comp.renderSize = render
            comp.frameDuration = CMTime(value: 1, timescale: 30)
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: -(size.width * scale - render.width) / 2, y: 0)), at: .zero)
            ins.layerInstructions = [layer]
            comp.instructions = [ins]
            export.videoComposition = comp
        }
        await export.export()
        if let err = export.error { throw err }
    }
}
#endif
