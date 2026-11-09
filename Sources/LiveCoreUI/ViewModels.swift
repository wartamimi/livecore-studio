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
    @Published public var toBusC: Bool { didSet { channel.controls.toBusC.value = toBusC } }
    @Published public var toBusD: Bool { didSet { channel.controls.toBusD.value = toBusD } }
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
    // Advanced audio settings (0.50.0)
    @Published public var eqLowHz: Double { didSet { channel.controls.eqLowHz.value = Float(eqLowHz) } }
    @Published public var eqHighHz: Double { didSet { channel.controls.eqHighHz.value = Float(eqHighHz) } }
    @Published public var eqMidQ: Double { didSet { channel.controls.eqMidQ.value = Float(eqMidQ) } }
    @Published public var lowPass: Bool { didSet { channel.controls.lowPassEnabled.value = lowPass } }
    @Published public var lowPassHz: Double { didSet { channel.controls.lowPassHz.value = Float(lowPassHz) } }
    @Published public var gateAttack: Double { didSet { channel.controls.gateAttackMs.value = Float(gateAttack) } }
    @Published public var gateHold: Double { didSet { channel.controls.gateHoldMs.value = Float(gateHold) } }
    @Published public var gateRelease: Double { didSet { channel.controls.gateReleaseMs.value = Float(gateRelease) } }
    @Published public var compKnee: Double { didSet { channel.controls.compKneeDB.value = Float(compKnee) } }
    @Published public var limiter: Bool { didSet { channel.controls.limiterEnabled.value = limiter } }
    @Published public var limiterCeiling: Double { didSet { channel.controls.limiterCeilingDB.value = Float(limiterCeiling) } }
    @Published public var limiterRelease: Double { didSet { channel.controls.limiterReleaseMs.value = Float(limiterRelease) } }
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
    /// Auto mixer (0.65.0): in the gain-sharing group, and its weight in dB.
    @Published public var autoMix: Bool { didSet { channel.controls.autoMix.value = autoMix } }
    @Published public var autoMixWeight: Double { didSet { channel.controls.autoMixWeightDB.value = Float(autoMixWeight) } }
    /// Audio of a video-file input (removed together with the input, not from the mixer).
    /// Audio that belongs to an input (video file or window/display capture).
    public var isFileChannel: Bool { ProductionEngine.inputOfChannel(channel.id) != nil }
    /// Channel of a music input (removed with the music input).
    public var isMusicChannel: Bool { channel.id.hasPrefix(ProductionEngine.musicChannelPrefix) }
    public var isRadioChannel: Bool { channel.id.hasPrefix(ProductionEngine.radioChannelPrefix) }

    public init(channel: MixerChannel) {
        self.channel = channel
        let c = channel.controls
        locked = channel.locked
        duckTrigger = c.duckTrigger.value
        duckTarget = c.duckTarget.value
        autoMix = c.autoMix.value
        autoMixWeight = Double(c.autoMixWeightDB.value)
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
        toBusC = c.toBusC.value
        toBusD = c.toBusD.value
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
        eqLowHz = Double(c.eqLowHz.value)
        eqHighHz = Double(c.eqHighHz.value)
        eqMidQ = Double(c.eqMidQ.value)
        lowPass = c.lowPassEnabled.value
        lowPassHz = Double(c.lowPassHz.value)
        gateAttack = Double(c.gateAttackMs.value)
        gateHold = Double(c.gateHoldMs.value)
        gateRelease = Double(c.gateReleaseMs.value)
        compKnee = Double(c.compKneeDB.value)
        limiter = c.limiterEnabled.value
        limiterCeiling = Double(c.limiterCeilingDB.value)
        limiterRelease = Double(c.limiterReleaseMs.value)
    }
}

