#if os(macOS)
import AppKit
import AVFoundation
import Combine
import CoreImage
import ImageIO
import LiveCoreCore
import LiveCoreEngine
import LiveCoreRemote
import SwiftUI
import UniformTypeIdentifiers
/// Per-channel view model (controls are lock-free atomics shared with the render thread).
public final class ChannelVM: ObservableObject, Identifiable {
    public let channel: MixerChannel
    public var id: String { channel.id }
    @Published public var fader: Double { didSet { channel.controls.faderDB.value = FaderLaw.db(forPosition: fader) } }
    @Published public var gainDB: Double { didSet { channel.controls.gainDB.value = Float(gainDB) } }
    @Published public var pan: Double { didSet { channel.controls.pan.value = Float(pan) } }
    @Published public var muted: Bool { didSet { channel.controls.muted.value = muted } }
    @Published public var solo: Bool { didSet { channel.controls.solo.value = solo } }
    @Published public var toProgram: Bool { didSet { channel.controls.toProgram.value = toProgram } }
    @Published public var toBusA: Bool { didSet { channel.controls.toBusA.value = toBusA } }
    @Published public var toBusB: Bool { didSet { channel.controls.toBusB.value = toBusB } }
    @Published public var compressor: Bool { didSet { channel.controls.compressorEnabled.value = compressor } }
    @Published public var compThreshold: Double { didSet { channel.controls.compThresholdDB.value = Float(compThreshold) } }
    @Published public var compRatio: Double { didSet { channel.controls.compRatio.value = Float(compRatio) } }
    @Published public var gate: Bool { didSet { channel.controls.gateEnabled.value = gate } }
    @Published public var gateThreshold: Double { didSet { channel.controls.gateThresholdDB.value = Float(gateThreshold) } }
    @Published public var gateRange: Double { didSet { channel.controls.gateRangeDB.value = Float(gateRange) } }
    @Published public var highPass: Bool { didSet { channel.controls.highPassEnabled.value = highPass } }
    @Published public var highPassHz: Double { didSet { channel.controls.highPassHz.value = Float(highPassHz) } }
    @Published public var eq: Bool { didSet { channel.controls.eqEnabled.value = eq } }
    @Published public var eqLow: Double { didSet { channel.controls.eqLowDB.value = Float(eqLow) } }
    @Published public var eqMid: Double { didSet { channel.controls.eqMidDB.value = Float(eqMid) } }
    @Published public var eqMidHz: Double { didSet { channel.controls.eqMidHz.value = Float(eqMidHz) } }
    @Published public var eqHigh: Double { didSet { channel.controls.eqHighDB.value = Float(eqHigh) } }
    // Audio properties (0.15.0)
    @Published public var name: String { didSet { channel.name = name } }
    @Published public var compMakeup: Double { didSet { channel.controls.compMakeupDB.value = Float(compMakeup) } }
    @Published public var compAttack: Double { didSet { channel.controls.compAttackMs.value = Float(compAttack) } }
    @Published public var compRelease: Double { didSet { channel.controls.compReleaseMs.value = Float(compRelease) } }
    @Published public var mode: ChannelMode { didSet { channel.controls.mode = mode } }
    @Published public var invertPhase: Bool { didSet { channel.controls.invertPhase.value = invertPhase } }
    @Published public var delayMs: Double { didSet { channel.controls.delayMs.value = Float(delayMs) } }
    @Published public var locked: Bool { didSet { channel.locked = locked } }
    /// Ducking: this channel (MC microphone) turns the ducked channels down / is turned down (music).
    @Published public var duckTrigger: Bool { didSet { channel.controls.duckTrigger.value = duckTrigger } }
    @Published public var duckTarget: Bool { didSet { channel.controls.duckTarget.value = duckTarget } }
    /// Audio of a video-file input (removed together with the input, not from the mixer).
    /// Audio that belongs to an input (video file or window/display capture).
    public var isFileChannel: Bool { ProductionEngine.inputOfChannel(channel.id) != nil }
    /// Channel of a music input (removed with the music input).
    public var isMusicChannel: Bool { channel.id.hasPrefix(ProductionEngine.musicChannelPrefix) }

