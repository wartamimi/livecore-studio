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
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Production") {
                Button(L10n.t("transition.cut")) { model.cut() }
                Button(L10n.t("transition.auto")) { model.auto() }
                Divider()
                Button(model.isStreamingActive ? L10n.t("stream.stop") : L10n.t("stream.start")) { model.toggleStream() }
                Button(model.isRecording ? L10n.t("record.stop") : L10n.t("record.start")) { model.toggleRecord() }
            }
        }

        Window("Program Output", id: "program-output") {
            ProgramOutputWindow()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
#endif
