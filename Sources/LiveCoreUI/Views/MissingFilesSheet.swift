#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore

/// A project (or template) whose media files were moved or deleted, waiting to open (0.80.0).
public struct MissingFilesRequest: Identifiable {
    public let id = UUID()
    let doc: ProjectDocument
    let url: URL
    let asTemplate: Bool
    let missing: [String]

    init(doc: ProjectDocument, url: URL, asTemplate: Bool) {
        self.doc = doc; self.url = url; self.asTemplate = asTemplate
        missing = doc.missingMedia(projectDirectory: url.deletingLastPathComponent().standardizedFileURL.path) {
            FileManager.default.fileExists(atPath: $0)
        }
    }
}

/// Missing Files (like OBS): lists the files that were not found, lets the operator point each one
/// at its new place or search a folder for all of them, then opens the project.
struct MissingFilesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: MissingFilesRequest
    @State private var moves: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(icon: "exclamationmark.triangle", title: L10n.t("missing.title"),
                         subtitle: L10n.f("missing.subtitle", request.missing.count), color: Theme.warning) { dismiss() }
            List(request.missing, id: \.self) { path in row(path) }
            HStack {
                Button(L10n.t("missing.search")) { searchFolder() }
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(L10n.t("missing.open")) {
                    dismiss()
                    let r = request, m = moves
                    DispatchQueue.main.async { model.finishOpen(r, moves: m) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 420)
    }

    private func row(_ path: String) -> some View {
        let found = moves[path]
        return HStack(spacing: 10) {
            Image(systemName: found == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(found == nil ? Theme.program : Theme.preview)
            VStack(alignment: .leading, spacing: 2) {
                Text((path as NSString).lastPathComponent).font(.system(size: 12, weight: .semibold))
                Text(found ?? path).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(L10n.t("missing.locate")) { locate(path) }.controlSize(.small)
        }
    }

    private func locate(_ path: String) {
        let panel = NSOpenPanel()
        panel.message = (path as NSString).lastPathComponent
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { moves[path] = url.path }
    }

    /// Finds every missing file by name anywhere inside one folder.
    private func searchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let all = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        let files = (all?.allObjects as? [URL] ?? []).map(\.path)
        let open = request.missing.filter { moves[$0] == nil }
        moves.merge(MissingMedia.matches(missing: open, candidates: files)) { a, _ in a }
    }
}
#endif