    public init(channel: MixerChannel) {
        self.channel = channel
        let c = channel.controls
        locked = channel.locked
        duckTrigger = c.duckTrigger.value
        duckTarget = c.duckTarget.value
        name = channel.name
        compMakeup = Double(c.compMakeupDB.value)
        compAttack = Double(c.compAttackMs.value)
        compRelease = Double(c.compReleaseMs.value)
        mode = c.mode
        invertPhase = c.invertPhase.value
        delayMs = Double(c.delayMs.value)
        fader = FaderLaw.position(forDB: c.faderDB.value)
        gainDB = Double(c.gainDB.value)
        pan = Double(c.pan.value)
        muted = c.muted.value
        solo = c.solo.value
        toProgram = c.toProgram.value
        toBusA = c.toBusA.value
        toBusB = c.toBusB.value
        compressor = c.compressorEnabled.value
        compThreshold = Double(c.compThresholdDB.value)
        compRatio = Double(c.compRatio.value)
        gate = c.gateEnabled.value
        gateThreshold = Double(c.gateThresholdDB.value)
        gateRange = Double(c.gateRangeDB.value)
        highPass = c.highPassEnabled.value
        highPassHz = Double(c.highPassHz.value)
        eq = c.eqEnabled.value
        eqLow = Double(c.eqLowDB.value)
        eqMid = Double(c.eqMidDB.value)
        eqMidHz = Double(c.eqMidHz.value)
        eqHigh = Double(c.eqHighDB.value)
    }
}

/// Aux bus A/B view model (fader and mute are atomics shared with the render thread).
public final class AuxBusVM: ObservableObject, Identifiable {
    public let index: Int
    public let controls: ChannelControls
    public var id: Int { index }
    public var name: String { index == 0 ? "AUX A" : "AUX B" }
    @Published public var fader: Double { didSet { controls.faderDB.value = FaderLaw.db(forPosition: fader) } }
    @Published public var muted: Bool { didSet { controls.muted.value = muted } }
    @Published public var deviceUID: String

    init(index: Int, controls: ChannelControls, deviceUID: String) {
        self.index = index; self.controls = controls; self.deviceUID = deviceUID
        fader = FaderLaw.position(forDB: controls.faderDB.value)
        muted = controls.muted.value
    }
}

/// Meter levels refreshed at 30 Hz. Kept separate so only meter views re-render.
public final class MeterModel: ObservableObject {
    public struct Level: Equatable {
        public var l: Float; public var r: Float; public var holdL: Float; public var holdR: Float; public var gr: Float
        public var gate: Float = 0
    }
    @Published public var levels: [String: Level] = [:]
    @Published public var master = Level(l: -120, r: -120, holdL: -120, holdR: -120, gr: 0)
    @Published public var aux: [Level] = []
    /// Program loudness in LUFS (momentary, short-term, integrated) and the ducking reduction (dB).
    public struct Loudness: Equatable {
        public var momentary: Float = -.infinity
        public var shortTerm: Float = -.infinity
        public var integrated: Float = -.infinity
        public var duckDB: Float = 0
    }
    @Published public var loudness = Loudness()

    func updateLoudness(_ mixer: AudioMixerEngine) {
        func r(_ v: Float) -> Float { v.isFinite ? (v * 10).rounded() / 10 : v }
        let l = Loudness(momentary: r(mixer.lufsMomentary.value), shortTerm: r(mixer.lufsShortTerm.value),
                         integrated: r(mixer.lufsIntegrated.value), duckDB: r(mixer.ducking.reductionDB.value))
        if l != loudness { loudness = l }
    }
    private var ballistics: [String: (MeterBallistics, MeterBallistics)] = [:]
    private var lastTime = HostClockUI.now()

    func update(channels: [MixerChannel], master m: ChannelControls, aux auxControls: [ChannelControls] = []) {
        let now = HostClockUI.now()
        let dt = now - lastTime
        lastTime = now
        var out: [String: Level] = [:]
        func step(_ key: String, _ c: ChannelControls) -> Level {
            var (bl, br) = ballistics[key] ?? (MeterBallistics(), MeterBallistics())
            bl.update(peakLinear: c.peakL.exchange(0), dt: dt, now: now)
            br.update(peakLinear: c.peakR.exchange(0), dt: dt, now: now)
            ballistics[key] = (bl, br)
            return Level(l: bl.levelDB, r: br.levelDB, holdL: bl.peakHoldDB, holdR: br.peakHoldDB, gr: c.gainReductionDB.value,
                         gate: c.gateReductionDB.value)
        }
        for ch in channels { out[ch.id] = step(ch.id, ch.controls) }
        let mm = step("__master", m)
        if out != levels { levels = out }
        if mm != master { master = mm }
        let ax = auxControls.enumerated().map { step("__aux\($0.offset)", $0.element) }
        if ax != aux { aux = ax }
    }
}

enum HostClockUI {
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}
#endif
