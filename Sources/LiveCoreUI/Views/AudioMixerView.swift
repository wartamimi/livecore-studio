#if os(macOS)
import Combine
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

struct AudioMixerView: View {
    @EnvironmentObject var model: AppModel
    @State private var showRadio = false
    /// Compact mixer: strips show only name, meter, fader and mute/solo (details hidden).
    @AppStorage("mixer.compact") private var compact = false
    /// Aux buses (A/B) folded away.
    @AppStorage("mixer.hideAux") private var hideAux = false
    /// How many aux buses the mixer shows (0.48.0: AUX A–D, "+ AUX / BUS" adds one).
    @AppStorage("mixer.auxCount") private var auxCount = 2
    /// Input strips folded to a slim bar at the side (0.63.0); Aux and Master stay visible.
    @AppStorage("mixer.inputsFolded") private var inputsFolded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: L10n.t("audio.title"))
                Spacer()
                Button { inputsFolded.toggle() } label: {
                    Image(systemName: inputsFolded ? "sidebar.left" : "sidebar.squares.left")
                }
                .buttonStyle(.borderless)
                .help(inputsFolded ? L10n.t("mixer.unfold_inputs") : L10n.t("mixer.fold_inputs"))
                Button { compact.toggle() } label: {
                    Image(systemName: compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                }
                .buttonStyle(.borderless)
                .help(compact ? L10n.t("mixer.expand_details") : L10n.t("mixer.minimize_details"))
                Button { hideAux.toggle() } label: { Image(systemName: hideAux ? "a.square" : "a.square.fill") }
                    .buttonStyle(.borderless)
                    .help(hideAux ? L10n.t("mixer.show_aux") : L10n.t("mixer.hide_aux"))
                if !model.audioChannels.isEmpty {
                    let allLocked = model.audioChannels.allSatisfy(\.locked)
                    Button { model.lockAllAudio(!allLocked) } label: { Image(systemName: allLocked ? "lock.fill" : "lock.open") }
                        .buttonStyle(.borderless)
                        .help(allLocked ? L10n.t("lock.unlock_all_audio") : L10n.t("lock.lock_all_audio"))
                }
                Menu {
                    ForEach(model.audioDevices) { d in Button(d.name) { model.addAudioInput(d) } }
                    Divider()
                    Button(L10n.t("tone.add")) { model.addTone() }
                    Button(L10n.t("radio.menu")) { showRadio = true }
                    Divider()
                    Button(L10n.t("aux.add")) { auxCount = min(auxCount + 1, 4); hideAux = false }
                        .disabled(auxCount >= 4)
                    Button(L10n.t("aux.remove")) { auxCount = max(auxCount - 1, 0) }
                        .disabled(auxCount <= 0)
                } label: { Image(systemName: "plus.circle.fill") }
                .menuStyle(.borderlessButton).fixedSize()
                .help(L10n.t("audio.add"))
            }
            HStack(alignment: .top, spacing: 6) {
                if inputsFolded {
                    DockBar(title: L10n.f("mixer.inputs_folded", model.audioChannels.count), axis: .vertical) { inputsFolded = false }
                    Spacer(minLength: 0)
                } else if model.audioChannels.isEmpty {
                    Text(L10n.t("audio.none")).font(.system(size: 12)).foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 6) {
                            ForEach(model.audioChannels) { ch in
                                ChannelStripView(vm: ch)
                            }
                        }
                    }
                }
                if !hideAux && auxCount > 0 {
                    Divider()
                    ForEach(model.auxBuses.prefix(auxCount)) { bus in
                        AuxStripView(bus: bus)
                    }
                }
                Divider()
                MasterStripView()
            }
        }
        .padding(8)
        .panel()
        .dialog(isPresented: $showRadio, model) { RadioSearchSheet() }
    }
}

