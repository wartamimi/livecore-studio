#if os(macOS)
import SwiftUI
import AppKit

/// In-app help (0.48.0), in the language the app runs in (English where a beta language has no
/// text yet). Topics follow the current screens; keep them in step with docs/FEATURE_STATUS.md.
struct HelpView: View {
    static let topics = ["start", "inputs", "switching", "overlays", "audio", "record", "stream",
                         "outputs", "color", "show", "remote", "tips"]
    static let icons = ["play.circle", "video", "arrow.left.arrow.right", "square.3.layers.3d", "slider.vertical.3",
                        "record.circle", "dot.radiowaves.left.and.right", "display.2", "camera.filters",
                        "list.number", "iphone.radiowaves.left.and.right", "lightbulb"]
    @State private var selection: String? = "start"
    @State private var query = ""

    private var visible: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Self.topics }
        return Self.topics.filter { title($0).lowercased().contains(q) || body($0).lowercased().contains(q) }
    }

    var body: some View {
        NavigationSplitView {
            List(visible, id: \.self, selection: $selection) { id in
                Label(title(id), systemImage: Self.icons[Self.topics.firstIndex(of: id) ?? 0])
            }
            .searchable(text: $query, placement: .sidebar, prompt: L10n.t("help.search"))
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    let id = selection ?? "start"
                    Text(title(id)).font(.title2.bold())
                    ForEach(Array(body(id).components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        paragraph(line)
                    }
                    Divider().padding(.top, 8)
                    Text(L10n.t("help.footer")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    @ViewBuilder
    private func paragraph(_ line: String) -> some View {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            Spacer().frame(height: 2)
        } else if t.hasPrefix("## ") {
            Text(String(t.dropFirst(3))).font(.headline).padding(.top, 6)
        } else if t.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(String(t.dropFirst(2))).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 13))
        } else {
            Text(t).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func title(_ id: String) -> String { L10n.t("help.\(id).title") }
    private func body(_ id: String) -> String { L10n.t("help.\(id).body") }
}

/// About LiveCore Studio (0.48.0).
struct AboutView: View {
    private var version: String {
        let i = Bundle.main.infoDictionary
        let v = i?["CFBundleShortVersionString"] as? String ?? "–"
        let b = i?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
            Text(L10n.t("app.name")).font(.system(size: 22, weight: .heavy))
            Text(L10n.f("about.version", version)).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(L10n.t("about.text"))
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(L10n.t("about.made_by")).font(.system(size: 13, weight: .semibold))
            Text("© 2026 Munawar Tamimi").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 420)
    }
}

/// Help menu entries (need `openWindow`, so they live in a view).
struct HelpCommands: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        Button(L10n.t("help.menu")) { openWindow(id: "help") }.keyboardShortcut("?", modifiers: [.command])
        Divider()
        Button(L10n.t("diagnostics.menu")) { model.exportDiagnostics() }
        Button(L10n.t("diagnostics.reveal_log")) { model.revealLogFolder() }
    }
}

/// Menu item that opens one of the app's windows (Multiview, Rundown).
struct WindowCommand: View {
    @Environment(\.openWindow) private var openWindow
    let title: String
    let id: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    var body: some View {
        Button(title) { openWindow(id: id) }.keyboardShortcut(key, modifiers: modifiers)
    }
}

struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(L10n.t("about.menu")) { openWindow(id: "about") }
    }
}
#endif
