#if os(macOS)
import SwiftUI

/// Scene definitions used by the app target (kept in the library so the SPM executable and
/// the Xcode app target share one implementation).
public enum LiveCoreScenes {
    @SceneBuilder
    public static func main(model: AppModel) -> some Scene {
        WindowGroup(L10n.t("app.name")) {
            MainView()
                .environmentObject(model)
                .environmentObject(model.meters)
                .frame(minWidth: 1180, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.t("project.new")) { model.newProject() }
                Button(L10n.t("project.open")) { model.openProject() }.keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(replacing: .saveItem) {
                Button(L10n.t("project.save")) { model.saveProject() }.keyboardShortcut("s", modifiers: [.command])
                Button(L10n.t("project.save_as")) { model.saveProjectAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("Production") {
                Button(L10n.t("transition.cut")) { model.cut() }
                Button(L10n.t("transition.auto")) { model.auto() }
                Divider()
                Button(model.isStreamingActive ? L10n.t("stream.stop") : L10n.t("stream.start")) { model.requestToggleStream() }.disabled(model.streamLocked)
                Button(model.isRecording ? L10n.t("record.stop") : L10n.t("record.start")) { model.requestToggleRecord() }.disabled(model.recordLocked)
                Divider()
                Button(L10n.t("fullscreen.button")) { model.fullscreen.toggle() }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        Window(L10n.t("multiview.title"), id: "multiview") {
            MultiviewView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 400)
                .preferredColorScheme(.dark)
        }

        Window(L10n.t("viewer.title"), id: "source-viewer") {
            SourceViewerWindow()
                .environmentObject(model)
                .frame(minWidth: 480, minHeight: 300)
                .preferredColorScheme(.dark)
        }

        Window("Program Output", id: "program-output") {
            ProgramOutputWindow()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)

        // Output 1–4 windows (EXTERNAL ⚙ / output buttons in the bottom dock).
        WindowGroup(L10n.t("output.section"), id: "output", for: Int.self) { $index in
            OutputWindowView(index: index ?? 1)
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
#endif
