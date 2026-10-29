#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import LiveCoreCore
import LiveCoreEngine

// Tools added in 0.37.0: pre-flight check, one Outputs panel, templates / welcome screen,
// loudness and ducking, title data sources and PTZ camera control.

/// "EXPERIMENTAL" tag for features that still depend on outside software or fragile timing.
struct ExperimentalTag: View {
    var body: some View {
        Text(L10n.t("common.experimental"))
            .font(.system(size: 8, weight: .heavy)).tracking(0.5)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Theme.warning.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help(L10n.t("common.experimental_help"))
    }
}

extension L10n {
    /// Menu text with the experimental marker ("PowerPoint Live… (Experimental)").
    static func experimental(_ key: String) -> String { "\(t(key))  · \(t("common.experimental"))" }
}

// MARK: Pre-flight

struct PreflightSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Shown as a tab inside Settings: no Close button and no Return/Escape shortcuts (Settings has them).
    var embedded = false
    @State private var plan: AppModel.PreflightPlan?
    @State private var items: [PreflightItem] = []
    @State private var running = false
    /// Pre-flight only starts after the operator confirms it (0.45.0): it opens devices and
    /// test-connects to the stream server.
    @State private var confirmRun = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checklist").font(.system(size: 20))
                Text(L10n.t("preflight.title")).font(.title2.bold())
                Spacer()
                if !items.isEmpty && !running { summary }
            }
            Text(L10n.t("preflight.intro")).font(.system(size: 12)).foregroundStyle(Theme.textDim)
            if let p = plan {
                HStack(spacing: 16) {
                    Toggle(L10n.t("preflight.will_stream"), isOn: Binding(get: { p.stream }, set: { plan?.stream = $0 }))
                    Toggle(L10n.t("preflight.will_record"), isOn: Binding(get: { p.record }, set: { plan?.record = $0 }))
                    Stepper(L10n.f("preflight.duration", Int(p.minutes / 60)), value: Binding(get: { p.minutes }, set: { plan?.minutes = $0 }),
                            in: 60...720, step: 60)
                        .disabled(!p.record)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if running {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L10n.t("preflight.running")).font(.system(size: 12))
                        }
                    } else if items.isEmpty {
                        Text(L10n.t("preflight.not_run")).font(.system(size: 12)).foregroundStyle(Theme.textDim)
                    }
                    ForEach(Array(items.sorted { $0.level > $1.level }.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 8) {
                            icon(item.level)
                            Text(AppModel.preflightText(item)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260)
            HStack {
                Text(L10n.t("preflight.privacy")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                Spacer()
                if embedded {
                    Button(items.isEmpty ? L10n.t("preflight.run") : L10n.t("preflight.run_again")) { confirmRun = true }
                        .disabled(running || plan == nil)
                } else {
                    Button(L10n.t("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(items.isEmpty ? L10n.t("preflight.run") : L10n.t("preflight.run_again")) { confirmRun = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || plan == nil)
                }
            }
        }
        .padding(embedded ? 4 : 18)
        .frame(width: embedded ? nil : 620, height: embedded ? nil : 520)
        .onAppear {
            if plan == nil { plan = model.defaultPreflightPlan }
        }
        .alert(L10n.t("preflight.confirm_title"), isPresented: $confirmRun) {
            Button(L10n.t("preflight.run")) { run() }
            Button(L10n.t("settings.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("preflight.confirm_message"))
        }
    }

    private func run() {
        guard let p = plan, !running else { return }
        running = true
        model.runPreflight(p) { result in
            items = result
            running = false
        }
    }

    private var summary: some View {
        let level = Preflight.overall(items)
        let text = level == .ok ? L10n.t("preflight.ready") : level == .warning ? L10n.t("preflight.check_warnings") : L10n.t("preflight.fix_problems")
        return Label(text, systemImage: level == .ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color(level).opacity(0.25))
            .clipShape(Capsule())
    }

    private func icon(_ l: PreflightItem.Level) -> some View {
        Image(systemName: l == .ok ? "checkmark.circle.fill" : l == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
            .foregroundStyle(color(l))
            .frame(width: 16)
    }

    private func color(_ l: PreflightItem.Level) -> Color {
        switch l {
        case .ok: return .green
        case .warning: return Theme.warning
        case .problem: return Theme.program
        }
    }
}

// MARK: Outputs panel

/// Every output in one place with its status: RECORD, ISOCORDER, STREAM, EXTERNAL (Syphon / NDI)
/// and FULLSCREEN. The bottom dock keeps the quick buttons; this panel is the full view.
struct OutputsPanelSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "square.stack.3d.up").font(.system(size: 18))
                Text(L10n.t("outputs.title")).font(.title2.bold())
                Spacer()
                Button(L10n.t("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section(L10n.t("dock.record"), status: recordStatus, on: model.isRecording,
                            action: model.isRecording ? L10n.t("record.stop") : L10n.t("record.start"),
                            disabled: model.recordLocked) { model.requestToggleRecord() } content: { RecordDetails() }
                    section(L10n.t("dock.stream"), status: streamStatus, on: model.isStreamingActive,
                            action: model.isStreamingActive ? L10n.t("stream.stop") : L10n.t("stream.start"),
                            disabled: model.streamLocked) { model.requestToggleStream() } content: { StreamDetails() }
                    section("ISOCORDER", status: isoStatus, on: model.isMultiCorderRunning,
                            action: model.isMultiCorderRunning ? L10n.t("multicorder.stop") : L10n.t("multicorder.start"),
                            disabled: model.recordLocked) { model.requestToggleMultiCorder() } content: { MultiCorderDetails() }
                    section(L10n.t("dock.external"), status: model.externalActive ? L10n.t("outputs.on") : L10n.t("outputs.off"),
                            on: model.externalActive,
                            action: model.externalActive ? L10n.t("outputs.turn_off") : L10n.t("outputs.turn_on"),
                            disabled: false) { model.toggleExternal() } content: { ExternalSettingsView() }
                    section(L10n.t("fullscreen.big"), status: model.isFullscreenActive ? L10n.t("outputs.on") : L10n.t("outputs.off"),
                            on: model.isFullscreenActive,
                            action: model.isFullscreenActive ? L10n.t("outputs.turn_off") : L10n.t("outputs.turn_on"),
                            disabled: false) { model.toggleFullscreen() } content: { FullscreenSettingsView() }
                }
            }
        }
        .padding(16)
        .frame(width: 720, height: 640)
    }

    private func section<C: View>(_ title: String, status: String, on: Bool, action: String, disabled: Bool,
                                  run: @escaping () -> Void, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(on ? Theme.program : Theme.panelRaised).frame(width: 10, height: 10)
                Text(title).font(.system(size: 13, weight: .heavy))
                Text(status).font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1)
                Spacer()
                Button(action, action: run).disabled(disabled)
            }
            content()
        }
        .padding(10)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var recordStatus: String {
        switch model.recordStats.state {
        case .recording:
            var s = "\(formatDuration(model.recordStats.duration)) · \(ByteCountFormatter.string(fromByteCount: model.recordStats.fileBytes, countStyle: .file))"
            if model.recordStats.droppedVideoFrames > 0 { s += " · \(model.recordStats.droppedVideoFrames) drop" }
            return s
        case .finishing: return L10n.t("outputs.finishing")
        case let .failed(msg): return msg
        default: return L10n.t("dock.record_off")
        }
    }

    private var streamStatus: String {
        guard !model.streamTargets.isEmpty else { return L10n.f("dock.stream_ready", model.readyDestinationCount) }
        return model.streamTargets.map { t -> String in
            let s = model.destinationStats[t.id] ?? StreamingEngine.Stats()
            var line = "\(t.name): \(Self.stateText(s.state))"
            if case .live = s.state { line += " \(Int(s.bitrateKbps)) kbps" }
            if s.reconnects > 0 { line += " · ↻\(s.reconnects)" }
            return line
        }.joined(separator: "  ·  ")
    }

    private var isoStatus: String {
        guard model.isMultiCorderRunning else {
            return model.multiCorder.inputs.isEmpty ? L10n.t("multicorder.none") : L10n.f("multicorder.ready", model.multiCorder.inputs.count)
        }
        return L10n.f("outputs.iso_running", model.isoFiles.count)
    }

    static func stateText(_ s: StreamingEngine.State) -> String {
        switch s {
        case .idle: return L10n.t("stream.idle")
        case .connecting: return L10n.t("stream.connecting")
        case .live: return L10n.t("stream.live")
        case let .reconnecting(a, _): return L10n.f("stream.reconnecting", a)
        case .failed: return L10n.t("stream.failed")
        case .stopping: return L10n.t("stream.stopping")
        }
    }
}

