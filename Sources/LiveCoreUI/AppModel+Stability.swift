#if os(macOS)
import AppKit
import Foundation
import LiveCoreCore
import LiveCoreEngine
import LiveCoreServices
import OSLog

/// Stability tools (0.37.0): autosave with crash recovery, undo of input changes, the on-disk
/// log and "Export Logs & Diagnostics".
extension AppModel {
    // MARK: Stutter log

    /// Writes what makes the show stutter into the log file (Help › Export Logs & Diagnostics):
    /// main-thread stalls and, once a second, dropped render frames by cause.
    func startStutterLog() {
        var lastLogged = 0.0
        watchdog.onStall = { ms in
            let now = HostClock.now()
            guard now - lastLogged > 1 else { return }   // at most one line a second
            lastLogged = now
            FileLog.shared.warning("main thread did not answer for \(ms) ms")
        }
        watchdog.start()
    }

    func logRenderDrops(_ e: ProductionEngine) {
        let now = (late: e.droppedLate.value, busy: e.droppedGPUBusy.value, failed: e.droppedFailed.value)
        let late = now.late &- lastDropCounts.late, busy = now.busy &- lastDropCounts.busy, failed = now.failed &- lastDropCounts.failed
        lastDropCounts = now
        guard late + busy + failed > 0 else { return }
        FileLog.shared.warning(String(format: "render drops +%llu (late tick %llu, GPU busy %llu, failed %llu), %.1f fps, GPU %.1f ms, CPU %.0f%%",
                                      late + busy + failed, late, busy, failed, performance.renderFPS, performance.gpuFrameMs, performance.cpuPercent))
    }

    // MARK: Autosave and crash recovery

    static let autosaveInterval: TimeInterval = 30

    /// Called once after the engine started: offers the autosave of a session that crashed, then
    /// saves the production every 30 seconds while it changes.
    func startAutosave() {
        let store = AutosaveStore(directory: AutosaveStore.defaultDirectory())
        autosave = store
        let recovery = store.beginSession()
        FileLog.shared.info("LiveCore Studio \(Self.appVersion) started on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if let recovery {
            recoveryPending = true
            FileLog.shared.warning("previous session did not end cleanly; autosave from \(recovery.savedAt)")
            // After the main window is up, so the alert has a window to sit over.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.offerRecovery(recovery) }
        }
        let t = Timer(timeInterval: Self.autosaveInterval, repeats: true) { [weak self] _ in self?.autosaveNow() }
        RunLoop.main.add(t, forMode: .common)
        autosaveTimer = t
    }

    /// Writes the current production to the autosave file (skipped when nothing changed).
    func autosaveNow() {
        guard let store = autosave, let data = encodedProject(directory: projectURL?.deletingLastPathComponent()) else { return }
        do { try store.save(data, projectPath: projectURL?.path) } catch {
            FileLog.shared.error("autosave failed: \(error.localizedDescription)")
        }
    }

    /// The production as project JSON (same content as Save).
    func encodedProject(directory: URL?) -> Data? {
        guard let e = engine else { return nil }
        var doc = e.exportProject(projectDirectory: directory)
        doc.outputs = outputRouting
        doc.multiCorder = multiCorder
        storeInputGroups(in: &doc)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(doc)
    }

    func endAutosaveSession() {
        autosaveTimer?.invalidate()
        autosaveNow()
        autosave?.endSession()
        FileLog.shared.info("LiveCore Studio quit normally")
        FileLog.shared.flush()
    }

