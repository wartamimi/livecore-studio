#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Add or change an NDI® input: pick a source found on the network (phones with an NDI camera
/// app, OBS / vMix on another computer, NDI HX cameras), or type its name.
struct NDIInputSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Input being edited, nil when adding a new one.
    let editing: InputID?
    @State private var sources: [String] = []
    @State private var selection = ""
    @State private var lowBandwidth = false
    @State private var audio = true
    @State private var finder = NDIFinder()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editing == nil ? L10n.t("ndi.add_title") : L10n.t("ndi.edit_title")).font(.headline)
            if !NDIRuntime.isAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("ndi.no_runtime")).foregroundStyle(Theme.warning)
                    Link(L10n.t("ndi.download"), destination: NDIRuntime.downloadURL)
                }
            } else {
                Form {
                    Section {
                        if sources.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(L10n.t("ndi.searching")).foregroundStyle(Theme.textDim)
                            }
                        }
                        ForEach(sources, id: \.self) { s in row(s) }
                    } header: {
                        Text(L10n.t("ndi.sources"))
                    }
                    Section {
                        TextField(L10n.t("ndi.name"), text: $selection, prompt: Text("MACBOOK (OBS)"))
                        Toggle(L10n.t("ndi.audio"), isOn: $audio)
                        Toggle(L10n.t("ndi.low_bandwidth"), isOn: $lowBandwidth).help(L10n.t("ndi.low_bandwidth_help"))
                        if let id = editing, let src = model.ndiSource(id) {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                let s = src.signal
                                LabeledContent(L10n.t("capturecard.status")) {
                                    Text(src.status.label).foregroundStyle(Theme.textDim).lineLimit(2)
                                }
                                if s.width > 0 {
                                    LabeledContent(L10n.t("capturecard.signal")) {
                                        Text(L10n.f("ndi.signal_value", s.width, s.height, s.fps,
                                                    s.audioChannels > 0 ? "\(s.audioChannels) ch \(s.audioRate / 1000) kHz" : "—",
                                                    s.alpha ? "alpha" : ""))
                                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textDim)
                                    }
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                Text(L10n.t("ndi.note")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("title.add") : L10n.t("settings.apply")) {
                    let c = ProjectNDI(sourceName: selection.trimmingCharacters(in: .whitespaces),
                                       lowBandwidth: lowBandwidth ? true : nil, audio: audio ? nil : false)
                    if let id = editing { model.updateNDI(id, c) } else { model.addNDI(c) }
                    dismiss()
                }
                .disabled(!canAdd)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480, height: 460)
        .onAppear(perform: load)
        .onDisappear { finder.stop() }
    }

    private var trimmed: String { selection.trimmingCharacters(in: .whitespaces) }
    private var canAdd: Bool {
        NDIRuntime.isAvailable && !trimmed.isEmpty && model.ndiInUse(trimmed, except: editing) == nil
    }

    private func row(_ s: String) -> some View {
        let parts = NDISourceName.split(s)
        let used = model.ndiInUse(s, except: editing)
        let own = NDISourceName.isOwnOutput(s)
        return Button { selection = s } label: {
            HStack {
                Image(systemName: selection == s ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                    .foregroundStyle(selection == s ? Theme.accent : Theme.textDim)
                VStack(alignment: .leading, spacing: 1) {
                    Text(parts.name).font(.system(size: 12, weight: .semibold))
                    Text(parts.machine).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                if let used {
                    Text(L10n.f("inputs.in_use", used)).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.warning)
                } else if own {
                    Text(L10n.t("ndi.own_output")).font(.system(size: 10)).foregroundStyle(Theme.warning)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(used != nil)
        .help(own ? L10n.t("ndi.own_output_help") : s)
    }

    private func load() {
        if let id = editing, let src = model.ndiSource(id) {
            selection = src.config.sourceName
            lowBandwidth = src.config.wantsLowBandwidth
            audio = src.config.wantsAudio
        }
        finder.start { list in
            sources = list
            if editing == nil, selection.isEmpty,
               let first = list.first(where: { !NDISourceName.isOwnOutput($0) && model.ndiInUse($0) == nil }) {
                selection = first
            }
        }
    }
}
#endif