// MARK: Templates / welcome

struct TemplatesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("welcome.showAtLaunch") private var showAtLaunch = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("template.title")).font(.title.bold())
            Text(L10n.t("template.intro")).font(.system(size: 12)).foregroundStyle(Theme.textDim)
            HStack(spacing: 12) {
                ForEach(ProjectTemplate.allCases, id: \.self) { t in
                    Button { dismiss(); DispatchQueue.main.async { model.newFromTemplate(t) } } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: icon(t)).font(.system(size: 28))
                            Text(L10n.t("template.\(t.rawValue)")).font(.system(size: 15, weight: .bold))
                            Text(L10n.t("template.\(t.rawValue)_help")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(width: 200, height: 170, alignment: .topLeading)
                        .background(Theme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(L10n.f("template.devices", model.videoDevices.filter(\.isConnected).count, model.audioDevices.filter(\.isConnected).count))
                .font(.system(size: 11)).foregroundStyle(Theme.textDim)
            Divider()
            HStack {
                Toggle(L10n.t("template.show_at_launch"), isOn: $showAtLaunch).toggleStyle(.checkbox).font(.system(size: 11))
                Spacer()
                Button(L10n.t("project.open")) { dismiss(); DispatchQueue.main.async { model.openProject() } }
                Button(L10n.t("template.blank")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 700)
        .onAppear { model.refreshDevices() }
    }

    private func icon(_ t: ProjectTemplate) -> String {
        switch t {
        case .wedding: return "heart.circle"
        case .seminar: return "person.wave.2"
        case .meeting: return "person.3"
        }
    }
}

// MARK: Loudness and ducking (mixer master)

struct LoudnessReadout: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var meters: MeterModel
    @State private var showPanel = false

    var body: some View {
        Button { showPanel.toggle() } label: {
            VStack(spacing: 0) {
                Text("LUFS").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textDim)
                Text(Self.format(meters.loudness.shortTerm)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Self.color(meters.loudness.shortTerm))
                if meters.loudness.duckDB < -0.5 {
                    Text(String(format: "DUCK %.0f", meters.loudness.duckDB)).font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.preview)
                }
            }
            .frame(width: 70)
            .padding(.vertical, 2)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(L10n.t("lufs.help"))
        .popover(isPresented: $showPanel, arrowEdge: .leading) {
            LoudnessPanel().environmentObject(model).environmentObject(meters).padding(14).frame(width: 340)
        }
    }

    static func format(_ v: Float) -> String { v.isFinite && v > -70 ? String(format: "%.1f", v) : "–" }

    /// Green around the streaming target (−14 to −16), yellow when far off.
    static func color(_ v: Float) -> Color {
        guard v.isFinite, v > -70 else { return Theme.textDim }
        if v > -9 { return Theme.program }
        if v >= -18 { return .green }
        return Theme.warning
    }
}

