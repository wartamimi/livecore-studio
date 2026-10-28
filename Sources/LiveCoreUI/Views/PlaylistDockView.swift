#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Dock beside the audio mixer listing the songs of a music input or the clips of a video
/// input: click a row to select it, double-click (or ▶) to play it, drag to reorder,
/// right-click to move or remove.
struct PlaylistDockView: View {
    @EnvironmentObject var model: AppModel
    /// "music:<channel id>" or "input:<input id>".
    @AppStorage("dock.playlist.selection") private var selection = ""
    @State private var query = ""
    /// Row picked with a single click (highlighted, not played): "<source key>#<index>".
    @State private var picked: String?

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
                .padding(.vertical, 1)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { play(s, i) }
                .onTapGesture { picked = key(s) + "#\(i)" }
                .listRowBackground(RoundedRectangle(cornerRadius: 4)
                    .fill(picked == key(s) + "#\(i)" ? Theme.accent.opacity(0.35) : Color.clear))
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
                Button { playPickedOrToggle(s) } label: { Image(systemName: m.isPlaying && pickedIndex(s) == nil ? "pause.fill" : "play.fill") }
                    .help(L10n.t("playlist.play_help"))
                Button { m.next() } label: { Image(systemName: "forward.fill") }
                PlaylistModeButton(icon: "repeat", on: m.loopPlaylist, help: L10n.t("music.loop")) {
                    m.loopPlaylist.toggle(); model.objectWillChange.send()
                }
                PlaylistModeButton(icon: "shuffle", on: m.shuffle, help: L10n.t("music.shuffle")) {
                    m.shuffle.toggle(); model.objectWillChange.send()
                }
                Spacer()
                m3uMenu(s)
                Button { model.addTracks(toMusic: m.channel.id) } label: { Image(systemName: "plus") }.help(L10n.t("music.add_tracks"))
            case let .video(id, v):
                Button { v.previousClip() } label: { Image(systemName: "backward.fill") }
                Button { playPickedOrToggle(s) } label: { Image(systemName: v.isPlaying && pickedIndex(s) == nil ? "pause.fill" : "play.fill") }
                    .help(L10n.t("playlist.play_help"))
                Button { v.nextClip() } label: { Image(systemName: "forward.fill") }
                PlaylistModeButton(icon: "repeat", on: v.loop, help: L10n.t("playlist.loop")) {
                    v.loop.toggle(); model.objectWillChange.send()
                }
                if v.isPlaylist {
                    PlaylistModeButton(icon: "shuffle", on: v.shuffle, help: L10n.t("playlist.shuffle")) {
                        v.shuffle.toggle(); model.objectWillChange.send()
                    }
                }
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

    private func key(_ s: Source) -> String {
        switch s {
        case let .music(m): return "music:" + m.channel.id
        case let .video(id, _): return "input:" + id.raw
        }
    }

    /// The selected row of this list when it is not the item already playing.
    private func pickedIndex(_ s: Source) -> Int? {
        guard let p = picked, p.hasPrefix(key(s) + "#"), let i = Int(p.dropFirst(key(s).count + 1)) else { return nil }
        let it = items(s)
        return it.urls.indices.contains(i) && i != it.index ? i : nil
    }

    /// ▶ plays the selected row; with nothing new selected it pauses / resumes.
    private func playPickedOrToggle(_ s: Source) {
        if let i = pickedIndex(s) { play(s, i); return }
        switch s {
        case let .music(m): m.togglePlay()
        case let .video(_, v): v.isPlaying ? v.pause() : v.play()
        }
        model.objectWillChange.send()
    }

    private func isLocked(_ s: Source) -> Bool {
        switch s {
        case let .music(m): return m.channel.locked
        case let .video(id, _): return model.isLocked(id)
        }
    }

    private func play(_ s: Source, _ i: Int) {
        picked = nil
        switch s {
        case let .music(m): m.select(i)
        case let .video(_, v): v.selectClip(i); v.play()
        }
        model.objectWillChange.send()
    }

    private func move(_ s: Source, _ from: Int, _ to: Int) {
        if picked == key(s) + "#\(from)" { picked = key(s) + "#\(to)" }
        switch s {
        case let .music(m): m.moveTrack(from: from, to: to)
        case let .video(_, v): v.moveClip(from: from, to: to)
        }
        model.objectWillChange.send()
    }

    private func remove(_ s: Source, _ i: Int) {
        guard !isLocked(s) else { return }
        picked = nil
        switch s {
        case let .music(m): m.removeTrack(at: i)
        case let .video(_, v): v.removeClip(at: i)
        }
        model.objectWillChange.send()
    }
}

/// Repeat / shuffle: an icon button that is clearly lit (accent fill + "ON") while active.
private struct PlaylistModeButton: View {
    let icon: String
    let on: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                if on { Text(L10n.t("playlist.mode_on")).font(.system(size: 8, weight: .heavy)) }
            }
            .foregroundStyle(on ? Color.white : Theme.textDim)
            .padding(.horizontal, 6).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.accent : Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? Theme.accent.opacity(0.9) : Color.white.opacity(0.12), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(help) (\(L10n.t(on ? "playlist.mode_on" : "playlist.mode_off")))")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
#endif
