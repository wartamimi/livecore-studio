#if os(macOS)
import AppKit
import AVFoundation
import Combine
import CoreImage
import ImageIO
import LiveCoreCore
import LiveCoreEngine
import LiveCoreRemote
import LiveCoreServices
import SwiftUI
import UniformTypeIdentifiers

/// Project files (.livecore, JSON).
extension AppModel {
    // MARK: Project files (.livecore, JSON)

    public func newProject() {
        guard let e = engine else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("project.new_confirm")
        alert.addButton(withTitle: L10n.t("common.ok"))
        alert.addButton(withTitle: L10n.t("settings.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var doc = ProjectDocument(settings: settings)
        doc.audio = ProjectAudio()
        var warnings: [String] = []
        withUndoSuspended { warnings = e.loadProject(doc, projectDirectory: nil) }
        clearUndo()
        warnings.forEach(report)
        projectURL = nil
        afterProjectLoad()
        setOutputRouting(OutputRouting())
        multiCorder = MultiCorderConfig()
        applyInputGroups(from: doc)
    }

    public func openProject() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [Self.projectType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    public func openProject(at url: URL) { openProject(at: url, asTemplate: false) }

    /// `asTemplate`: a saved template opens as a new untitled project (Save asks for a name).
    func openProject(at url: URL, asTemplate: Bool) {
        guard let e = engine else { return }
        do {
            let data = try Data(contentsOf: url)
            let doc = try JSONDecoder().decode(ProjectDocument.self, from: data)
            var warnings: [String] = []
            withUndoSuspended { warnings = e.loadProject(doc, projectDirectory: url.deletingLastPathComponent()) }
            clearUndo()
            FileLog.shared.info("opened project \(url.lastPathComponent)")
            projectURL = asTemplate ? nil : url
            if !asTemplate { noteRecent(url) }
            afterProjectLoad()
            setOutputRouting(doc.sanitized().outputs ?? OutputRouting())
            multiCorder = doc.sanitized().multiCorder ?? MultiCorderConfig()
            applyInputGroups(from: doc)
            if !warnings.isEmpty { report("\(L10n.t("project.warnings")): " + warnings.joined(separator: " · ")) }
        } catch {
            report("Cannot open project: \(error.localizedDescription)")
        }
    }

    public func saveProject() {
        if let url = projectURL { writeProject(to: url) } else { saveProjectAs() }
    }

    public func saveProjectAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.nameFieldStringValue = projectURL?.lastPathComponent ?? "Untitled.\(ProjectDocument.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeProject(to: url)
    }

    func writeProject(to url: URL, makeCurrent: Bool = true) {
        guard let e = engine else { return }
        var doc = e.exportProject(projectDirectory: url.deletingLastPathComponent())
        doc.outputs = outputRouting
        doc.multiCorder = multiCorder
        storeInputGroups(in: &doc)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(doc).write(to: url, options: .atomic)
            if makeCurrent { projectURL = url; noteRecent(url) }
        } catch {
            report("Cannot save project: \(error.localizedDescription)")
        }
    }

    func afterProjectLoad() {
        guard let e = engine else { return }
        DispatchQueue.main.async { [weak self] in self?.reloadAllDataSources() }
        settings = e.settings
        transitionKind = settings.transition
        transitionDuration = settings.transitionDuration
        customTransitionID = settings.customTransition
        customTransitions = CustomTransitionLibrary.entries()
        overlays = e.overlays
        stinger = e.stinger
        reloadAudioChannels()
        syncMasterFromEngine()
    }

    // MARK: Open Recent (0.62.0)

    static let recentKey = "project.recent"

    static func loadRecentProjects() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: recentKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    func noteRecent(_ url: URL) {
        var list = recentProjects.filter { $0.standardizedFileURL != url.standardizedFileURL }
        list.insert(url, at: 0)
        recentProjects = Array(list.prefix(12))
        UserDefaults.standard.set(recentProjects.map(\.path), forKey: Self.recentKey)
    }

    public func clearRecentProjects() {
        recentProjects = []
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
    }

    public func openRecent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            report(L10n.f("project.recent_missing", url.lastPathComponent))
            recentProjects.removeAll { $0 == url }
            UserDefaults.standard.set(recentProjects.map(\.path), forKey: Self.recentKey)
            return
        }
        openProject(at: url)
    }

    // MARK: My templates (0.62.0): the whole production saved for reuse

    public static var userTemplateFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LiveCore Studio/Templates", isDirectory: true)
    }

    static func listUserTemplates() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: userTemplateFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == ProjectDocument.fileExtension }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public func refreshUserTemplates() { userTemplates = Self.listUserTemplates() }

    /// Saves inputs, layers, audio, outputs and settings as a template under a name.
    public func saveAsTemplate() {
        let alert = NSAlert()
        alert.messageText = L10n.t("template.save_title")
        alert.informativeText = L10n.t("template.save_body")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = projectURL?.deletingPathExtension().lastPathComponent ?? L10n.t("template.default_name")
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t("common.ok"))
        alert.addButton(withTitle: L10n.t("settings.cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let name = field.stringValue.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try? FileManager.default.createDirectory(at: Self.userTemplateFolder, withIntermediateDirectories: true)
        let url = Self.userTemplateFolder.appendingPathComponent(name).appendingPathExtension(ProjectDocument.fileExtension)
        if FileManager.default.fileExists(atPath: url.path) {
            let a = NSAlert()
            a.messageText = L10n.f("template.replace", name)
            a.addButton(withTitle: L10n.t("common.ok"))
            a.addButton(withTitle: L10n.t("settings.cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        writeProject(to: url, makeCurrent: false)
        refreshUserTemplates()
        report(L10n.f("template.saved", name))
    }

    public func newFromUserTemplate(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = L10n.t("project.new_confirm")
        alert.addButton(withTitle: L10n.t("common.ok"))
        alert.addButton(withTitle: L10n.t("settings.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openProject(at: url, asTemplate: true)
    }

    public func deleteUserTemplate(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        refreshUserTemplates()
    }

    public func revealUserTemplates() {
        try? FileManager.default.createDirectory(at: Self.userTemplateFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.userTemplateFolder)
    }

    /// Project files are JSON with their own extension (declared dynamically, no Info.plist UTI needed).
    static let projectType: UTType = UTType(filenameExtension: ProjectDocument.fileExtension, conformingTo: .json) ?? .json
}
#endif
