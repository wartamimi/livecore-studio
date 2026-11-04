#if os(macOS)
import AppKit
import Combine
import LiveCoreCore
import LiveCoreEngine
import SwiftUI

/// Entry points the app binary runs before the UI (0.60.0): the VST 3 scanner child process.
public enum LiveCoreLaunch {
    public static func handleChildModes() { PluginScanChild.runIfRequested() }
}

/// Watches one insert chain and the plug-in catalog for the plug-in list (0.60.0).
final class PluginChainModel: ObservableObject {
    let chain: PluginInsertChain
    let host: AudioPluginHost
    @Published private(set) var tick = 0
    private var observers: [NSObjectProtocol] = []

    init(chain: PluginInsertChain, host: AudioPluginHost) {
        self.chain = chain
        self.host = host
        for name in [PluginInsertChain.didChange, PluginCatalog.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.tick += 1
            })
        }
        if !host.catalog.hasScanned && !host.catalog.isScanning { host.catalog.scan() }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    var slots: [PluginSlot] { chain.slots }
}

/// The insert list of a channel or the master bus: add, order, bypass, edit, remove (0.60.0).
struct PluginChainSheet: View {
    @StateObject private var m: PluginChainModel
    let title: String
    /// Shown inside the Audio Properties tab (no Close button, no fixed width).
    let embedded: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var showFailures = false
    @State private var showFolders = false

    init(chain: PluginInsertChain, host: AudioPluginHost, title: String, embedded: Bool = false) {
        _m = StateObject(wrappedValue: PluginChainModel(chain: chain, host: host))
        self.title = title
        self.embedded = embedded
    }