struct LoudnessPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var meters: MeterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L10n.t("lufs.title"))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row(L10n.t("lufs.momentary"), meters.loudness.momentary)
                row(L10n.t("lufs.short"), meters.loudness.shortTerm)
                row(L10n.t("lufs.integrated"), meters.loudness.integrated)
            }
            HStack {
                Text(L10n.t("lufs.target")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                Spacer()
                Button(L10n.t("lufs.reset")) { model.resetLoudness() }
            }
            Divider()
            SectionHeader(title: L10n.t("duck.title"))
            let d = model.ducking
            Toggle(L10n.t("duck.enabled"), isOn: Binding(get: { d.enabled }, set: { var n = model.ducking; n.enabled = $0; model.ducking = n }))
                .toggleStyle(.checkbox)
            Text(L10n.t("duck.how")).font(.system(size: 10)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            slider(L10n.t("duck.threshold"), d.thresholdDB, DuckingSettings.thresholdRange, "%.0f dB") { v in var n = model.ducking; n.thresholdDB = v; model.ducking = n.clamped }
            slider(L10n.t("duck.depth"), d.depthDB, DuckingSettings.depthRange, "%.0f dB") { v in var n = model.ducking; n.depthDB = v; model.ducking = n.clamped }
            slider(L10n.t("duck.attack"), d.attackMs, DuckingSettings.attackRange, "%.0f ms") { v in var n = model.ducking; n.attackMs = v; model.ducking = n.clamped }
            slider(L10n.t("duck.hold"), d.holdMs, DuckingSettings.holdRange, "%.0f ms") { v in var n = model.ducking; n.holdMs = v; model.ducking = n.clamped }
            slider(L10n.t("duck.release"), d.releaseMs, DuckingSettings.releaseRange, "%.0f ms") { v in var n = model.ducking; n.releaseMs = v; model.ducking = n.clamped }
            let triggers = model.audioChannels.filter(\.duckTrigger).map(\.name)
            let targets = model.audioChannels.filter(\.duckTarget).map(\.name)
            Text(L10n.f("duck.routing", triggers.isEmpty ? "–" : triggers.joined(separator: ", "),
                        targets.isEmpty ? "–" : targets.joined(separator: ", ")))
                .font(.system(size: 10)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ label: String, _ v: Float) -> some View {
        GridRow {
            Text(label).font(.system(size: 11))
            Text(LoudnessReadout.format(v) + " LUFS").font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(LoudnessReadout.color(v))
        }
    }

    private func slider(_ label: String, _ value: Float, _ range: ClosedRange<Float>, _ fmt: String,
                        set: @escaping (Float) -> Void) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).frame(width: 80, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: { set(Float($0)) }), in: Double(range.lowerBound)...Double(range.upperBound))
            Text(String(format: fmt, value)).font(.system(size: 10).monospacedDigit()).frame(width: 56, alignment: .trailing)
        }
    }
}

