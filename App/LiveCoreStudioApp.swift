#if os(macOS)
import SwiftUI
import LiveCoreUI

@main
struct LiveCoreStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        LiveCoreScenes.main(model: appDelegate.model)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.confirmQuit() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#else
@main
enum LiveCoreStudioUnsupported {
    static func main() {
        print("LiveCore Studio is a macOS application. On this platform only LiveCoreCore and its tests are built.")
    }
}
#endif
