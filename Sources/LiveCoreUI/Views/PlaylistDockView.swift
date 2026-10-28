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
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        VStack(spacing: 4) { list(src); progress(src) }
                    }
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
                    Button(L10n.t("playlist.play_next")) { move(s, i, i < it.index ? it.index : it.index + 1) }
                        .disabled(i == it.index || i == it.index + 1)
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
                repeatButton(m.repeatMode) { m.repeatMode = m.repeatMode.cycled }
                PlaylistModeButton(icon: "shuffle", on: m.shuffle, help: L10n.t("music.shuffle")) {
                    m.shuffle.toggle(); model.objectWillChange.send()
                }
                stopAfterButton(m.stopAfterCurrent) { m.stopAfterCurrent.toggle() }
                Spacer()
                m3uMenu(s)
                Button { model.addTracks(toMusic: m.channel.id) } label: { Image(systemName: "plus") }.help(L10n.t("music.add_tracks"))
            case let .video(id, v):
                Button { v.previousClip() } label: { Image(systemName: "backward.fill") }
                Button { playPickedOrToggle(s) } label: { Image(systemName: v.isPlaying && pickedIndex(s) == nil ? "pause.fill" : "play.fill") }
                    .help(L10n.t("playlist.play_help"))
                Button { v.nextClip() } label: { Image(systemName: "forward.fill") }
                repeatButton(v.repeatMode) { v.repeatMode = v.repeatMode.cycled }
                if v.isPlaylist {
                    PlaylistModeButton(icon: "shuffle", on: v.shuffle, help: L10n.t("playlist.shuffle")) {
                        v.shuffle.toggle(); model.objectWillChange.send()
                    }
                }
                stopAfterButton(v.stopAfterCurrent) { v.stopAfterCurrent.toggle() }
                Spacer()
                m3uMenu(s)
                Button { model.addClips(to: id) } label: { Image(systemName: "plus") }.help(L10n.t("playlist.add_clips")).disabled(model.isLocked(id))
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
    }

    /// Repeat: off → all (ON) → one (1) → off.
    private func repeatButton(_ mode: RepeatMode, _ cycle: @escaping () -> Void) -> some View {
        PlaylistModeButton(icon: mode == .one ? "repeat.1" : "repeat", on: mode != .off,
                           help: L10n.t("playlist.repeat_help"),
                           label: mode == .one ? L10n.t("playlist.repeat_one") : nil) {
            cycle(); model.objectWillChange.send()
        }
    }

    private func stopAfterButton(_ on: Bool, _ toggle: @escaping () -> Void) -> some View {
        PlaylistModeButton(icon: "stop.circle", on: on, help: L10n.t("playlist.stop_after_help")) {
            toggle(); model.objectWillChange.send()
        }
    }

    /// Elapsed / progress (click or drag to seek) / remaining time of the item playing now.
    private func progress(_ s: Source) -> some View {
        let (pos, dur): (Double, Double?) = {
            switch s {
            case let .music(m): return (m.position, m.duration)
            case let .video(_, v): return (v.position, v.duration)
            }
        }()
        let d = max(dur ?? 0, 0)
        let f = d > 0 ? min(max(pos / d, 0), 1) : 0
        return HStack(spacing: 6) {
            Text(Self.time(pos)).frame(width: 40, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(Theme.accent).frame(width: max(4, g.size.width * f))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                    guard d > 0, !isLocked(s) else { return }
                    let t = min(max(v.location.x / max(g.size.width, 1), 0), 1) * d
                    switch s {
                    case let .music(m): m.seek(to: t)
                    case let .video(_, vs): vs.seek(to: t)
                    }
                })
            }
            .frame(height: 12)
            Text(d > 0 ? "-" + Self.time(d - pos) : "--:--").frame(width: 44, alignment: .trailing)
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(Theme.textDim)
        .help(L10n.t("playlist.seek_help"))
    }

    private static func time(_ t: Double) -> String {
        let s = Int(max(t, 0).rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
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
    /// Text shown while on (default "ON").
    var label: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                if on { Text(label ?? L10n.t("playlist.mode_on")).font(.system(size: 8, weight: .heavy)) }
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