// MARK: Title data source

struct DataSourceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let input: InputID
    @State private var kind: TitleDataSource.Kind = .url
    @State private var location = ""
    @State private var titleColumn: String?
    @State private var subtitleColumn: String?
    @State private var row = 0
    @State private var refresh = 0.0
    @State private var table: CSVTable?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("data.title")).font(.title2.bold())
            Text(L10n.t("data.intro")).font(.system(size: 11)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $kind) {
                Text(L10n.t("data.kind_url")).tag(TitleDataSource.Kind.url)
                Text(L10n.t("data.kind_file")).tag(TitleDataSource.Kind.file)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 320)
            HStack {
                TextField(kind == .url ? "https://docs.google.com/spreadsheets/d/…" : L10n.t("data.file_placeholder"), text: $location)
                    .textFieldStyle(.roundedBorder)
                if kind == .file { Button(L10n.t("data.choose")) { chooseFile() } }
                Button(L10n.t("data.load")) { load() }.disabled(location.trimmingCharacters(in: .whitespaces).isEmpty || loading)
            }
            if kind == .url {
                Text(L10n.t("data.sheets_help")).font(.system(size: 10)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(L10n.t("data.refresh"))
                    Picker("", selection: $refresh) {
                        Text(L10n.t("data.refresh_manual")).tag(0.0)
                        ForEach([10.0, 30, 60, 300], id: \.self) { s in Text(s < 60 ? "\(Int(s)) s" : "\(Int(s / 60)) min").tag(s) }
                    }
                    .labelsHidden().frame(width: 140)
                }
                .font(.system(size: 11))
            }
            if loading { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.warning) }
            if let t = table {
                Divider()
                HStack {
                    columnPicker(L10n.t("data.title_column"), $titleColumn, t)
                    columnPicker(L10n.t("data.subtitle_column"), $subtitleColumn, t)
                }
                Text(L10n.f("data.rows", t.rows.count)).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                List(selection: Binding(get: { row }, set: { row = $0 ?? row })) {
                    ForEach(t.rows.indices, id: \.self) { i in
                        HStack {
                            Text("\(i + 1)").foregroundStyle(Theme.textDim).frame(width: 28, alignment: .trailing)
                            Text(titleColumn.flatMap { t.value(row: i, column: $0) } ?? "").bold()
                            Text(subtitleColumn.flatMap { t.value(row: i, column: $0) } ?? "").foregroundStyle(Theme.textDim)
                        }
                        .font(.system(size: 11))
                        .tag(i)
                    }
                }
                .frame(height: 200)
            }
            Divider()
            HStack {
                if model.dataSource(input) != nil {
                    Button(L10n.t("data.disconnect"), role: .destructive) { model.setDataSource(nil, for: input); dismiss() }
                }
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.t("data.apply")) { apply() }.keyboardShortcut(.defaultAction).disabled(table == nil)
            }
        }
        .padding(18)
        .frame(width: 620)
        .onAppear {
            if let ds = model.dataSource(input) {
                kind = ds.kind; location = ds.location; titleColumn = ds.titleColumn; subtitleColumn = ds.subtitleColumn
                row = ds.row; refresh = ds.refreshSeconds ?? 0
                table = model.dataTables[input]
                if table == nil { load() }
            }
        }
    }

    private var draft: TitleDataSource {
        TitleDataSource(kind: kind, location: location.trimmingCharacters(in: .whitespacesAndNewlines), titleColumn: titleColumn,
                        subtitleColumn: subtitleColumn, row: row, refreshSeconds: kind == .url && refresh > 0 ? refresh : nil)
    }

    private func load() {
        loading = true
        error = nil
        AppModel.readTable(draft) { result in
            loading = false
            switch result {
            case let .success(t):
                table = t
                if titleColumn == nil || !t.header.contains(titleColumn ?? "") {
                    var d = draft
                    d.titleColumn = nil; d.subtitleColumn = nil
                    d.pickDefaultColumns(t)
                    titleColumn = d.titleColumn; subtitleColumn = d.subtitleColumn
                }
                row = min(row, max(t.rows.count - 1, 0))
            case let .failure(e):
                table = nil
                error = L10n.f("data.load_failed", e.localizedDescription)
            }
        }
    }

    private func apply() {
        model.setDataSource(draft, for: input)
        dismiss()
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText] + (UTType(filenameExtension: "xlsx").map { [$0] } ?? [])
        guard panel.runModal() == .OK, let url = panel.url else { return }
        location = url.path
        load()
    }

    private func columnPicker(_ label: String, _ value: Binding<String?>, _ t: CSVTable) -> some View {
        Picker(label, selection: value) {
            Text(L10n.t("data.none")).tag(String?.none)
            ForEach(t.header, id: \.self) { h in Text(h).tag(String?.some(h)) }
        }
        .font(.system(size: 11))
    }
}