struct ChannelStripView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var vm: ChannelVM
    @State private var showDSP = false
    @State private var hovering = false
    @State private var confirmClose = false
    @AppStorage("mixer.compact") private var compact = false
    @AppStorage("mixer.auxCount") private var auxCount = 2

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                if vm.isFileChannel { Image(systemName: "film").font(.system(size: 8)).help(L10n.t("audio.file")) }
                if vm.isMusicChannel { Image(systemName: "music.note").font(.system(size: 8)).help(L10n.t("music.title")) }
                if vm.isRadioChannel { Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 8)).help(L10n.t("radio.title")) }
                if model.tone(vm.id) != nil { Image(systemName: "waveform").font(.system(size: 8)).help(L10n.t("tone.name")) }
                Text(vm.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                if let i = model.pairedInput(of: vm.id), let name = model.inputs.first(where: { $0.id == i })?.name {
                    Image(systemName: "link").font(.system(size: 8)).foregroundStyle(Theme.accent).help(L10n.f("pair.with", name))
                }
                Spacer(minLength: 0)
                Button { vm.locked.toggle() } label: {
                    Image(systemName: vm.locked ? "lock.fill" : "lock.open").font(.system(size: 8))
                        .foregroundStyle(vm.locked ? Theme.warning : Theme.textDim)
                }
                .buttonStyle(.plain)
                .help(vm.locked ? L10n.t("lock.unlock_audio") : L10n.t("lock.lock_audio"))
                if hovering && !vm.locked {
                    Button { confirmClose = true } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("audio.close"))
                }
            }
            .frame(width: 84)
            HStack(spacing: 4) {
                StereoMeter(source: .channel(vm.id))
                VerticalFader(value: $vm.fader)
            }
            .frame(height: compact ? 90 : 120)
            Text(dbLabel).font(.system(size: 9).monospacedDigit()).foregroundStyle(Theme.textDim)
            HStack(spacing: 3) {
                toggle(L10n.t("audio.mute"), $vm.muted, Theme.program)
                toggle(L10n.t("audio.solo"), $vm.solo, Theme.warning)
                toggle(L10n.t("audio.pgm"), $vm.toProgram, Theme.accent)
            }
            if !compact { details }
        }
        .padding(4)
        .card(stroke: hovering ? Color.white.opacity(0.2) : Theme.border)
        .onHover { hovering = $0 }
        .alert(L10n.f("audio.close_confirm", vm.name), isPresented: $confirmClose) {
            Button(L10n.t("audio.close"), role: .destructive) { model.closeAudioChannel(vm.id) }
            Button(L10n.t("settings.cancel"), role: .cancel) {}
        } message: {
            Text(closeMessage)
        }
    }

    /// Transport, aux sends and properties: hidden in the compact mixer.
    @ViewBuilder private var details: some View {
            if let m = model.musicPlayer(vm.id) { MusicTransport(player: m) }
            if let r = model.radio(vm.id) { RadioTransport(radio: r) }
            HStack(spacing: 3) {
                let n = auxCount
                if n > 0 { toggle("A", $vm.toBusA, Theme.preview).help(L10n.t("aux.send_a")) }
                if n > 1 { toggle("B", $vm.toBusB, Theme.preview).help(L10n.t("aux.send_b")) }
                if n > 2 { toggle("C", $vm.toBusC, Theme.preview).help(L10n.f("aux.send_n", "C")) }
                if n > 3 { toggle("D", $vm.toBusD, Theme.preview).help(L10n.f("aux.send_n", "D")) }
                afvButton
            }
            Button { showDSP = true } label: {
                Label(dspLabel, systemImage: "slider.horizontal.3").labelStyle(.titleAndIcon)
            }
                .buttonStyle(.borderless).font(.system(size: 10))
                .help(L10n.t("audio.properties"))
                .dialog(isPresented: $showDSP, model) {
                    AudioPropertiesSheet(vm: vm, meter: model.meters.meter(vm.id)).environmentObject(model.meters)
                }
                .contextMenu {
                    Button(L10n.t("audio.properties")) { showDSP = true }
                    Divider()
                    Button(L10n.f("aux.mix_minus", "A")) { model.makeMixMinus(bus: 0, excluding: vm.id) }
                    Button(L10n.f("aux.mix_minus", "B")) { model.makeMixMinus(bus: 1, excluding: vm.id) }
                    Divider()
                    Toggle(L10n.t("duck.trigger"), isOn: $vm.duckTrigger)
                    Toggle(L10n.t("duck.target"), isOn: $vm.duckTarget)
                    Toggle(L10n.t("automix.enable"), isOn: $vm.autoMix)
                    if let m = model.musicPlayer(vm.id) {
                        Divider()
                        Button(L10n.t("music.add_tracks")) { model.addTracks(toMusic: vm.id) }
                        Toggle(L10n.t("music.loop"), isOn: Binding(get: { m.loopPlaylist }, set: { m.loopPlaylist = $0; model.objectWillChange.send() }))
                        Toggle(L10n.t("music.shuffle"), isOn: Binding(get: { m.shuffle }, set: { m.shuffle = $0; model.objectWillChange.send() }))
                        Menu(L10n.t("music.fade")) {
                            ForEach([0.0, 1, 2, 3, 5, 8], id: \.self) { s in
                                Button((abs(m.fadeSeconds - s) < 0.01 ? "✓ " : "") + (s == 0 ? L10n.t("music.fade_off") : String(format: "%.0f s", s))) {
                                    m.fadeSeconds = s; model.objectWillChange.send()
                                }
                            }
                        }
                        Menu(L10n.t("music.tracks")) {
                            ForEach(Array(m.tracks.enumerated()), id: \.offset) { i, u in
                                Button((i == m.index ? "▶ " : "") + u.deletingPathExtension().lastPathComponent) { m.select(i) }
                            }
                        }
                    }
                    Divider()
                    Button(L10n.t("audio.close"), role: .destructive) { confirmClose = true }.disabled(vm.locked)
                }
    }

    /// What closing removes: the input the audio belongs to, the music input, or the channel.
    private var closeMessage: String {
        if let input = ProductionEngine.inputOfChannel(vm.id) {
            return L10n.f("audio.close_input_message", model.inputs.first { $0.id == input }?.name ?? "")
        }
        return vm.isMusicChannel ? L10n.t("audio.close_music_message") : L10n.t("audio.close_message")
    }

    /// AFV: a video file's own audio follows its input with one click; other channels pick the
    /// input to follow from a menu.
    @ViewBuilder private var afvButton: some View {
        let link = model.afvLink(vm.id)
        if let own = ProductionEngine.inputOfChannel(vm.id) {
            toggle("AFV", Binding(get: { link != nil }, set: { model.setAFV(vm.id, input: $0 ? own : nil) }), Theme.program)
                .help(L10n.t("afv.help"))
        } else {
            Menu {
                Button(L10n.t("afv.off")) { model.setAFV(vm.id, input: nil) }
                Divider()
                ForEach(model.inputs) { info in
                    Button((link == info.id ? "✓ " : "") + info.name) { model.setAFV(vm.id, input: info.id) }
                }
            } label: {
                Text("AFV").font(.system(size: 9, weight: .bold))
                    .frame(width: 26, height: 18)
                    .background(link != nil ? Theme.program : Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(link.flatMap { id in model.inputs.first { $0.id == id }?.name }.map { L10n.f("afv.following", $0) } ?? L10n.t("afv.help"))
        }
    }

    /// "DSP", with a marker for each active processor (G = gate, C = compressor).
    private var dspLabel: String {
        let active = [vm.highPass || vm.eq ? "EQ" : nil, vm.gate ? "G" : nil, vm.compressor ? "C" : nil,
                      vm.duckTrigger ? "D↑" : nil, vm.duckTarget ? "D↓" : nil, vm.autoMix ? "AM" : nil].compactMap { $0 }
        return active.isEmpty ? L10n.t("audio.dsp") : "\(L10n.t("audio.dsp")) " + active.joined(separator: "·")
    }

    private var dbLabel: String {
        let db = FaderLaw.db(forPosition: vm.fader)
        return db <= -90 ? "-∞ dB" : String(format: "%+.1f dB", db)
    }

    private func toggle(_ label: String, _ b: Binding<Bool>, _ color: Color) -> some View {
        Button(label) { b.wrappedValue.toggle() }
            .font(.system(size: 9, weight: .bold))
            .frame(width: 26, height: 18)
            .background(b.wrappedValue ? color : Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .buttonStyle(.plain)
    }
}

/// Play/pause, previous/next and the current track of a music input.
struct MusicTransport: View {
    @EnvironmentObject var model: AppModel
    let player: MusicInput

    var body: some View {
        VStack(spacing: 2) {
            Text(player.currentTitle).font(.system(size: 9)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(Theme.textDim).frame(width: 84)
                .help("\(player.index + 1)/\(player.tracks.count) · \(player.currentTitle)")
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                if let d = player.duration {
                    Slider(value: Binding(get: { min(player.position, d) }, set: { player.seek(to: $0) }), in: 0...d)
                        .controlSize(.mini).frame(width: 84)
                        .help("\(TimerMath.duration(player.position)) / \(TimerMath.duration(d))")
                }
            }
            HStack(spacing: 6) {
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
            }
            .buttonStyle(.borderless).font(.system(size: 10))
        }
    }
}

/// vMix-style audio properties of one channel: general (name, channels, phase, delay, gain, pan),
/// EQ, noise gate, compressor and routing, with live meters.
struct AudioPropertiesSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var vm: ChannelVM
    /// The sheet's live meters (gate / compressor / limiter readouts) follow this channel only.
    @ObservedObject var meter: ChannelMeter
    @Environment(\.dismiss) private var dismiss

    /// Audio Unit / VST3 inserts of this channel (0.60.0), after the compressor, before the fader.
    @ViewBuilder private var pluginsTab: some View {
        if let engine = model.engine {
            ScrollView { PluginChainSheet(chain: vm.channel.inserts, host: engine.plugins, title: vm.name, embedded: true) }
        }
    }

    /// Pages of the sheet (0.76.2: side list like Settings and input Properties, no cut-off tabs).
    private enum Page: String, CaseIterable, Identifiable {
        case general, eq, gate, compressor, limiter, routing, autoMix, plugins
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return L10n.t("audio.tab.general")
            case .eq: return L10n.t("audio.eq")
            case .gate: return L10n.t("audio.gate")
            case .compressor: return L10n.t("audio.compressor")
            case .limiter: return L10n.t("audio.limiter")
            case .routing: return L10n.t("audio.tab.routing")
            case .autoMix: return L10n.t("automix.tab")
            case .plugins: return L10n.t("plugins.tab")
            }
        }
        var icon: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .eq: return "slider.vertical.3"
            case .gate: return "door.left.hand.closed"
            case .compressor: return "arrow.down.right.and.arrow.up.left"
            case .limiter: return "line.horizontal.3.decrease"
            case .routing: return "arrow.triangle.branch"
            case .autoMix: return "person.wave.2"
            case .plugins: return "puzzlepiece.extension"
            }
        }
    }
    @State private var page: Page = .general

    var body: some View {
        let level: MeterModel.Level? = meter.level
        GeometryReader { g in
            let wide = g.size.width >= 620
            VStack(spacing: 0) {
                DialogHeader(icon: "waveform", title: L10n.t("audio.properties"), subtitle: vm.name, close: { dismiss() }) {
                    if !wide {
                        Picker("", selection: $page) { ForEach(Page.allCases) { Text($0.title).tag($0) } }
                            .labelsHidden().fixedSize()
                    }
                    HStack(spacing: 3) {
                        MeterView(levelDB: level?.l ?? -120, holdDB: level?.holdL ?? -120)
                        MeterView(levelDB: level?.r ?? -120, holdDB: level?.holdR ?? -120)
                    }
                    .frame(height: 30)
                }
                HStack(spacing: 0) {
                    if wide {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(Page.allCases) { p in SidebarRow(title: p.title, icon: p.icon, selected: page == p) { page = p } }
                            }
                            .padding(8)
                        }
                        .frame(width: 180)
                        .background(Theme.panel)
                        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
                    }
                    content(level).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                HStack {
                    Button(L10n.t("audio.reset_dsp")) { resetDSP() }
                    Spacer()
                    Button(L10n.t("common.close")) { dismiss() }
                        .buttonStyle(StudioButtonStyle(color: Theme.accent, active: true)).frame(width: 110)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.panel)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .frame(minWidth: 460, idealWidth: 780, maxWidth: 1100, minHeight: 440, idealHeight: 560, maxHeight: 900)
    }

    @ViewBuilder private func content(_ level: MeterModel.Level?) -> some View {
        switch page {
        case .general: general
        case .eq: eqTab
        case .gate: gateTab(level)
        case .compressor: compTab(level)
        case .limiter: limiterTab(level)
        case .routing: routing
        case .autoMix: autoMixTab
        case .plugins: pluginsTab
        }
    }

    /// Auto mixer (0.65.0): gain sharing between all channels with Auto Mix on.
    private var autoMixTab: some View {
        Form {
            Toggle(L10n.t("automix.enable"), isOn: $vm.autoMix)
            row(L10n.t("automix.weight"), $vm.autoMixWeight, Double(AutoMixer.weightRange.lowerBound)...Double(AutoMixer.weightRange.upperBound), "%+.0f dB")
            LabeledContent(L10n.t("automix.gain")) {
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    let db = vm.channel.controls.autoMixGainDB.value
                    Text(vm.autoMix ? String(format: "%.1f dB", db) : "—").monospacedDigit()
                }
            }
            LabeledContent(L10n.t("automix.group")) {
                Text(model.audioChannels.filter(\.autoMix).map(\.name).joined(separator: ", ")).foregroundStyle(Theme.textDim)
            }
            Text(L10n.t("automix.help")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var general: some View {
        Form {
            TextField(L10n.t("audio.name"), text: $vm.name)
            Picker(L10n.t("audio.channels"), selection: $vm.mode) {
                ForEach(ChannelMode.allCases, id: \.self) { m in Text(L10n.t("audio.mode.\(m.rawValue)")).tag(m) }
            }
            Toggle(L10n.t("audio.invert_phase"), isOn: $vm.invertPhase)
            row("Gain", $vm.gainDB, -24...24, "%+.0f dB")
            row("Pan", $vm.pan, -1...1, "%+.2f")
            row(L10n.t("audio.delay"), $vm.delayMs, 0...Double(ChannelStripDSP.maxDelayMs), "%.0f ms")
            Text(L10n.t("audio.delay_help")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            if let t = model.tone(vm.id) { ToneControls(tone: t) }
            LabeledContent(L10n.t("audio.drift")) { Text(String(format: "%+.0f ppm", vm.channel.driftPPM.value)).monospacedDigit() }
            LabeledContent(L10n.t("audio.underruns")) { Text("\(vm.channel.underrunCount)").monospacedDigit() }
        }
        .formStyle(.grouped)
    }

    private var eqTab: some View {
        Form {
            Toggle(L10n.t("audio.hpf"), isOn: $vm.highPass)
            row("HPF", $vm.highPassHz, 40...300, "%.0f Hz")
            Toggle(L10n.t("audio.lpf"), isOn: $vm.lowPass)
            row("LPF", $vm.lowPassHz, 2000...20000, "%.0f Hz")
            Toggle(L10n.t("audio.eq_enable"), isOn: $vm.eq)
            EQCurveView(vm: vm).frame(height: 70)
            row("Low", $vm.eqLow, -12...12, "%+.1f dB")
            row("Low freq", $vm.eqLowHz, 40...500, "%.0f Hz")
            row("Mid", $vm.eqMid, -12...12, "%+.1f dB")
            row("Mid freq", $vm.eqMidHz, 200...6000, "%.0f Hz")
            row("Mid Q", $vm.eqMidQ, 0.3...8, "%.2f")
            row("High", $vm.eqHigh, -12...12, "%+.1f dB")
            row("High freq", $vm.eqHighHz, 2000...16000, "%.0f Hz")
        }
        .formStyle(.grouped)
    }

    private func gateTab(_ level: MeterModel.Level?) -> some View {
        Form {
            Toggle(L10n.t("audio.enabled"), isOn: $vm.gate)
            row("Threshold", $vm.gateThreshold, -80...0, "%.0f dB")
            row("Range", $vm.gateRange, -80...0, "%.0f dB")
            row("Attack", $vm.gateAttack, 0.1...50, "%.1f ms")
            row("Hold", $vm.gateHold, 0...1000, "%.0f ms")
            row("Release", $vm.gateRelease, 5...2000, "%.0f ms")
            LabeledContent(L10n.t("audio.state")) {
                let g = level?.gate ?? 0
                Text(!vm.gate ? "—" : (g < 1 ? "Open" : String(format: "Closed (−%.0f dB)", g))).monospacedDigit()
            }
        }
        .formStyle(.grouped)
    }

    private func compTab(_ level: MeterModel.Level?) -> some View {
        Form {
            Toggle(L10n.t("audio.enabled"), isOn: $vm.compressor)
            row("Threshold", $vm.compThreshold, -50...0, "%.0f dB")
            row("Ratio", $vm.compRatio, 1...20, "%.1f:1")
            row("Attack", $vm.compAttack, 0.1...200, "%.1f ms")
            row("Release", $vm.compRelease, 5...2000, "%.0f ms")
            row("Knee", $vm.compKnee, 0...24, "%.0f dB")
            row("Makeup", $vm.compMakeup, 0...24, "%+.1f dB")
            LabeledContent(L10n.t("audio.gain_reduction")) { Text(String(format: "%.1f dB", level?.gr ?? 0)).monospacedDigit() }
        }
        .formStyle(.grouped)
    }

    /// Per-channel brick-wall limiter after the compressor, before the fader (0.50.0).
    private func limiterTab(_ level: MeterModel.Level?) -> some View {
        Form {
            Toggle(L10n.t("audio.enabled"), isOn: $vm.limiter)
            row("Ceiling", $vm.limiterCeiling, -20...0, "%.1f dB")
            row("Release", $vm.limiterRelease, 5...1000, "%.0f ms")
            LabeledContent(L10n.t("audio.gain_reduction")) { Text(String(format: "%.1f dB", level?.limiter ?? 0)).monospacedDigit() }
            Text(L10n.t("audio.limiter_help")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
        }
        .formStyle(.grouped)
    }

    private var routing: some View {
        Form {
            Toggle(L10n.t("audio.route_program"), isOn: $vm.toProgram)
            Toggle(L10n.t("aux.send_a"), isOn: $vm.toBusA)
            Toggle(L10n.t("aux.send_b"), isOn: $vm.toBusB)
            Toggle(L10n.f("aux.send_n", "C"), isOn: $vm.toBusC)
            Toggle(L10n.f("aux.send_n", "D"), isOn: $vm.toBusD)
            Toggle(L10n.t("audio.mute"), isOn: $vm.muted)
            Toggle(L10n.t("audio.solo"), isOn: $vm.solo)
            Picker("AFV", selection: Binding(get: { model.afvLink(vm.id) }, set: { model.setAFV(vm.id, input: $0) })) {
                Text(L10n.t("afv.off")).tag(InputID?.none)
                ForEach(model.inputs) { info in Text(info.name).tag(InputID?.some(info.id)) }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ fmt: String) -> some View {
        LabeledContent(label) {
            Slider(value: value, in: range)
            Text(String(format: fmt, value.wrappedValue)).monospacedDigit().frame(width: 70, alignment: .trailing)
        }
    }

    private func resetDSP() {
        vm.mode = .stereo; vm.invertPhase = false; vm.delayMs = 0; vm.gainDB = 0; vm.pan = 0
        vm.highPass = false; vm.highPassHz = 80; vm.eq = false; vm.eqLow = 0; vm.eqMid = 0; vm.eqMidHz = 1000; vm.eqHigh = 0
        vm.gate = false; vm.gateThreshold = -50; vm.gateRange = -80
        vm.compressor = false; vm.compThreshold = -18; vm.compRatio = 3; vm.compAttack = 10; vm.compRelease = 150; vm.compMakeup = 0
        vm.eqLowHz = 120; vm.eqHighHz = 8000; vm.eqMidQ = 0.9; vm.lowPass = false; vm.lowPassHz = 18000
        vm.gateAttack = 2; vm.gateHold = 60; vm.gateRelease = 150; vm.compKnee = 6
        vm.limiter = false; vm.limiterCeiling = -1; vm.limiterRelease = 80
    }
}

/// Frequency response of the channel's filters and EQ, 20 Hz–20 kHz, ±15 dB (0.50.0).
struct EQCurveView: View {
    @ObservedObject var vm: ChannelVM

    var body: some View {
        var p = ChannelEQ.Params()
        p.highPassEnabled = vm.highPass; p.highPassHz = vm.highPassHz
        p.lowPassEnabled = vm.lowPass; p.lowPassHz = vm.lowPassHz
        p.eqEnabled = vm.eq
        p.lowGainDB = vm.eqLow; p.lowHz = vm.eqLowHz
        p.midGainDB = vm.eqMid; p.midHz = vm.eqMidHz; p.midQ = vm.eqMidQ
        p.highGainDB = vm.eqHigh; p.highHz = vm.eqHighHz
        var eq = ChannelEQ(sampleRate: 48_000)
        eq.update(p)
        let curve = eq
        return Canvas { ctx, size in
            let mid = size.height / 2
            var grid = Path()
            grid.move(to: CGPoint(x: 0, y: mid)); grid.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(grid, with: .color(Theme.textDim.opacity(0.4)), lineWidth: 0.5)
            var path = Path()
            let n = 120
            for i in 0...n {
                let x = Double(i) / Double(n)
                let f = 20 * pow(1000, x)            // 20 Hz … 20 kHz, logarithmic
                let db = min(max(curve.responseDB(at: f), -15), 15)
                let pt = CGPoint(x: x * size.width, y: mid - db / 15 * mid)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            ctx.stroke(path, with: .color(Theme.accent), lineWidth: 1.5)
        }
        .background(Theme.panelRaised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Aux bus A/B: post-fader sends from the channels, own fader/mute, optional output device.
struct AuxStripView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var bus: AuxBusVM

    var body: some View {
        VStack(spacing: 4) {
            Text(bus.name).font(.system(size: 10, weight: .heavy))
            HStack(spacing: 4) {
                StereoMeter(source: .aux(bus.index))
                VerticalFader(value: $bus.fader)
            }
            .frame(height: 120)
            Button(L10n.t("audio.mute")) { bus.muted.toggle() }
                .font(.system(size: 9, weight: .bold))
                .frame(width: 34, height: 18)
                .background(bus.muted ? Theme.program : Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .buttonStyle(.plain)
            Menu {
                Button(L10n.t("aux.no_output")) { model.setAuxDevice(bus.index, uid: "") }
                Divider()
                ForEach(model.outputDevices, id: \.uid) { d in
                    Button(d.name) { model.setAuxDevice(bus.index, uid: d.uid) }
                }
            } label: {
                Image(systemName: bus.deviceUID.isEmpty ? "speaker.slash" : "speaker.wave.2.fill").font(.system(size: 10))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(deviceName)
        }
        .padding(4)
        .frame(width: 70)
    }

    private var deviceName: String {
        if bus.deviceUID.isEmpty { return L10n.t("aux.no_output") }
        return model.outputDevices.first { $0.uid == bus.deviceUID }?.name ?? bus.deviceUID
    }
}

struct MasterStripView: View {
    @EnvironmentObject var model: AppModel
    @State private var showFX = false

    var body: some View {
        VStack(spacing: 4) {
            Text(L10n.t("audio.master")).font(.system(size: 10, weight: .heavy))
            HStack(spacing: 4) {
                StereoMeter(source: .master)
                VerticalFader(value: $model.masterFader)
            }
            .frame(height: 120)
            Toggle(L10n.t("audio.limiter"), isOn: $model.limiterEnabled)
                .toggleStyle(.checkbox).font(.system(size: 10))
            StereoMeter(source: .masterGR)
            LoudnessReadout()
            HStack(spacing: 2) {
                Image(systemName: "headphones").font(.system(size: 10))
                Slider(value: $model.monitorVolume, in: 0...1)
                    .frame(width: 70)
            }
            .help(L10n.t("audio.monitor"))
        }
        .padding(4)
        .frame(width: 110)
        // Master inserts: right-click the master strip (the per-channel ones live in Audio Properties).
        .contextMenu { Button(L10n.t("plugins.master_menu")) { showFX = true } }
        .dialog(isPresented: $showFX, model) {
            if let engine = model.engine {
                PluginChainSheet(chain: engine.mixer.masterInserts, host: engine.plugins, title: L10n.t("audio.master"))
            }
        }
    }
}

/// The only views that watch the 30 Hz meter model: strips, faders and the rest of the mixer
/// are not redrawn on every meter update, which keeps dragging smooth and the CPU low.
struct StereoMeter: View {
    enum Source { case channel(String), aux(Int), master, masterGR }
    /// Not observed for changes (MeterModel publishes nothing); each meter watches its own channel.
    @EnvironmentObject var meters: MeterModel
    let source: Source

    var body: some View {
        switch source {
        case let .channel(id): StereoMeterBars(meter: meters.meter(id), grOnly: false)
        case let .aux(i): StereoMeterBars(meter: meters.meter(MeterModel.auxKey(i)), grOnly: false)
        case .master: StereoMeterBars(meter: meters.meter(MeterModel.masterKey), grOnly: false)
        case .masterGR: StereoMeterBars(meter: meters.meter(MeterModel.masterKey), grOnly: true)
        }
    }
}

struct StereoMeterBars: View {
    @ObservedObject var meter: ChannelMeter
    let grOnly: Bool

    var body: some View {
        let level = meter.level
        if grOnly {
            if level.gr > 0.1 {
                Text(String(format: "GR %.1f dB", level.gr)).font(.system(size: 9)).foregroundStyle(Theme.warning)
            }
        } else {
            HStack(spacing: 4) {
                MeterView(levelDB: level.l, holdDB: level.holdL)
                MeterView(levelDB: level.r, holdDB: level.holdR)
            }
        }
    }
}

/// Peak meter: green to -18 dBFS, yellow to -6, red above; peak-hold line.
struct MeterView: View {
    let levelDB: Float
    let holdDB: Float
    static let floor: Float = -60

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.black.opacity(0.5))
                LinearGradient(stops: [
                    .init(color: Theme.meterGreen, location: 0),
                    .init(color: Theme.meterGreen, location: 0.69),
                    .init(color: Theme.meterYellow, location: 0.7),
                    .init(color: Theme.meterYellow, location: 0.89),
                    .init(color: Theme.meterRed, location: 0.9),
                ], startPoint: .bottom, endPoint: .top)
                .mask(alignment: .bottom) { Rectangle().frame(height: h * Self.fraction(levelDB)) }
                Rectangle().fill(holdDB > -6 ? Theme.meterRed : Color.white.opacity(0.8))
                    .frame(height: 2)
                    .offset(y: -h * Self.fraction(holdDB))
                    .opacity(holdDB > Self.floor ? 1 : 0)
            }
        }
        .frame(width: 8)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    static func fraction(_ db: Float) -> CGFloat {
        CGFloat(min(max((db - floor) / -floor, 0), 1))
    }
}

struct VerticalFader: View {
    @Binding var value: Double
    /// Fader position when the drag started: the cap moves by the drag distance instead of
    /// jumping to the pointer, so grabbing it never makes the level leap.
    @State private var dragStart: Double?
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.black.opacity(0.5)).frame(width: 4)
                RoundedRectangle(cornerRadius: 2).fill(Theme.text)
                    .frame(width: 22, height: 10)
                    .offset(y: -CGFloat(value) * (h - 10))
                    .shadow(radius: 1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { g in
                let travel = max(Double(h - 10), 1)
                if dragStart == nil {
                    // A press on the cap grabs it; a press on the track moves the cap there first.
                    let capY = Double(h - 5) - value * travel
                    dragStart = abs(Double(g.startLocation.y) - capY) <= 10 ? value
                        : min(max(1 - Double((g.startLocation.y - 5) / (h - 10)), 0), 1)
                }
                let v = min(max(dragStart! - Double(g.translation.height) / travel, 0), 1)
                if abs(v - value) > 0.0005 {
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { value = v }
                }
            }.onEnded { _ in dragStart = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0.75 }) // unity
        }
        .frame(width: 26)
        .help("Double-click: 0 dB")
    }
}
/// Frequency and level of a test tone channel (in its audio properties).
struct ToneControls: View {
    let tone: TestTone
    @State private var freq: Double = 1000
    @State private var level: Double = -18
    var body: some View {
        Group {
            Picker(L10n.t("tone.frequency"), selection: Binding(get: { freq }, set: { freq = $0; tone.frequency = $0 })) {
                ForEach([100.0, 440, 1000, 10_000], id: \.self) { f in Text(f >= 1000 ? "\(Int(f / 1000)) kHz" : "\(Int(f)) Hz").tag(f) }
            }
            LabeledContent(L10n.t("tone.level")) {
                Slider(value: Binding(get: { level }, set: { level = $0; tone.levelDB = $0 }), in: ToneGenerator.levelRange, step: 1)
                Text(String(format: "%.0f dBFS", level)).monospacedDigit().frame(width: 70, alignment: .trailing)
            }
        }
        .onAppear { freq = tone.frequency; level = tone.levelDB }
    }
}
#endif
