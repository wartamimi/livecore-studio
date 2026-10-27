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
        // Zoom Meeting SDK bridge: present only in builds made with the SDK (Xcode app target).
        if let registrar = NSClassFromString("LCZoomRegistrar") as? NSObject.Type {
            _ = registrar.perform(NSSelectorFromString("register"))
        }
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