// MARK: PTZ

struct PTZSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let input: InputID
    @State private var host = ""
    @State private var transport: PTZConfig.Transport = .sonyUDP
    @State private var port = PTZConfig.Transport.sonyUDP.defaultPort
    @State private var address = 1
    @State private var speed = 8
    @State private var presetNames = Array(repeating: "", count: PTZConfig.presetCount)
    @State private var storing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("ptz.title")).font(.title2.bold())
                Spacer()
                if let s = model.ptzStatus[input] { Text(s).font(.system(size: 11)).foregroundStyle(Theme.warning) }
            }
            Text(L10n.t("ptz.intro")).font(.system(size: 11)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text(L10n.t("ptz.address"))
                    TextField("192.168.1.88", text: $host).textFieldStyle(.roundedBorder).frame(width: 200)
                }
                GridRow {
                    Text(L10n.t("ptz.protocol"))
                    Picker("", selection: $transport) {
                        Text("VISCA over IP (Sony, UDP)").tag(PTZConfig.Transport.sonyUDP)
                        Text("VISCA UDP").tag(PTZConfig.Transport.udp)
                        Text("VISCA TCP").tag(PTZConfig.Transport.tcp)
                    }
                    .labelsHidden().frame(width: 240)
                    .onChange(of: transport) { t in port = t.defaultPort }
                }
                GridRow {
                    Text(L10n.t("ptz.port"))
                    HStack {
                        TextField("", value: $port, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 80)
                        Stepper(L10n.f("ptz.camera_id", address), value: $address, in: 1...7)
                    }
                }
                GridRow {
                    Text(L10n.t("ptz.speed"))
                    Slider(value: Binding(get: { Double(speed) }, set: { speed = Int($0) }), in: 1...24, step: 1).frame(width: 200)
                }
            }
            .font(.system(size: 12))
            HStack {
                Button(L10n.t("ptz.save")) { save() }.disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.ptzConfig(input) != nil {
                    Button(L10n.t("ptz.remove"), role: .destructive) { model.setPTZ(nil, for: input); dismiss() }
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 24) {
                // Arrow pad: hold to move, release to stop.
                VStack(spacing: 4) {
                    holdButton("arrow.up", .panTilt(pan: .stop, tilt: .up, panSpeed: speed, tiltSpeed: speed))
                    HStack(spacing: 4) {
                        holdButton("arrow.left", .panTilt(pan: .left, tilt: .stop, panSpeed: speed, tiltSpeed: speed))
                        Button { model.ptz(.home, input: input) } label: { Image(systemName: "house").frame(width: 34, height: 34) }
                            .help(L10n.t("ptz.home"))
                        holdButton("arrow.right", .panTilt(pan: .right, tilt: .stop, panSpeed: speed, tiltSpeed: speed))
                    }
                    holdButton("arrow.down", .panTilt(pan: .stop, tilt: .down, panSpeed: speed, tiltSpeed: speed))
                }
                VStack(spacing: 4) {
                    holdButton("plus.magnifyingglass", .zoom(.tele(4)), stop: .zoom(.stop))
                    holdButton("minus.magnifyingglass", .zoom(.wide(4)), stop: .zoom(.stop))
                    Button(L10n.t("ptz.autofocus")) { model.ptz(.autoFocus, input: input) }.font(.system(size: 10))
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.t("ptz.presets")).font(.system(size: 11, weight: .bold))
                        Spacer()
                        Toggle(L10n.t("ptz.store_mode"), isOn: $storing).toggleStyle(.checkbox).font(.system(size: 10))
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(70)), count: 4), spacing: 4) {
                        ForEach(0..<PTZConfig.presetCount, id: \.self) { i in
                            Button {
                                model.ptz(storing ? .storePreset(i) : .recallPreset(i), input: input)
                                storing = false
                            } label: {
                                Text(presetNames[i].isEmpty ? "\(i + 1)" : presetNames[i]).lineLimit(1).frame(width: 60)
                            }
                            .contextMenu {
                                Button(L10n.t("ptz.store_here")) { model.ptz(.storePreset(i), input: input) }
                            }
                        }
                    }
                    Text(L10n.t("ptz.names")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(70)), count: 4), spacing: 4) {
                        ForEach(0..<PTZConfig.presetCount, id: \.self) { i in
                            TextField("\(i + 1)", text: $presetNames[i]).textFieldStyle(.roundedBorder).font(.system(size: 10))
                        }
                    }
                }
            }
            .disabled(model.ptzConfig(input) == nil)
            HStack {
                Spacer()
                Button(L10n.t("common.close")) { save(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 640)
        .onAppear {
            if let c = model.ptzConfig(input) {
                host = c.host; transport = c.transport; port = c.port; address = c.address; speed = c.speed
                for i in 0..<PTZConfig.presetCount where i < c.presetNames.count { presetNames[i] = c.presetNames[i] }
            }
        }
    }

    private func save() {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var names = presetNames
        while names.last?.isEmpty == true { names.removeLast() }
        let c = PTZConfig(host: host, transport: transport, port: port, address: address, speed: speed, presetNames: names).clamped
        if c != model.ptzConfig(input) { model.setPTZ(c, for: input) }
    }

    /// Sends `command` while pressed and `stop` when released.
    private func holdButton(_ symbol: String, _ command: VISCA.Command,
                            stop: VISCA.Command = .panTilt(pan: .stop, tilt: .stop, panSpeed: 1, tiltSpeed: 1)) -> some View {
        PTZHoldButton(symbol: symbol) { pressed in model.ptz(pressed ? command : stop, input: input) }
    }
}

