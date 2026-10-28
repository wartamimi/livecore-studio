#if os(macOS)
import AppKit
import AVFoundation
import Combine
import CoreImage
import ImageIO
import LiveCoreCore
import LiveCoreEngine
import LiveCoreRemote
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
        let warnings = e.loadProject(doc, projectDirectory: nil)
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

    public func openProject(at url: URL) {
        guard let e = engine else { return }
        do {
            let data = try Data(contentsOf: url)
            let doc = try JSONDecoder().decode(ProjectDocument.self, from: data)
            let warnings = e.loadProject(doc, projectDirectory: url.deletingLastPathComponent())
            projectURL = url
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

    func writeProject(to url: URL) {
        guard let e = engine else { return }
        var doc = e.exportProject(projectDirectory: url.deletingLastPathComponent())
        doc.outputs = outputRouting
        doc.multiCorder = multiCorder
        storeInputGroups(in: &doc)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(doc).write(to: url, options: .atomic)
            projectURL = url
        } catch {
            report("Cannot save project: \(error.localizedDescription)")
        }
    }

    func afterProjectLoad() {
        guard let e = engine else { return }
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

    /// Project files are JSON with their own extension (declared dynamically, no Info.plist UTI needed).
    static let projectType: UTType = UTType(filenameExtension: ProjectDocument.fileExtension, conformingTo: .json) ?? .json
}
#endif
