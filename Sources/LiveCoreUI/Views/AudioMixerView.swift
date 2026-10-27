#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

struct AudioMixerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var meters: MeterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: L10n.t("audio.title"))
                Spacer()
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
                } label: { Image(systemName: "plus.circle.fill") }
                .menuStyle(.borderlessButton).fixedSize()
                .help(L10n.t("audio.add"))
            }
            HStack(alignment: .top, spacing: 6) {
                if model.audioChannels.isEmpty {
                    Text(L10n.t("audio.none")).font(.system(size: 12)).foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 6) {
                            ForEach(model.audioChannels) { ch in
                                ChannelStripView(vm: ch, level: meters.levels[ch.id])
                            }
                        }
                    }
                }
                Divider()
                ForEach(model.auxBuses) { bus in
                    AuxStripView(bus: bus, level: bus.index < meters.aux.count ? meters.aux[bus.index] : nil)
                }
                Divider()
                MasterStripView()
            }
        }
        .padding(8)
        .panel()
    }
}

struct ChannelStripView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var vm: ChannelVM
    let level: MeterModel.Level?
    @State private var showDSP = false
    @State private var hovering = false
    @State private var confirmClose = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                if vm.isFileChannel { Image(systemName: "film").font(.system(size: 8)).help(L10n.t("audio.file")) }
                if vm.isMusicChannel { Image(systemName: "music.note").font(.system(size: 8)).help(L10n.t("music.title")) }
                if model.tone(vm.id) != nil { Image(systemName: "waveform").font(.system(size: 8)).help(L10n.t("tone.name")) }
                Text(vm.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
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
                MeterView(levelDB: level?.l ?? -120, holdDB: level?.holdL ?? -120)
                MeterView(levelDB: level?.r ?? -120, holdDB: level?.holdR ?? -120)
                VerticalFader(value: $vm.fader)
            }
            .frame(height: 120)
            Text(dbLabel).font(.system(size: 9).monospacedDigit()).foregroundStyle(Theme.textDim)
            HStack(spacing: 3) {
                toggle(L10n.t("audio.mute"), $vm.muted, Theme.program)
                toggle(L10n.t("audio.solo"), $vm.solo, Theme.warning)
                toggle(L10n.t("audio.pgm"), $vm.toProgram, Theme.accent)
            }
            if let m = model.musicPlayer(vm.id) { MusicTransport(player: m) }
            HStack(spacing: 3) {
                toggle("A", $vm.toBusA, Theme.preview).help(L10n.t("aux.send_a"))
                toggle("B", $vm.toBusB, Theme.preview).help(L10n.t("aux.send_b"))
                afvButton
            }
            Button { showDSP = true } label: {
                Label(dspLabel, systemImage: "slider.horizontal.3").labelStyle(.titleAndIcon)
            }
                .buttonStyle(.borderless).font(.system(size: 10))
                .help(L10n.t("audio.properties"))
                .sheet(isPresented: $showDSP) { AudioPropertiesSheet(vm: vm).environmentObject(model).environmentObject(model.meters) }
                .contextMenu {
                    Button(L10n.t("audio.properties")) { showDSP = true }
                    Divider()
                    Button(L10n.f("aux.mix_minus", "A")) { model.makeMixMinus(bus: 0, excluding: vm.id) }
                    Button(L10n.f("aux.mix_minus", "B")) { model.makeMixMinus(bus: 1, excluding: vm.id) }
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
        .padding(4)
        .background(Theme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
        .alert(L10n.f("audio.close_confirm", vm.name), isPresented: $confirmClose) {
            Button(L10n.t("audio.close"), role: .destructive) { model.closeAudioChannel(vm.id) }
            Button(L10n.t("settings.cancel"), role: .cancel) {}
        } message: {
            Text(closeMessage)
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
        let active = [vm.highPass || vm.eq ? "EQ" : nil, vm.gate ? "G" : nil, vm.compressor ? "C" : nil].compactMap { $0 }
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
    @EnvironmentObject var meters: MeterModel
    @ObservedObject var vm: ChannelVM
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let level = meters.levels[vm.id]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(L10n.t("audio.properties")).font(.headline)
                Text(vm.name).foregroundStyle(Theme.textDim)
                Spacer()
                HStack(spacing: 3) {
                    MeterView(levelDB: level?.l ?? -120, holdDB: level?.holdL ?? -120)
                    MeterView(levelDB: level?.r ?? -120, holdDB: level?.holdR ?? -120)
                }
                .frame(height: 40)
            }
            TabView {
                general.tabItem { Text(L10n.t("audio.tab.general")) }
                eqTab.tabItem { Text(L10n.t("audio.eq")) }
                gateTab(level).tabItem { Text(L10n.t("audio.gate")) }
                compTab(level).tabItem { Text(L10n.t("audio.compressor")) }
                routing.tabItem { Text(L10n.t("audio.tab.routing")) }
            }
            .frame(height: 330)
            HStack {
                Button(L10n.t("audio.reset_dsp")) { resetDSP() }
                Spacer()
                Button(L10n.t("common.close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 500)
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
            Toggle(L10n.t("audio.eq_enable"), isOn: $vm.eq)
            row("Low 120 Hz", $vm.eqLow, -12...12, "%+.1f dB")
            row("Mid", $vm.eqMid, -12...12, "%+.1f dB")
            row("Mid freq", $vm.eqMidHz, 200...6000, "%.0f Hz")
            row("High 8 kHz", $vm.eqHigh, -12...12, "%+.1f dB")
        }
        .formStyle(.grouped)
    }

    private func gateTab(_ level: MeterModel.Level?) -> some View {
        Form {
            Toggle(L10n.t("audio.enabled"), isOn: $vm.gate)
            row("Threshold", $vm.gateThreshold, -80...0, "%.0f dB")
            row("Range", $vm.gateRange, -80...0, "%.0f dB")
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
            row("Makeup", $vm.compMakeup, 0...24, "%+.1f dB")
            LabeledContent(L10n.t("audio.gain_reduction")) { Text(String(format: "%.1f dB", level?.gr ?? 0)).monospacedDigit() }
        }
        .formStyle(.grouped)
    }

    private var routing: some View {
        Form {
            Toggle(L10n.t("audio.route_program"), isOn: $vm.toProgram)
            Toggle(L10n.t("aux.send_a"), isOn: $vm.toBusA)
            Toggle(L10n.t("aux.send_b"), isOn: $vm.toBusB)
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
    }
}

/// Aux bus A/B: post-fader sends from the channels, own fader/mute, optional output device.
struct AuxStripView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var bus: AuxBusVM
    let level: MeterModel.Level?

    var body: some View {
        VStack(spacing: 4) {
            Text(bus.name).font(.system(size: 10, weight: .heavy))
            HStack(spacing: 4) {
                MeterView(levelDB: level?.l ?? -120, holdDB: level?.holdL ?? -120)
                MeterView(levelDB: level?.r ?? -120, holdDB: level?.holdR ?? -120)
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
    @EnvironmentObject var meters: MeterModel

    var body: some View {
        VStack(spacing: 4) {
            Text(L10n.t("audio.master")).font(.system(size: 10, weight: .heavy))
            HStack(spacing: 4) {
                MeterView(levelDB: meters.master.l, holdDB: meters.master.holdL)
                MeterView(levelDB: meters.master.r, holdDB: meters.master.holdR)
                VerticalFader(value: $model.masterFader)
            }
            .frame(height: 120)
            Toggle(L10n.t("audio.limiter"), isOn: $model.limiterEnabled)
                .toggleStyle(.checkbox).font(.system(size: 10))
            if meters.master.gr > 0.1 {
                Text(String(format: "GR %.1f dB", meters.master.gr)).font(.system(size: 9)).foregroundStyle(Theme.warning)
            }
            HStack(spacing: 2) {
                Image(systemName: "headphones").font(.system(size: 10))
                Slider(value: $model.monitorVolume, in: 0...1)
                    .frame(width: 70)
            }
            .help(L10n.t("audio.monitor"))
        }
        .padding(4)
        .frame(width: 110)
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
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = min(max(1 - Double((g.location.y - 5) / (h - 10)), 0), 1)
            })
            .onTapGesture(count: 2) { value = 0.75 } // unity
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