    var body: some View {
        let _ = m.tick
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.t("plugins.title")).font(.headline)
                Text(title).foregroundStyle(Theme.textDim)
                Spacer()
                if m.chain.latencySamples > 0 {
                    Text(L10n.f("plugins.latency", Double(m.chain.latencySamples) / 48.0))
                        .font(.system(size: 10)).foregroundStyle(Theme.warning)
                        .help(L10n.t("plugins.latency_help"))
                }
            }
            if m.host.safeMode {
                Text(L10n.t("plugins.safe_mode")).font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
            if m.slots.isEmpty {
                Text(L10n.t("plugins.empty")).foregroundStyle(Theme.textDim).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(m.slots.enumerated()), id: \.element.id) { i, slot in row(i, slot) }
                }
            }
            HStack {
                addMenu
                Spacer()
                if m.host.catalog.isScanning {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("plugins.scanning")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                } else {
                    Text(L10n.f("plugins.found", m.host.catalog.audioUnits.count, m.host.catalog.vst3.count))
                        .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    if !m.host.catalog.failures.isEmpty {
                        Button(L10n.f("plugins.failed", m.host.catalog.failures.count)) { showFailures.toggle() }
                            .buttonStyle(.link).font(.system(size: 11))
                    }
                    Button(L10n.t("plugins.rescan")) { m.host.catalog.scan(force: true) }.font(.system(size: 11))
                }
            }
            if showFailures {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(m.host.catalog.failures, id: \.self) { f in
                            Text("\(URL(fileURLWithPath: f.path).lastPathComponent): \(f.reason)").font(.system(size: 10))
                                .foregroundStyle(Theme.textDim).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
            Toggle(L10n.t("plugins.au_out_of_process"), isOn: Binding(get: { m.host.auOutOfProcess }, set: { m.host.auOutOfProcess = $0; m.objectWillChange.send() }))
                .toggleStyle(.checkbox).font(.system(size: 11))
                .help(L10n.t("plugins.au_out_of_process_help"))
            folderNote
            if !embedded {
                HStack {
                    Spacer()
                    Button(L10n.t("common.close")) { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(embedded ? 10 : 16)
        .frame(width: embedded ? nil : 560)
    }

    /// Where macOS looks for plug-ins, with buttons that open each folder in Finder.
    private var folderNote: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { showFolders.toggle() } label: {
                Label(L10n.t("plugins.folders"), systemImage: showFolders ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.borderless).font(.system(size: 11))
            if showFolders {
                ForEach(PluginFolders.all, id: \.path) { f in
                    HStack(spacing: 6) {
                        Text(f.kind).font(.system(size: 10, weight: .semibold)).frame(width: 34, alignment: .leading)
                        Text(f.path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(L10n.t("plugins.show_in_finder")) { PluginFolders.reveal(f.path) }
                            .buttonStyle(.link).font(.system(size: 10))
                    }
                }
                Text(L10n.t("plugins.folders_note")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func row(_ i: Int, _ slot: PluginSlot) -> some View {
        let status = slot.statusText
        HStack(spacing: 8) {
            Text("\(i + 1)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textDim).frame(width: 14)
            Toggle("", isOn: Binding(get: { !slot.bypassed.value }, set: { m.chain.setBypassed(slot.id, !$0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help(L10n.t("plugins.bypass_help"))
                .disabled(!slot.isLoaded || slot.fault != .none)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(slot.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    badge(slot.descriptor.format.label)
                    if slot.isLoaded { badge(slot.outOfProcess ? L10n.t("plugins.isolated") : L10n.t("plugins.in_app")) }
                }
                if !status.isEmpty {
                    Text(status).font(.system(size: 10)).foregroundStyle(Theme.program).lineLimit(2)
                } else {
                    PluginLoadText(slot: slot)
                }
            }
            Spacer(minLength: 4)
            if slot.isLoaded && slot.fault == .none {
                Button(L10n.t("plugins.edit")) { PluginEditorWindows.shared.open(slot, title: "\(slot.name) — \(title)") }
            } else {
                Button(L10n.t("plugins.reload")) {
                    m.host.unblock(slot.descriptor)
                    PluginEditorWindows.shared.close(slot)
                    m.host.reload(slot, in: m.chain)
                }
            }
            Button { m.chain.move(slot.id, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
            Button { m.chain.move(slot.id, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(i == m.slots.count - 1)
            Button {
                PluginEditorWindows.shared.close(slot)
                m.host.remove(slot, from: m.chain)
            } label: { Image(systemName: "trash") }
                .help(L10n.t("plugins.remove"))
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(Theme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func badge(_ s: String) -> some View {
        Text(s).font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
            .background(Theme.panelHover).clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var addMenu: some View {
        Menu {
            pluginMenu(L10n.t("plugins.audio_units"), m.host.catalog.audioUnits)
            pluginMenu("VST3", m.host.catalog.vst3)
        } label: {
            Label(L10n.t("plugins.add"), systemImage: "plus")
        }
        .fixedSize()
        .disabled(m.chain.isFull || !m.host.catalog.hasScanned)
    }

    @ViewBuilder private func pluginMenu(_ title: String, _ list: [AudioPluginDescriptor]) -> some View {
        Menu(title) {
            if list.isEmpty { Text(L10n.t("plugins.none_found")) }
            let vendors = Dictionary(grouping: list, by: \.vendor)
            ForEach(vendors.keys.sorted(), id: \.self) { v in
                Menu(v) {
                    ForEach(vendors[v] ?? []) { d in
                        Button(d.name + (m.host.isBlocked(d) ? " ⚠︎" : "")) {
                            m.host.unblock(d)
                            m.host.add(d, to: m.chain)
                        }
                    }
                }
            }
        }
    }
}

/// Vendor and CPU load of one slot. Only this text refreshes every second, so the rest of the
/// plug-in list (and an open Add Plug-in menu) is not redrawn and does not flicker.
struct PluginLoadText: View {
    let slot: PluginSlot
    @State private var load: Float = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("\(slot.descriptor.vendor) · CPU \(Int((load * 100).rounded())) %")
            .font(.system(size: 10)).foregroundStyle(load > 0.7 ? Theme.warning : Theme.textDim)
            .onReceive(timer) { _ in
                let v = slot.takeLoad()
                if abs(v - load) > 0.005 { load = v }
            }
    }
}

/// One window per open plug-in editor: the plug-in's own interface, or generic sliders.
final class PluginEditorWindows: NSObject, NSWindowDelegate {
    static let shared = PluginEditorWindows()
    private var windows: [UUID: (window: NSWindow, slot: PluginSlot)] = [:]

    func open(_ slot: PluginSlot, title: String) {
        if let w = windows[slot.id]?.window { w.makeKeyAndOrderFront(nil); return }
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.delegate = self
        // Above the main window and its sheets, so the editor never opens hidden behind them.
        window.level = .floating
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.center()
        windows[slot.id] = (window, slot)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        var answered = false
        let showGeneric = { [weak self, weak window] in
            guard let self, let window else { return }
            // No editor of its own (or it never answered): generic parameter sliders.
            slot.closeEditor()
            let host = NSHostingView(rootView: GenericPluginEditor(slot: slot))
            host.frame = NSRect(x: 0, y: 0, width: 460, height: 420)
            window.contentView = host
            window.setContentSize(host.frame.size)
            window.styleMask.insert(.resizable)
            window.makeKeyAndOrderFront(nil)
            self.windows[slot.id] = (window, slot)
        }
        slot.openEditor(in: container, resize: { [weak window] size in
            if Thread.isMainThread { window?.setContentSize(size) } else { DispatchQueue.main.async { window?.setContentSize(size) } }
        }, completion: { [weak window] size in
            guard !answered, let window else { return }
            answered = true
            if let size, size.width > 1, size.height > 1, !container.subviews.isEmpty {
                window.setContentSize(size)
                if slot.editorResizable { window.styleMask.insert(.resizable) }
                window.makeKeyAndOrderFront(nil)
            } else {
                showGeneric()
            }
        })
        // Some Audio Units (often out-of-process AUv2) never return their view: fall back after 4 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard !answered else { return }
            answered = true
            showGeneric()
        }
    }

    func close(_ slot: PluginSlot) {
        windows[slot.id]?.window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let entry = windows.first(where: { $0.value.window === w }) else { return }
        entry.value.slot.closeEditor()
        windows.removeValue(forKey: entry.key)
    }

    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let entry = windows.first(where: { $0.value.window === w }),
              entry.value.slot.editorResizable, w.contentView is FlippedView else { return }
        let accepted = entry.value.slot.editorResized(to: w.contentLayoutRect.size)
        if accepted != w.contentLayoutRect.size { w.setContentSize(accepted) }
    }
}

/// Top-left origin, as plug-in editors expect.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Sliders for every writable parameter of a plug-in without its own interface.
struct GenericPluginEditor: View {
    let slot: PluginSlot
    @State private var params: [PluginParameter] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(slot.name).font(.headline)
            Text(L10n.t("plugins.generic")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
            if params.isEmpty {
                Text(L10n.t("plugins.no_params")).foregroundStyle(Theme.textDim)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach($params) { $p in
                        HStack {
                            Text(p.name).font(.system(size: 11)).frame(width: 140, alignment: .leading).lineLimit(1)
                            Slider(value: $p.value, in: 0...1)
                                .onChange(of: p.value) { v in slot.setParameter(p.id, normalized: v) }
                            Text(slot.display(p.id, normalized: p.value) + (p.unit.isEmpty ? "" : " \(p.unit)"))
                                .font(.system(size: 10).monospacedDigit()).frame(width: 90, alignment: .trailing).lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 420, minHeight: 300)
        .onAppear { params = slot.parameters() }
    }
}

/// The standard macOS plug-in folders the scan reads.
enum PluginFolders {
    struct Folder { let kind: String; let path: String }
    static var all: [Folder] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            Folder(kind: "VST3", path: "/Library/Audio/Plug-Ins/VST3"),
            Folder(kind: "VST3", path: home + "/Library/Audio/Plug-Ins/VST3"),
            Folder(kind: "AU", path: "/Library/Audio/Plug-Ins/Components"),
            Folder(kind: "AU", path: home + "/Library/Audio/Plug-Ins/Components"),
        ]
    }
    static func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
#endif