    private func offerRecovery(_ r: AutosaveStore.Recovery) {
        defer { recoveryPending = false }
        let alert = NSAlert()
        alert.messageText = L10n.t("recovery.title")
        let time = DateFormatter.localizedString(from: r.savedAt, dateStyle: .medium, timeStyle: .medium)
        alert.informativeText = L10n.f("recovery.message", time,
                                       r.projectPath.map { ($0 as NSString).lastPathComponent } ?? L10n.t("recovery.untitled"))
        alert.addButton(withTitle: L10n.t("recovery.restore"))
        alert.addButton(withTitle: L10n.t("recovery.discard"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else {
            autosave?.discard()
            FileLog.shared.info("recovery declined")
            return
        }
        let decoder = JSONDecoder()
        guard let e = engine, let data = autosave?.recoveryData(validate: { (try? decoder.decode(ProjectDocument.self, from: $0)) != nil }),
              let doc = try? decoder.decode(ProjectDocument.self, from: data) else {
            report(L10n.t("recovery.failed"))
            return
        }
        let original = r.projectPath.map { URL(fileURLWithPath: $0) }
        withUndoSuspended {
            let warnings = e.loadProject(doc, projectDirectory: original?.deletingLastPathComponent())
            projectURL = original.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            afterProjectLoad()
            setOutputRouting(doc.sanitized().outputs ?? OutputRouting())
            multiCorder = doc.sanitized().multiCorder ?? MultiCorderConfig()
            applyInputGroups(from: doc)
            if !warnings.isEmpty { report("\(L10n.t("project.warnings")): " + warnings.joined(separator: " · ")) }
        }
        clearUndo()
        FileLog.shared.info("recovered project from autosave of \(r.savedAt)")
        report(L10n.f("recovery.done", DateFormatter.localizedString(from: r.savedAt, dateStyle: .none, timeStyle: .short)))
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    // MARK: Undo of input changes (close, add, rename)

    /// One undoable change to the input list; applying it returns its inverse.
    enum InputUndo {
        case restore(ProductionEngine.RemovedInput)
        case remove(InputID)
        case rename(InputID, String)

        var titleKey: String {
            switch self {
            case .restore: return "undo.close_input"
            case .remove: return "undo.add_input"
            case .rename: return "undo.rename_input"
            }
        }
    }

    static let undoLimit = 50

    func pushUndo(_ step: InputUndo) {
        undoSteps.append(step)
        if undoSteps.count > Self.undoLimit { undoSteps.removeFirst(undoSteps.count - Self.undoLimit) }
        redoSteps.removeAll()
    }

    func clearUndo() {
        undoSteps.removeAll()
        redoSteps.removeAll()
        knownInputs = Set(inputs.map(\.id))
    }

    /// Runs `body` without recording the inputs it adds as undoable (project load, undo itself).
    func withUndoSuspended(_ body: () -> Void) {
        undoSuspended += 1
        body()
        // Inputs are published asynchronously; resume after they arrived.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.undoSuspended -= 1
            self.knownInputs = Set(self.inputs.map(\.id))
        }
    }

    /// From `onInputsChange`: inputs that appeared by an operator action can be undone.
    func noteInputsChanged(_ list: [ProductionEngine.InputInfo]) {
        let ids = Set(list.map(\.id))
        if undoSuspended == 0 {
            for id in list.map(\.id) where !knownInputs.contains(id) { pushUndo(.remove(id)) }
        }
        knownInputs = ids
    }

    /// Closes an input so that ⌘Z can bring it back.
    func removeWithUndo(_ id: InputID) {
        guard let e = engine else { return }
        let snap = e.removalSnapshot(id)
        withUndoSuspended { e.removeInput(id) }
        if let snap { pushUndo(.restore(snap)) }
        FileLog.shared.info("closed input \(snap?.input.name ?? id.raw)")
    }

    func renameWithUndo(_ id: InputID, _ name: String) {
        guard let e = engine, let old = inputs.first(where: { $0.id == id })?.name, old != name else { return }
        e.renameInput(id, to: name)
        pushUndo(.rename(id, old))
    }

    /// Applies a step; returns its inverse, or nil when it could not be applied.
    private func apply(_ step: InputUndo) -> InputUndo? {
        guard let e = engine else { return nil }
        switch step {
        case let .restore(snap):
            var warnings: [String] = []
            withUndoSuspended { warnings = e.restoreInput(snap) }
            warnings.forEach(report)
            return e.source(snap.input.id) == nil ? nil : .remove(snap.input.id)
        case let .remove(id):
            guard e.source(id) != nil, !isLocked(id), let snap = e.removalSnapshot(id) else { return nil }
            withUndoSuspended { e.removeInput(id) }
            return .restore(snap)
        case let .rename(id, name):
            guard let old = e.inputs.first(where: { $0.id == id })?.name else { return nil }
            e.renameInput(id, to: name)
            return .rename(id, old)
        }
    }

    public var canUndoInputs: Bool { !undoSteps.isEmpty }
    public var canRedoInputs: Bool { !redoSteps.isEmpty }

    public func undoInputs() {
        guard let step = undoSteps.popLast() else { NSSound.beep(); return }
        if let inverse = apply(step) { redoSteps.append(inverse) } else { NSSound.beep() }
        objectWillChange.send()
    }

    public func redoInputs() {
        guard let step = redoSteps.popLast() else { NSSound.beep(); return }
        if let inverse = apply(step) { undoSteps.append(inverse) } else { NSSound.beep() }
        objectWillChange.send()
    }

    /// Edit › Undo: a text field being edited first, then an open editor (Layer Designer), then
    /// the input list.
    public func performUndo() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.undoManager?.canUndo == true {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        } else if let ed = editorUndo, ed.canUndo() {
            ed.undo()
        } else {
            undoInputs()
        }
    }

    public func performRedo() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.undoManager?.canRedo == true {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        } else if let ed = editorUndo, ed.canRedo() {
            ed.redo()
        } else {
            redoInputs()
        }
    }

