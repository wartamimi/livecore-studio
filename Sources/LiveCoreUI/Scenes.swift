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
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.t("project.new")) { model.newProject() }
                Button(L10n.t("project.open")) { model.openProject() }.keyboardShortcut("o", modifiers: [.command])
                Menu(L10n.t("project.open_recent")) {
                    ForEach(model.recentProjects, id: \.self) { u in
                        Button(u.deletingPathExtension().lastPathComponent) { model.openRecent(u) }
                    }
                    if !model.recentProjects.isEmpty { Divider() }
                    Button(L10n.t("project.recent_clear")) { model.clearRecentProjects() }.disabled(model.recentProjects.isEmpty)
                }
                Divider()
                // 0.63.0: Save lives here (the system Save group did not show in every macOS version).
                Button(L10n.t("project.save")) { model.saveProject() }.keyboardShortcut("s", modifiers: [.command])
                Button(L10n.t("project.save_as")) { model.saveProjectAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button(L10n.t("template.save_menu")) { model.saveAsTemplate() }.keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
                Button(L10n.t("template.menu")) { model.showTemplates = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Menu(L10n.t("template.my_menu")) {
                    ForEach(model.userTemplates, id: \.self) { u in
                        Button(u.deletingPathExtension().lastPathComponent) { model.newFromUserTemplate(u) }
                    }
                    if model.userTemplates.isEmpty { Text(L10n.t("template.my_none")) }
                    Divider()
                    Button(L10n.t("template.show_folder")) { model.revealUserTemplates() }
                    Button(L10n.t("template.refresh")) { model.refreshUserTemplates() }
                }
            }
            // Undo / Redo: text fields first, then an open editor, then the input list.
            CommandGroup(replacing: .undoRedo) {
                Button(L10n.t("undo.undo")) { model.performUndo() }.keyboardShortcut("z", modifiers: [.command])
                Button(L10n.t("undo.redo")) { model.performRedo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {}
            CommandMenu("Production") {
                WindowCommand(title: L10n.t("rundown.create_menu"), id: "rundown", key: "r", modifiers: [.command, .shift])
                WindowCommand(title: L10n.t("macro.menu"), id: "macros", key: "k", modifiers: [.command, .option])
                WindowCommand(title: L10n.t("ai.menu"), id: "ai-assistant", key: "j", modifiers: [.command, .option])
                WindowCommand(title: L10n.t("automation.menu"), id: "automation", key: "a", modifiers: [.command, .option])
                WindowCommand(title: L10n.t("prompter.menu"), id: "teleprompter", key: "p", modifiers: [.command, .option])
                Divider()
                Button(L10n.t("transition.cut")) { model.cut() }
                Button(L10n.t("transition.auto")) { model.auto() }
                Divider()
                Button(model.isStreamingActive ? L10n.t("stream.stop") : L10n.t("stream.start")) { model.requestToggleStream() }.disabled(model.streamLocked)
                Button(model.isRecording ? L10n.t("record.stop") : L10n.t("record.start")) { model.requestToggleRecord() }.disabled(model.recordLocked)
                Divider()
                Button(L10n.t("fullscreen.big")) { model.toggleFullscreen() }.keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button(L10n.t("preflight.menu")) { model.showPreflight = true }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button(L10n.t("outputs.menu")) { model.showOutputsPanel = true }.keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button(L10n.f("package.highlight_button", "\(model.highlightCount)")) { model.markHighlight() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                WindowCommand(title: L10n.t("highlights.menu"), id: "highlights", key: "j", modifiers: [.command, .shift])
                Button(L10n.t("package.menu")) { model.makeClientPackage() }
            }
            CommandGroup(replacing: .appInfo) { AboutCommand() }
            // LiveCore Studio ▸ Settings… (⌘,), View ▸ Multiview Mode, Production ▸ Create Rundown (0.55.0).
            CommandGroup(replacing: .appSettings) {
                Button(L10n.t("settings.menu")) { model.openSettingsRequest = true }
                    .keyboardShortcut(",", modifiers: [.command])
                    .disabled(model.isOperatorMode)
            }
            CommandGroup(before: .toolbar) {
                WindowCommand(title: L10n.t("multiview.menu"), id: "multiview", key: "m", modifiers: [.command, .option])
                Divider()
            }
            CommandGroup(replacing: .help) { HelpCommands(model: model) }
        }

        // Help and About (0.48.0).
        Window(L10n.t("help.title"), id: "help") {
            HelpView().background(Backdrop()).tint(Theme.accent).preferredColorScheme(.dark)
        }
        .defaultSize(width: 900, height: 640)
        Window(L10n.t("about.menu"), id: "about") {
            AboutView().background(Backdrop()).tint(Theme.accent).preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)

        Window(L10n.t("ai.title"), id: "ai-assistant") {
            AIAgentWindow(session: model.aiAgent)
                .environmentObject(model)
                .frame(minWidth: 380, idealWidth: 520, minHeight: 420, idealHeight: 640)
                .background(Backdrop()).tint(Theme.accent).preferredColorScheme(.dark)
        }

        Window(L10n.t("macro.title"), id: "macros") {
            MacrosWindow()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 460)
                .background(Backdrop()).tint(Theme.accent).preferredColorScheme(.dark)
        }
        .defaultSize(width: 960, height: 600)

        Window(L10n.t("automation.title"), id: "automation") {
            ShowAutomationWindow()
                .environmentObject(model)
                .frame(minWidth: 560, minHeight: 480)
                .background(Backdrop()).tint(Theme.accent).preferredColorScheme(.dark)
        }
        .defaultSize(width: 640, height: 720)

        Window(L10n.t("prompter.title"), id: "teleprompter") {
            TeleprompterWindow()
                .environmentObject(model)
                .frame(minWidth: 480, minHeight: 320)
        }
        .defaultSize(width: 900, height: 600)

        Window(L10n.t("multiview.title"), id: "multiview") {
            MultiviewView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 400)
                .background(Backdrop()).tint(Theme.accent).preferredColorScheme(.dark)
        }

        Window(L10n.t("viewer.title"), id: "source-viewer") {
            SourceViewerWindow()
                .environmentObject(model)
                .frame(minWidth: 480, minHeight: 300)
                .background(Backdrop()).tint(Theme.accent).preferredColorScheme(.dark)
        }

        // Running transcript of a Realtime Transcription input, selectable and copyable (0.57.0).
        Window(L10n.t("transcript.title"), id: "transcript") {
            TranscriptWindow()
                .environmentObject(model)
                .frame(minWidth: 380, minHeight: 260)
                .background(Backdrop()).tint(Theme.accent).preferredColorScheme(.dark)
        }
        .defaultSize(width: 520, height: 600)

        // Marked moments and the highlight video (0.58.0).
        Window(L10n.t("highlights.title"), id: "highlights") {
            HighlightsWindow()
                .environmentObject(model)
                .frame(minWidth: 560, minHeight: 420)
                .background(Backdrop()).tint(Theme.accent).preferredColorScheme(.dark)
        }
        .defaultSize(width: 640, height: 560)

        Window(L10n.t("rundown.title"), id: "rundown") {
            RundownView()
                .environmentObject(model)
                .background(Backdrop()).tint(Theme.accent).preferredColorScheme(.dark)
        }

        Window("Program Output", id: "program-output") {
            ProgramOutputWindow()
                .environmentObject(model)
                .background(Backdrop()).tint(Theme.accent).preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)

        // Output 1–4 windows (EXTERNAL ⚙ / output buttons in the bottom dock).
        WindowGroup(L10n.t("output.section"), id: "output", for: Int.self) { $index in
            OutputWindowView(index: index ?? 1)
                .environmentObject(model)
                .background(Backdrop()).tint(Theme.accent).preferredColorScheme(.dark)
        }
    }
}
#endif