private struct PTZHoldButton: View {
    let symbol: String
    let onChange: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .frame(width: 34, height: 34)
            .background(pressed ? Theme.accent : Theme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true; onChange(true) } }
                .onEnded { _ in pressed = false; onChange(false) })
    }
}
#endif

#if os(macOS)
// MARK: Undo for editor sheets

/// Undo / redo for an editor sheet (Title Designer, Scene editor): records each change of the
/// draft, coalescing quick changes (a slider drag) into one step, and registers with Edit › Undo
/// while the sheet is open.
final class DraftHistory<Value: Equatable>: ObservableObject {
    @Published private(set) var history: EditHistory<Value>?
    /// Puts an undone / redone value back into the editor.
    var apply: ((Value) -> Void)?
    private var previous: EditorUndo?
    private var restoring = false

    func start(_ value: Value, model: AppModel) {
        history = EditHistory(value)
        previous = model.editorUndo
        model.editorUndo = EditorUndo(canUndo: { [weak self] in self?.history?.canUndo ?? false },
                                      canRedo: { [weak self] in self?.history?.canRedo ?? false },
                                      undo: { [weak self] in self?.undo() },
                                      redo: { [weak self] in self?.redo() })
    }

    /// Gives Edit › Undo back to whatever had it before the sheet opened.
    func stop(model: AppModel) {
        model.editorUndo = previous
        previous = nil
    }

    func record(_ value: Value) {
        guard !restoring else { return }
        history?.record(value, now: ProcessInfo.processInfo.systemUptime)
    }

    /// A button press is its own step even right after a drag.
    func breakCoalescing() { history?.breakCoalescing() }

    var canUndo: Bool { history?.canUndo ?? false }
    var canRedo: Bool { history?.canRedo ?? false }

    func undo() { if let v = history?.undo() { restore(v) } }
    func redo() { if let v = history?.redo() { restore(v) } }

    private func restore(_ v: Value) {
        restoring = true
        apply?(v)
        // onChange fires after this update; keep it from recording the restored value.
        DispatchQueue.main.async { self.restoring = false }
    }
}

/// Undo / redo buttons for an editor sheet.
struct UndoRedoButtons<Value: Equatable>: View {
    @ObservedObject var history: DraftHistory<Value>
    var body: some View {
        HStack(spacing: 2) {
            Button { history.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .help(L10n.t("undo.undo") + " (⌘Z)")
                .disabled(!history.canUndo)
            Button { history.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .help(L10n.t("undo.redo") + " (⇧⌘Z)")
                .disabled(!history.canRedo)
        }
    }
}
#endif
