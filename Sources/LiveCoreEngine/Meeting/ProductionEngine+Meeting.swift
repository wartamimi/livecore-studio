#if os(macOS)
import CoreVideo
import Foundation
import LiveCoreCore

/// Sends Program to the meeting as our camera: frames are converted to I420 on a utility
/// queue at most `maxFPS`; a frame arriving while the previous one is still converting is
/// dropped (never blocks the render queue).
final class MeetingVideoSender {
    weak var bridge: MeetingBridge?
    var maxFPS = 30.0
    private let queue = DispatchQueue(label: "livecore.meeting.video", qos: .userInitiated)
    private let busy = AtomicBool(false)
    private var last = 0.0
    private let converter = I420Converter()

    func offer(_ pb: CVPixelBuffer) {
        let now = HostClock.now()
        guard now - last >= 1 / maxFPS - 0.002, !busy.value, let bridge, bridge.canSendVideo else { return }
        last = now
        busy.value = true
        queue.async {
            defer { self.busy.value = false }
            self.converter.i420(from: pb) { bridge.sendVideo($0) }
        }
    }
}

/// Mixed meeting audio -> its own mixer channel (Int16 at the SDK's rate -> Float 48 kHz).
final class MeetingAudioIn {
    let channel: MixerChannel
    private var resampler: LinearResampler?
    private var rate = 0
    private var l: [Float] = [], r: [Float] = [], ol: [Float] = [], or: [Float] = []

    init(channel: MixerChannel) { self.channel = channel }

    /// SDK audio thread.
    func write(_ s: UnsafePointer<Int16>, frames: Int, channels: Int, sampleRate: Int) {
        guard frames > 0, channels > 0, sampleRate > 0 else { return }
        if rate != sampleRate { rate = sampleRate; resampler = LinearResampler(inputRate: Double(sampleRate), outputRate: 48_000) }
        guard var rs = resampler else { return }
        if l.count < frames { l = [Float](repeating: 0, count: frames); r = l }
        for i in 0..<frames {
            l[i] = Float(s[i * channels]) / 32768
            r[i] = Float(s[i * channels + (channels > 1 ? 1 : 0)]) / 32768
        }
        if rs.isPassthrough {
            l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in
                channel.ringL.write(lp.baseAddress!, count: frames); channel.ringR.write(rp.baseAddress!, count: frames)
            } }
            return
        }
        let cap = rs.maxOutputFrames(forInput: frames)
        if ol.count < cap { ol = [Float](repeating: 0, count: cap); or = ol }
        let n = l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in
            ol.withUnsafeMutableBufferPointer { olp in or.withUnsafeMutableBufferPointer { orp in
                rs.process(inLeft: lp.baseAddress!, inRight: rp.baseAddress!, inputFrames: frames,
                           outLeft: olp.baseAddress!, outRight: orp.baseAddress!, outputCapacity: cap)
            } }
        } }
        resampler = rs
        ol.withUnsafeBufferPointer { lp in or.withUnsafeBufferPointer { rp in
            channel.ringL.write(lp.baseAddress!, count: n); channel.ringR.write(rp.baseAddress!, count: n)
        } }
    }
}

extension ProductionEngine {
    public static let meetingChannelID = "meeting:mix"

    /// Lazily created bridge; nil when the app was built without the Zoom SDK.
    public var meeting: MeetingBridge? {
        if let b = meetingState.bridge { return b }
        guard let make = MeetingBridgeRegistry.make else { return nil }
        let b = make()
        meetingState.bridge = b
        meetingOut.bridge = b
        let sources = meetingState.sources
        b.onVideoFrame = { userID, frame in sources.read { $0[userID] }?.push(frame) }
        b.onMixedAudio = { [weak self] samples, frames, channels, rate in
            self?.meetingState.audioIn.read { $0 }?.write(samples, frames: frames, channels: channels, sampleRate: rate)
        }
        return b
    }

    /// Adds a participant as a video input (subscribes to their video).
    @discardableResult
    public func addMeetingParticipant(_ p: MeetingParticipant) -> InputID? {
        guard let b = meeting else { return nil }
        if let existing = meetingState.sources.read({ $0[p.id] }) { return existing.id }
        let src = MeetingParticipantSource(id: InputID("meeting-\(p.id)"), userID: p.id, name: p.name.isEmpty ? "Zoom \(p.id)" : p.name)
        meetingState.sources.mutate { $0[p.id] = src }
        add(src)
        b.subscribe(userID: p.id)
        return src.id
    }

    func meetingParticipantRemoved(_ m: MeetingParticipantSource) {
        meetingState.sources.mutate { $0[m.userID] = nil }
        meeting?.unsubscribe(userID: m.userID)
    }

    /// Meeting audio channel in the mixer (created on first use, kept until the meeting ends).
    public func setMeetingAudio(_ on: Bool) {
        if on {
            guard meetingState.audioIn.read({ $0 }) == nil else { return }
            let ch = mixer.addChannel(id: Self.meetingChannelID, name: "Zoom", primeFrames: 2048, maxBufferedFrames: 9600)
            meetingState.audioIn.mutate { $0 = MeetingAudioIn(channel: ch) }
        } else {
            meetingState.audioIn.mutate { $0 = nil }
            mixer.removeChannel(id: Self.meetingChannelID)
        }
        onAudioChannelsChange?()
    }

    /// Program as our camera in the meeting.
    public func setMeetingSendsProgram(_ on: Bool) { setMeetingVideoOutput(on) }

    /// A bus as our microphone in the meeting (nil = off). Usually a mix-minus aux bus so the
    /// meeting does not hear itself.
    public func setMeetingMicBus(_ bus: OutputBus?) {
        audioPump.removeSink("meeting")
        guard let bus, let b = meeting else { return }
        var mono: [Int16] = []
        audioPump.addSink("meeting") { [weak b] chunk in
            guard let b, b.canSendAudio else { return }
            let c = chunk.bus(bus)
            if mono.count != c.frames { mono = [Int16](repeating: 0, count: c.frames) }
            for i in 0..<c.frames {
                let v = max(-1, min(1, (c.left[i] + c.right[i]) * 0.5))
                mono[i] = Int16(v * 32767)
            }
            mono.withUnsafeBufferPointer { b.sendAudio($0.baseAddress!, frames: c.frames) }
        }
    }

    /// Ends everything meeting-related (after leaving or when the meeting ended).
    public func meetingEnded() {
        for id in meetingState.sources.read({ $0.values.map(\.id) }) { removeInput(id) }
        setMeetingAudio(false)
        setMeetingVideoOutput(false)
        audioPump.removeSink("meeting")
    }
}

/// Meeting objects shared with SDK threads.
final class MeetingRuntime {
    var bridge: MeetingBridge?
    let sources = Locked([UInt32: MeetingParticipantSource]())
    let audioIn = Locked<MeetingAudioIn?>(nil)
}
#endif
