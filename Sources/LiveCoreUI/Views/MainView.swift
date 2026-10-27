#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        Group {
            if let err = model.startupError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(Theme.warning)
                    Text("LiveCore Studio could not start").font(.title2)
                    Text(err).foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    TopBarView(showSettings: $showSettings)
                    ErrorBanner()
                    HSplitView {
                        InputPanelView()
                            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                        VSplitView {
                            MonitorRow()
                                .frame(minHeight: 300)
                            HStack(alignment: .top, spacing: 6) {
                                AudioMixerView()
                                ControlPanelView(showSettings: $showSettings)
                                    .frame(width: 330)
                            }
                            .frame(minHeight: 230, idealHeight: 280)
                        }
                    }
                }
                .padding(6)
            }
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
        .background(KeyboardShortcuts())
    }
}

/// Invisible buttons that carry the configurable shortcuts.
struct KeyboardShortcuts: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ZStack {
            Button("") { model.cut() }.keyboardShortcut(ShortcutSettings.key(model.shortcuts.cut), modifiers: [])
            Button("") { model.auto() }.keyboardShortcut(ShortcutSettings.key(model.shortcuts.auto), modifiers: [])
            Button("") { model.toggleStream() }.keyboardShortcut(ShortcutSettings.key(model.shortcuts.stream), modifiers: [.command])
            Button("") { model.toggleRecord() }.keyboardShortcut(ShortcutSettings.key(model.shortcuts.record), modifiers: [.command])
            ForEach(1..<10) { n in
                Button("") { model.previewNumber(n) }.keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

struct ErrorBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if !model.errors.isEmpty {
            VStack(spacing: 4) {
                ForEach(model.errors) { e in
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        Text(e.message).font(.system(size: 12)).lineLimit(3)
                        Spacer()
                        Button(L10n.t("common.dismiss")) { model.dismissError(e) }.buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(Theme.warning.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }
}

/// Full-screen Program output for an external display / projector: open the window from
/// the toolbar, drag it to the external screen and press ⌃⌘F for full screen.
struct ProgramOutputWindow: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        PixelBufferView(feed: model.programOutputFeed)
            .background(Color.black)
            .frame(minWidth: 320, minHeight: 180)
            .ignoresSafeArea()
    }
}
#endif
