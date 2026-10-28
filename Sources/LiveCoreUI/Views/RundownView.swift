#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Event rundown window (0.42.0): the running order with GO / NEXT, a countdown per segment and
/// an editor for what each segment puts on air.
struct RundownView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: String?
    @State private var editing = false

    private var segments: [RundownSegment] { model.rundown.segments }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                list
                if editing, let id = selected, let i = segments.firstIndex(where: { $0.id == id }) {
                    Divider()
                    ScrollView { editor(i).padding(12) }.frame(width: 340)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: editing ? 820 : 480, minHeight: 420)
    }

    // MARK: Toolbar and footer

    private var toolbar: some View {
        HStack {
            Text(L10n.t("rundown.title")).font(.headline)
            Spacer()
            Menu(L10n.t("rundown.templates")) {
                Button(L10n.t("rundown.tpl.wedding")) { replace(with: Rundown.template("wedding")) }
                Button(L10n.t("rundown.tpl.seminar")) { replace(with: Rundown.template("seminar")) }
                Button(L10n.t("rundown.tpl.empty")) { replace(with: Rundown()) }
            }.fixedSize()
            Button { model.makeClientPackage() } label: { Label(L10n.t("package.button"), systemImage: "shippingbox") }
                .help(L10n.t("package.help"))
            Button { addSegment() } label: { Label(L10n.t("rundown.add"), systemImage: "plus") }
            Toggle(L10n.t("rundown.edit"), isOn: $editing).toggleStyle(.button)
        }
        .padding(10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { model.previousSegment() } label: { Image(systemName: "backward.fill") }
                .disabled((model.rundownIndex ?? 0) == 0)
            Button { model.nextSegment() } label: {
                Label(model.rundownIndex == nil ? L10n.t("rundown.start") : L10n.t("rundown.next"), systemImage: "forward.fill")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled((model.rundownIndex ?? -1) + 1 >= segments.count)
            if model.rundownIndex != nil {
                Button(L10n.t("rundown.end")) { model.endRundown() }
            }
            Button { model.markHighlight() } label: {
                Label(L10n.f("package.highlight_button", "\(model.highlightCount)"), systemImage: "star.fill")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .help(L10n.t("package.highlight_help"))
            if let p = model.packageProgress { Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            if let i = model.rundownIndex, segments.indices.contains(i) {
                Text(L10n.f("rundown.now", segments[i].title)).font(.callout.bold()).lineLimit(1)
                Text(clock(i)).font(.system(.title3, design: .monospaced)).foregroundStyle(remainingColor(i))
            }
        }
        .padding(10)
    }

    // MARK: List

    private var list: some View {
        List(selection: $selected) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.system(.body, design: .monospaced)).frame(width: 24)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.body.weight(model.rundownIndex == i ? .bold : .regular))
                        Text(summary(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if !s.notes.isEmpty { Text(s.notes).font(.caption).italic().lineLimit(2) }
                    }
                    Spacer()
                    if s.minutes > 0 { Text(L10n.f("rundown.minutes", fmt(s.minutes))).font(.caption).foregroundStyle(.secondary) }
                    Button(L10n.t("rundown.go")) { model.goToSegment(i) }
                        .buttonStyle(.bordered)
                        .tint(model.rundownIndex == i ? .red : nil)
                }
                .padding(.vertical, 3)
                .listRowBackground(model.rundownIndex == i ? Color.red.opacity(0.18) : Color.clear)
                .tag(s.id)
            }
            .onMove { from, to in
                var r = model.rundown
                r.segments.move(fromOffsets: from, toOffset: to)
                model.setRundown(r)
            }
        }
        .overlay {
            if segments.isEmpty { Text(L10n.t("rundown.empty")).foregroundStyle(.secondary).padding() }
        }
    }

    private func summary(_ s: RundownSegment) -> String {
        var parts: [String] = []
        if let i = s.input { parts.append("▶ " + name(i)) }
        if let t = s.titleInput { parts.append("T\(s.overlayIndex): " + name(t)) }
        switch s.music {
        case .play: parts.append("♪ " + (model.musicInputs.first { $0.id == s.musicID }?.name ?? "?"))
        case .stop: parts.append("♪ ■")
        case .keep: break
        }
        if s.autoNext { parts.append(L10n.t("rundown.auto_next_short")) }
        return parts.isEmpty ? L10n.t("rundown.nothing") : parts.joined(separator: "  ·  ")
    }

    private func name(_ id: InputID) -> String { model.inputs.first { $0.id == id }?.name ?? L10n.t("rundown.missing") }

    private func fmt(_ m: Double) -> String { m == m.rounded() ? String(Int(m)) : String(format: "%.1f", m) }

    private func clock(_ i: Int) -> String {
        guard let start = model.rundownStart else { return "" }
        let e = Date().timeIntervalSince(start)
        func mmss(_ t: Double) -> String { let a = Int(abs(t)); return (t < 0 ? "-" : "") + String(format: "%d:%02d", a / 60, a % 60) }
        if let left = Rundown.remaining(segments[i], elapsed: e) { return mmss(left) }
        return mmss(e)
    }

    private func remainingColor(_ i: Int) -> Color {
        guard let start = model.rundownStart,
              let left = Rundown.remaining(segments[i], elapsed: Date().timeIntervalSince(start)) else { return .primary }
        return left < 0 ? .red : left < 60 ? .orange : .primary
    }

    // MARK: Editing

    private func replace(with r: Rundown) {
        if !segments.isEmpty {
            let a = NSAlert()
            a.messageText = L10n.t("rundown.replace_confirm")
            a.addButton(withTitle: L10n.t("common.ok"))
            a.addButton(withTitle: L10n.t("settings.cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        model.endRundown()
        model.setRundown(r)
        selected = r.segments.first?.id
        editing = true
    }

    private func addSegment() {
        var r = model.rundown
        let s = RundownSegment(title: L10n.f("rundown.new_segment", "\(r.segments.count + 1)"))
        r.segments.append(s)
        model.setRundown(r)
        selected = s.id
        editing = true
    }

    private func seg<T>(_ i: Int, _ kp: WritableKeyPath<RundownSegment, T>) -> Binding<T> {
        Binding(get: { model.rundown.segments[i][keyPath: kp] },
                set: { v in var r = model.rundown; guard r.segments.indices.contains(i) else { return }
                    r.segments[i][keyPath: kp] = v; model.setRundown(r) })
    }

    @ViewBuilder
    private func editor(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L10n.t("rundown.segment_title"), text: seg(i, \.title)).font(.headline)
            GroupBox(L10n.t("rundown.program")) {
                VStack(alignment: .leading) {
                    Picker(L10n.t("rundown.input"), selection: seg(i, \.input)) {
                        Text(L10n.t("rundown.keep_shot")).tag(InputID?.none)
                        ForEach(model.inputs) { Text("\($0.number). \($0.name)").tag(InputID?.some($0.id)) }
                    }
                    Picker(L10n.t("rundown.transition"), selection: seg(i, \.transition)) {
                        Text("CUT").tag(RundownSegment.Transition.cut)
                        Text("AUTO").tag(RundownSegment.Transition.auto)
                    }.pickerStyle(.segmented)
                }.padding(4)
            }
            GroupBox(L10n.t("rundown.title_overlay")) {
                VStack(alignment: .leading) {
                    Picker(L10n.t("rundown.title_input"), selection: seg(i, \.titleInput)) {
                        Text(L10n.t("rundown.no_title")).tag(InputID?.none)
                        ForEach(model.inputs) { Text("\($0.number). \($0.name)").tag(InputID?.some($0.id)) }
                    }
                    Stepper(L10n.f("rundown.overlay_channel", "\(model.rundown.segments[i].overlayIndex)"),
                            value: seg(i, \.overlayIndex), in: 1...4)
                }.padding(4)
            }
            GroupBox(L10n.t("rundown.music")) {
                VStack(alignment: .leading) {
                    Picker(L10n.t("rundown.music_action"), selection: seg(i, \.music)) {
                        Text(L10n.t("rundown.music.keep")).tag(RundownSegment.Music.keep)
                        Text(L10n.t("rundown.music.play")).tag(RundownSegment.Music.play)
                        Text(L10n.t("rundown.music.stop")).tag(RundownSegment.Music.stop)
                    }.pickerStyle(.segmented)
                    if model.rundown.segments[i].music == .play {
                        Picker(L10n.t("rundown.music_input"), selection: seg(i, \.musicID)) {
                            Text("—").tag(String?.none)
                            ForEach(model.musicInputs, id: \.id) { Text($0.name).tag(String?.some($0.id)) }
                        }
                        if model.musicInputs.isEmpty {
                            Text(L10n.t("rundown.no_music")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(4)
            }
            GroupBox(L10n.t("rundown.timing")) {
                VStack(alignment: .leading) {
                    HStack {
                        Text(L10n.t("rundown.planned"))
                        TextField("", value: seg(i, \.minutes), format: .number).frame(width: 60)
                        Text(L10n.t("rundown.min"))
                    }
                    Toggle(L10n.t("rundown.auto_next"), isOn: seg(i, \.autoNext))
                        .disabled(model.rundown.segments[i].minutes <= 0)
                }.padding(4)
            }
            Text(L10n.t("rundown.notes")).font(.caption)
            TextEditor(text: seg(i, \.notes)).frame(height: 60).border(Color.gray.opacity(0.3))
            HStack {
                Button(L10n.t("rundown.go_now")) { model.goToSegment(i) }
                Spacer()
                Button(role: .destructive) {
                    var r = model.rundown
                    r.segments.remove(at: i)
                    model.setRundown(r)
                    selected = nil
                } label: { Label(L10n.t("rundown.delete"), systemImage: "trash") }
            }
        }
    }
}
#endif
