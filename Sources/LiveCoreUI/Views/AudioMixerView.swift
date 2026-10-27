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
                Menu {
                    ForEach(model.audioDevices) { d in Button(d.name) { model.addAudioInput(d) } }
                    Divider()
                    Button(L10n.t("music.add")) { model.addMusic() }
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

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                if vm.isFileChannel { Image(systemName: "film").font(.system(size: 8)).help(L10n.t("audio.file")) }
                if vm.isMusicChannel { Image(systemName: "music.note").font(.system(size: 8)).help(L10n.t("music.title")) }
                Text(vm.channel.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
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
            }
            Button(dspLabel) { showDSP.toggle() }
                .buttonStyle(.borderless).font(.system(size: 10))
                .popover(isPresented: $showDSP) { DSPPopover(vm: vm, grDB: level?.gr ?? 0, gateDB: level?.gate ?? 0) }
                .contextMenu {
                    Button(L10n.f("aux.mix_minus", "A")) { model.makeMixMinus(bus: 0, excluding: vm.id) }
                    Button(L10n.f("aux.mix_minus", "B")) { model.makeMixMinus(bus: 1, excluding: vm.id) }
                    if let m = model.musicPlayer(vm.id) {
                        Divider()
                        Button(L10n.t("music.add_tracks")) { model.addTracks(toMusic: vm.id) }
                        Toggle(L10n.t("music.loop"), isOn: Binding(get: { m.loopPlaylist }, set: { m.loopPlaylist = $0; model.objectWillChange.send() }))
                        Toggle(L10n.t("music.shuffle"), isOn: Binding(get: { m.shuffle }, set: { m.shuffle = $0; model.objectWillChange.send() }))
                        Menu(L10n.t("music.tracks")) {
                            ForEach(Array(m.tracks.enumerated()), id: \.offset) { i, u in
                                Button((i == m.index ? "▶ " : "") + u.deletingPathExtension().lastPathComponent) { m.select(i) }
                            }
                        }
                        Button(L10n.t("music.remove"), role: .destructive) { model.removeMusic(vm.id) }
                    }
                    // File audio belongs to its video input: remove the input instead.
                    if !vm.isFileChannel && !vm.isMusicChannel { Button(L10n.t("inputs.remove"), role: .destructive) { model.removeAudioInput(vm.id) } }
                }
        }
        .padding(4)
        .background(Theme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
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
            HStack(spacing: 6) {
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
            }
            .buttonStyle(.borderless).font(.system(size: 10))
        }
    }
}

struct DSPPopover: View {
    @ObservedObject var vm: ChannelVM
    let grDB: Float
    let gateDB: Float
    var body: some View {
        Form {
            Section("Input") {
                LabeledContent("Gain") { Slider(value: $vm.gainDB, in: -24...24); Text(String(format: "%+.0f dB", vm.gainDB)).monospacedDigit() }
                LabeledContent("Pan") { Slider(value: $vm.pan, in: -1...1) }
            }
            Section(L10n.t("audio.gate")) {
                Toggle("Enabled", isOn: $vm.gate)
                LabeledContent("Threshold") { Slider(value: $vm.gateThreshold, in: -80...0); Text(String(format: "%.0f dB", vm.gateThreshold)).monospacedDigit() }
                LabeledContent("Range") { Slider(value: $vm.gateRange, in: -80...0); Text(String(format: "%.0f dB", vm.gateRange)).monospacedDigit() }
                LabeledContent("State") {
                    Text(!vm.gate ? "—" : (gateDB < 1 ? "Open" : String(format: "Closed (−%.0f dB)", gateDB))).monospacedDigit()
                }
            }
            Section(L10n.t("audio.eq")) {
                Toggle(L10n.t("audio.hpf"), isOn: $vm.highPass)
                LabeledContent("HPF") { Slider(value: $vm.highPassHz, in: 40...300); Text(String(format: "%.0f Hz", vm.highPassHz)).monospacedDigit() }
                Toggle(L10n.t("audio.eq_enable"), isOn: $vm.eq)
                LabeledContent("Low 120 Hz") { Slider(value: $vm.eqLow, in: -12...12); Text(String(format: "%+.1f dB", vm.eqLow)).monospacedDigit() }
                LabeledContent("Mid") { Slider(value: $vm.eqMid, in: -12...12); Text(String(format: "%+.1f dB", vm.eqMid)).monospacedDigit() }
                LabeledContent("Mid freq") { Slider(value: $vm.eqMidHz, in: 200...6000); Text(String(format: "%.0f Hz", vm.eqMidHz)).monospacedDigit() }
                LabeledContent("High 8 kHz") { Slider(value: $vm.eqHigh, in: -12...12); Text(String(format: "%+.1f dB", vm.eqHigh)).monospacedDigit() }
            }
            Section("Compressor") {
                Toggle("Enabled", isOn: $vm.compressor)
                LabeledContent("Threshold") { Slider(value: $vm.compThreshold, in: -50...0); Text(String(format: "%.0f dB", vm.compThreshold)).monospacedDigit() }
                LabeledContent("Ratio") { Slider(value: $vm.compRatio, in: 1...20); Text(String(format: "%.1f:1", vm.compRatio)).monospacedDigit() }
                LabeledContent("Gain reduction") { Text(String(format: "%.1f dB", grDB)).monospacedDigit() }
            }
            Section(L10n.t("audio.clock")) {
                LabeledContent(L10n.t("audio.drift")) { Text(String(format: "%+.0f ppm", vm.channel.driftPPM.value)).monospacedDigit() }
                LabeledContent(L10n.t("audio.underruns")) { Text("\(vm.channel.underrunCount)").monospacedDigit() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
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
#endif
