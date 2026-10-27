#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Dock beside the audio mixer listing the songs of a music input or the clips of a video
/// input: click a row to play it, drag to reorder, right-click to move or remove.
struct PlaylistDockView: View {
    @EnvironmentObject var model: AppModel
    /// "music:<channel id>" or "input:<input id>".
    @AppStorage("dock.playlist.selection") private var selection = ""
    @State private var query = ""

    private enum Source {
        case music(MusicInput)
        case video(InputID, VideoFileSource)
    }

    private struct Choice: Identifiable { let id: String; let title: String; let icon: String }

    private var choices: [Choice] {
        model.musicInputs.map { Choice(id: "music:" + $0.channel.id, title: $0.name, icon: "music.note.list") }
            + model.inputs.filter { $0.kind == .videoFile }.map { Choice(id: "input:" + $0.id.raw, title: "\($0.number) \($0.name)", icon: "film.stack") }
    }

    private var current: Source? {
        let key = choices.contains { $0.id == selection } ? selection : (choices.first?.id ?? "")
        if key.hasPrefix("music:"), let m = model.musicPlayer(String(key.dropFirst(6))) { return .music(m) }
        if key.hasPrefix("input:") {
            let id = InputID(String(key.dropFirst(6)))
            if let v = model.videoFile(id) { return .video(id, v) }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L10n.t("playlist.dock"))
            if choices.isEmpty {
                Text(L10n.t("playlist.dock_empty")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("", selection: Binding(get: { choices.contains { $0.id == selection } ? selection : (choices.first?.id ?? "") },
                                              set: { selection = $0 })) {
                    ForEach(choices) { c in Label(c.title, systemImage: c.icon).tag(c.id) }
                }
                .labelsHidden()
                TextField(L10n.t("playlist.search"), text: $query).textFieldStyle(.roundedBorder).controlSize(.small)
                if let src = current {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in list(src) }
                    controls(src)
                }
            }
        }
        .padding(8)
        .panel()
    }

    private func items(_ s: Source) -> (urls: [URL], index: Int, playing: Bool) {
        switch s {
        case let .music(m): return (m.tracks, m.index, m.isPlaying)
        case let .video(_, v): return (v.urls, v.index, v.isPlaying)
        }
    }

    @ViewBuilder private func list(_ s: Source) -> some View {
        let it = items(s)
        let visible = Array(it.urls.enumerated()).filter {
            query.isEmpty || $0.element.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(query)
        }
        List {
            ForEach(visible, id: \.offset) { i, u in
                HStack(spacing: 6) {
                    Image(systemName: it.playing ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 9)).frame(width: 12)
                        .foregroundStyle(Theme.program)
                        .opacity(i == it.index ? 1 : 0)
                    Text("\(i + 1)").font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textDim).frame(width: 20, alignment: .trailing)
                    Text(u.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 11, weight: i == it.index ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { play(s, i) }
                .help(u.lastPathComponent)
                .contextMenu {
                    Button(L10n.t("playlist.play_this")) { play(s, i) }
                    Button(L10n.t("playlist.move_up")) { move(s, i, i - 1) }.disabled(i == 0)
                    Button(L10n.t("playlist.move_down")) { move(s, i, i + 1) }.disabled(i == it.urls.count - 1)
                    Divider()
                    Button(L10n.t("playlist.remove_item"), role: .destructive) { remove(s, i) }
                        .disabled(isLocked(s) || (it.urls.count == 1 && { if case .video = s { return true }; return false }()))
                }
            }
            // Drag to reorder (not while the list is filtered by a search).
            .onMove(perform: query.isEmpty ? { (from: IndexSet, to: Int) in
                guard let f = from.first else { return }
                move(s, f, to > f ? to - 1 : to)
            } : nil)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 90)
    }

    private func controls(_ s: Source) -> some View {
        HStack(spacing: 8) {
            switch s {
            case let .music(m):
                Button { m.previous() } label: { Image(systemName: "backward.fill") }
                Button { m.togglePlay(); model.objectWillChange.send() } label: { Image(systemName: m.isPlaying ? "pause.fill" : "play.fill") }
                Button { m.next() } label: { Image(systemName: "forward.fill") }
                Toggle(isOn: Binding(get: { m.loopPlaylist }, set: { m.loopPlaylist = $0; model.objectWillChange.send() })) { Image(systemName: "repeat") }
                    .toggleStyle(.button).help(L10n.t("music.loop"))
                Toggle(isOn: Binding(get: { m.shuffle }, set: { m.shuffle = $0; model.objectWillChange.send() })) { Image(systemName: "shuffle") }
                    .toggleStyle(.button).help(L10n.t("music.shuffle"))
                Spacer()
                m3uMenu(s)
                Button { model.addTracks(toMusic: m.channel.id) } label: { Image(systemName: "plus") }.help(L10n.t("music.add_tracks"))
            case let .video(id, v):
                Button { v.previousClip() } label: { Image(systemName: "backward.fill") }
                Button { v.isPlaying ? v.pause() : v.play(); model.objectWillChange.send() } label: { Image(systemName: v.isPlaying ? "pause.fill" : "play.fill") }
                Button { v.nextClip() } label: { Image(systemName: "forward.fill") }
                Toggle(isOn: Binding(get: { v.loop }, set: { v.loop = $0; model.objectWillChange.send() })) { Image(systemName: "repeat") }
                    .toggleStyle(.button).help(L10n.t("playlist.loop"))
                Spacer()
                m3uMenu(s)
                Button { model.addClips(to: id) } label: { Image(systemName: "plus") }.help(L10n.t("playlist.add_clips")).disabled(model.isLocked(id))
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
    }

    private func m3uMenu(_ s: Source) -> some View {
        Menu {
            Button(L10n.t("playlist.import_m3u")) {
                let urls = model.importM3U()
                guard !urls.isEmpty else { return }
                switch s {
                case let .music(m): m.appendTracks(urls)
                case let .video(_, v): v.appendClips(urls)
                }
                model.objectWillChange.send()
            }
            .disabled(isLocked(s))
            Button(L10n.t("playlist.export_m3u")) { model.exportM3U(items(s).urls) }
        } label: { Image(systemName: "list.bullet.rectangle") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L10n.t("playlist.m3u_help"))
    }

    private func isLocked(_ s: Source) -> Bool {
        switch s {
        case let .music(m): return m.channel.locked
        case let .video(id, _): return model.isLocked(id)
        }
    }

    private func play(_ s: Source, _ i: Int) {
        switch s {
        case let .music(m): m.select(i)
        case let .video(_, v): v.selectClip(i); v.play()
        }
        model.objectWillChange.send()
    }

    private func move(_ s: Source, _ from: Int, _ to: Int) {
        switch s {
        case let .music(m): m.moveTrack(from: from, to: to)
        case let .video(_, v): v.moveClip(from: from, to: to)
        }
        model.objectWillChange.send()
    }

    private func remove(_ s: Source, _ i: Int) {
        guard !isLocked(s) else { return }
        switch s {
        case let .music(m): m.removeTrack(at: i)
        case let .video(_, v): v.removeClip(at: i)
        }
        model.objectWillChange.send()
    }
}
#endif