    // MARK: Logs and diagnostics

    public func revealLogFolder() {
        FileLog.shared.flush()
        let dir = FileLog.shared.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// Asks where to save, then writes a zip with the summary, logs, crash reports and project.
    public func exportDiagnostics() {
        let stamp = Self.fileStamp(Date())
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LiveCore-Diagnostics-\(stamp).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let zipURL = panel.url else { return }
        let bundle = makeDiagnostics()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lc-diag-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let dir = try bundle.write(into: tmp, name: "LiveCore-Diagnostics-\(stamp)")
                try? FileManager.default.removeItem(at: zipURL)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", dir.path, zipURL.path]
                try p.run()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([zipURL]) }
            } catch {
                DispatchQueue.main.async { self?.report(L10n.f("diagnostics.failed", error.localizedDescription)) }
            }
        }
    }

    /// The folder recordings and snapshots go to.
    var recordingFolder: URL {
        settings.recording.folderPath.isEmpty ? RecordingEngine.defaultFolder()
            : URL(fileURLWithPath: settings.recording.folderPath, isDirectory: true)
    }

    static func fileStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: d)
    }

    /// Main thread: collects everything the bundle shows. No stream keys: they are only in the
    /// Keychain; known keys are also registered as secrets to scrub.
    func makeDiagnostics() -> DiagnosticsBundle {
        var b = DiagnosticsBundle()
        let pi = ProcessInfo.processInfo
        var mac: [String] = [
            "LiveCore Studio \(Self.appVersion)",
            "macOS \(pi.operatingSystemVersionString)",
            "Model: \(Self.sysctl("hw.model") ?? "?")",
            "CPU: \(Self.sysctl("machdep.cpu.brand_string") ?? "Apple silicon") · \(pi.activeProcessorCount) cores",
            "Memory: \(pi.physicalMemory / 1_073_741_824) GB",
            "Thermal state: \(pi.thermalState.rawValue) (0 nominal … 3 critical)",
            "Low power mode: \(pi.isLowPowerModeEnabled)",
            "App uptime: \(Int(pi.systemUptime - launchUptime)) s",
        ]
        if let free = Self.freeDiskBytes(recordingFolder) { mac.append("Free space in recording folder: \(free / 1_000_000_000) GB") }
        b.sections.append(.init(title: "Mac", lines: mac))
        let p = performance
        b.sections.append(.init(title: "Performance", lines: [
            "Render: \(String(format: "%.1f", p.renderFPS)) fps (target \(settings.output.frameRate)) · GPU \(String(format: "%.1f", p.gpuFrameMs)) ms/frame",
            "CPU (app): \(String(format: "%.0f", p.cpuPercent)) % · Memory: \(Int(p.memoryMB)) MB · Dropped render frames: \(p.droppedRenderFrames)",
        ]))
        b.sections.append(.init(title: "Inputs (\(inputs.count))", lines: inputs.map { "\($0.number). \($0.name) [\($0.kind)] \($0.status)" }))
        b.sections.append(.init(title: "Audio", lines: audioChannels.map {
            "\($0.name) [\($0.id)] fader \(String(format: "%.2f", $0.fader)) muted \($0.muted) program \($0.toProgram)"
        } + ["Master fader \(String(format: "%.2f", masterFader)) · limiter \(limiterEnabled) · sync offset \(Int(syncOffsetMs)) ms"]))
        var outputs = ["Recording: \(recordStats.state)", "ISO files: \(isoStats.count)"]
        for (id, s) in destinationStats.sorted(by: { $0.key < $1.key }) {
            outputs.append("Stream \(id): \(s.state) · \(Int(s.bitrateKbps)) kbit/s · dropped \(s.droppedVideoFrames) · reconnects \(s.reconnects)")
        }
        b.sections.append(.init(title: "Outputs", lines: outputs))
        b.sections.append(.init(title: "Recent errors shown", lines: errors.map(\.message)))

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let s = try? enc.encode(settings) { b.files["settings.json"] = String(decoding: s, as: UTF8.self) }
        if let d = encodedProject(directory: nil) { b.files["project.livecore"] = String(decoding: d, as: UTF8.self) }
        b.files["system-log.txt"] = Self.unifiedLog()
        b.copies = FileLog.shared.files() + Self.recentCrashReports()
        b.secrets = knownSecrets()
        return b
    }

    /// Stream keys and the remote PIN, only to scrub them from the bundle.
    func knownSecrets() -> [String] {
        var accounts = [settings.stream.keychainAccount] + settings.stream.additional.map(\.keychainAccount)
        accounts.append("remote-pin")
        return accounts.compactMap { (try? KeychainStore.load(account: $0)) ?? nil }.filter { $0.count >= 4 }
    }

    /// This launch's unified log lines of LiveCore Studio (last 2 hours).
    static func unifiedLog() -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return "unavailable" }
        let start = store.position(date: Date().addingTimeInterval(-7200))
        let pred = NSPredicate(format: "subsystem == %@", Log.subsystem)
        guard let entries = try? store.getEntries(at: start, matching: pred) else { return "unavailable" }
        var lines: [String] = []
        for case let e as OSLogEntryLog in entries {
            lines.append("\(e.date) [\(e.category)] \(e.composedMessage)")
            if lines.count > 20_000 { lines.removeFirst(5_000) }
        }
        return lines.joined(separator: "\n")
    }

    /// The three newest crash reports of LiveCore Studio in ~/Library/Logs/DiagnosticReports.
    static func recentCrashReports() -> [URL] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("LiveCore") || $0.lastPathComponent.hasPrefix("LiveCoreStudio") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            .prefix(3).map { $0 }
    }

    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func freeDiskBytes(_ url: URL) -> Int64? {
        guard (try? url.checkResourceIsReachable()) == true else { return nil }
        return RecordingEngine.freeBytes(at: url)
    }
}

/// Undo / redo of an editor that is open (Layer Designer), used by Edit › Undo.
public struct EditorUndo {
    public var canUndo: () -> Bool
    public var canRedo: () -> Bool
    public var undo: () -> Void
    public var redo: () -> Void
}
#endif
