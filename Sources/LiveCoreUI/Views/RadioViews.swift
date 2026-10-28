#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Search the Radio Browser directory and add a station to the mixer (0.38.0).
struct RadioSearchSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("radio.lastCountry") private var country = "ID"
    @State private var name = ""
    @State private var tag = ""
    @State private var results: [RadioStation] = []
    @State private var searching = false
    @State private var message: String?
    @State private var selection: RadioStation.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 20))
                Text(L10n.t("radio.title")).font(.title2.bold())
                Spacer()
            }
            Text(L10n.t("radio.intro")).font(.system(size: 12)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(L10n.t("radio.name"), text: $name).onSubmit(search)
                TextField(L10n.t("radio.genre"), text: $tag).frame(width: 140).onSubmit(search)
                TextField(L10n.t("radio.country"), text: $country).frame(width: 70).onSubmit(search)
                    .help(L10n.t("radio.country_help"))
                Button(L10n.t("radio.search"), action: search).disabled(searching)
            }
            .textFieldStyle(.roundedBorder)
            ZStack {
                List(results, selection: $selection) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(s.summary).font(.system(size: 10)).foregroundStyle(Theme.textDim).lineLimit(1)
                    }
                    .tag(s.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { add(s) }
                }
                if searching {
                    ProgressView().controlSize(.small)
                } else if let message {
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.textDim).multilineTextAlignment(.center).padding()
                }
            }
            .frame(minHeight: 280)
            Text(L10n.t("radio.copyright")).font(.system(size: 10)).foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(L10n.t("radio.source")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                Spacer()
                Button(L10n.t("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.t("radio.add")) { if let s = results.first(where: { $0.id == selection }) { add(s) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(18)
        .frame(width: 640, height: 560)
        .onAppear { if results.isEmpty { search() } }
    }

    private func search() {
        searching = true
        message = nil
        let q = RadioBrowser.Query(name: name, tag: tag, countryCode: country)
        model.searchRadio(q) { result in
            searching = false
            switch result {
            case let .success(list):
                results = list
                selection = list.first?.id
                message = list.isEmpty ? L10n.t("radio.none") : nil
            case let .failure(err):
                results = []
                message = L10n.f("radio.search_failed", err.localizedDescription)
            }
        }
    }

    private func add(_ s: RadioStation) {
        model.addRadio(s)
        dismiss()
    }
}

/// Station, song and play/stop on a radio channel strip.
struct RadioTransport: View {
    @EnvironmentObject var model: AppModel
    let radio: RadioInput

    var body: some View {
        VStack(spacing: 2) {
            Text(radio.nowPlaying ?? AppModel.radioStateText(radio.state))
                .font(.system(size: 9)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(stateColor).frame(width: 84)
                .help([radio.station.name, radio.station.summary, radio.nowPlaying, AppModel.radioStateText(radio.state)]
                    .compactMap { $0 }.joined(separator: "\n"))
            Button { radio.togglePlay() } label: {
                Image(systemName: radio.isActive ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless).font(.system(size: 10))
            .help(radio.isActive ? L10n.t("radio.stop") : L10n.t("radio.play"))
        }
    }

    private var stateColor: Color {
        switch radio.state {
        case .playing: return Theme.textDim
        case .failed: return Theme.program
        case .stopped: return Theme.textDim
        default: return Theme.warning
        }
    }
}
#endif