/// Aux bus A/B view model (fader and mute are atomics shared with the render thread).
public final class AuxBusVM: ObservableObject, Identifiable {
    public let index: Int
    public let controls: ChannelControls
    public var id: Int { index }
    public var name: String { "AUX " + ["A", "B", "C", "D"][min(max(index, 0), 3)] }
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
        public var limiter: Float = 0
    }
    public static let silent = Level(l: -120, r: -120, holdL: -120, holdR: -120, gr: 0)
    /// Latest values for code (remote page, preflight). Not published (0.56.0): views watch one
    /// `ChannelMeter` each, so a meter update redraws only that meter, and only when it moved.
    public private(set) var levels: [String: Level] = [:]
    public private(set) var master = MeterModel.silent
    public private(set) var aux: [Level] = []
    private var channelMeters: [String: ChannelMeter] = [:]
    /// Program loudness (LUFS readout and panel), its own object so meters do not redraw it.
    public let lufs = LoudnessMeter()

    /// The observable meter of a mixer channel, `masterKey` or `auxKey(i)`.
    public func meter(_ key: String) -> ChannelMeter {
        if let m = channelMeters[key] { return m }
        let m = ChannelMeter()
        if key == Self.masterKey { m.level = master } else if let l = levels[key] { m.level = l }
        channelMeters[key] = m
        return m
    }
    public static let masterKey = "__master"
    public static func auxKey(_ i: Int) -> String { "__aux\(i)" }

    /// 0.5 dB steps (finer than a meter pixel), anything under -70 dB = silent: steady or silent
    /// channels publish nothing.
    static func quantized(_ l: Level) -> Level {
        func q(_ v: Float) -> Float { v.isFinite && v > -70 ? (v * 2).rounded() / 2 : -120 }
        func g(_ v: Float) -> Float { v.isFinite ? (v * 10).rounded() / 10 : 0 }
        return Level(l: q(l.l), r: q(l.r), holdL: q(l.holdL), holdR: q(l.holdR), gr: g(l.gr), gate: g(l.gate), limiter: g(l.limiter))
    }

    private func publish(_ key: String, _ level: Level) {
        guard let m = channelMeters[key], m.level != level else { return }
        m.level = level
    }
    /// Program loudness in LUFS (momentary, short-term, integrated) and the ducking reduction (dB).
    public struct Loudness: Equatable {
        public var momentary: Float = -.infinity
        public var shortTerm: Float = -.infinity
        public var integrated: Float = -.infinity
        public var duckDB: Float = 0
    }
    public var loudness: Loudness { lufs.loudness }

    func updateLoudness(_ mixer: AudioMixerEngine) {
        func r(_ v: Float) -> Float { v.isFinite ? (v * 10).rounded() / 10 : v }
        let l = Loudness(momentary: r(mixer.lufsMomentary.value), shortTerm: r(mixer.lufsShortTerm.value),
                         integrated: r(mixer.lufsIntegrated.value), duckDB: r(mixer.ducking.reductionDB.value))
        if l != lufs.loudness { lufs.loudness = l }
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
            let level = Self.quantized(Level(l: bl.levelDB, r: br.levelDB, holdL: bl.peakHoldDB, holdR: br.peakHoldDB,
                                             gr: c.gainReductionDB.value, gate: c.gateReductionDB.value,
                                             limiter: c.limiterReductionDB.value))
            publish(key, level)
            return level
        }
        for ch in channels { out[ch.id] = step(ch.id, ch.controls) }
        levels = out
        master = step(Self.masterKey, m)
        aux = auxControls.enumerated().map { step(Self.auxKey($0.offset), $0.element) }
        if ballistics.count > out.count + aux.count + 1 {
            let keep = Set(out.keys).union([Self.masterKey]).union(aux.indices.map(Self.auxKey))
            ballistics = ballistics.filter { keep.contains($0.key) }
        }
    }
}

/// One meter's level; only the views of this meter redraw when it changes (0.56.0).
public final class ChannelMeter: ObservableObject {
    @Published public internal(set) var level = MeterModel.silent
}

public final class LoudnessMeter: ObservableObject {
    @Published public internal(set) var loudness = MeterModel.Loudness()
}

enum HostClockUI {
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}
#endif
