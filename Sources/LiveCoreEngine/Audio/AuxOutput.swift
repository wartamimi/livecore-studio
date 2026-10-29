#if os(macOS)
import AVFoundation
import AudioToolbox
import CoreAudio
import LiveCoreCore

/// Plays one aux bus on its own output device (headphones of a guest, a virtual device that feeds
/// a call app for mix-minus, ...). The mixer writes the bus into a ring on its render thread;
/// this output's own AVAudioEngine pulls from it on the device's IO thread. The two devices run
/// on different clocks, so the read side uses the same drift compensator as mixer inputs.
final class AuxOutput {
    let deviceID: AudioDeviceID
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    private let ringL: SPSCFloatRingBuffer
    private let ringR: SPSCFloatRingBuffer
    private let drift: DriftCompensator
    private let primeFrames = 2048
    private let maxBufferedFrames = 9600
    // Render-thread-only state
    private var primed = false
    private var flushPending = true
    let underruns = AtomicCounter()

    init(deviceID: AudioDeviceID, ringL: SPSCFloatRingBuffer, ringR: SPSCFloatRingBuffer) throws {
        self.deviceID = deviceID
        self.ringL = ringL
        self.ringR = ringR
        drift = DriftCompensator(targetFill: primeFrames + primeFrames / 2, maxFrames: AudioMixerEngine.maxFrames)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        sourceNode = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, abl in
            self.render(frames: Int(frameCount), output: abl)
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        var dev = deviceID
        guard let au = engine.outputNode.audioUnit else { throw NSError(domain: "LiveCore", code: 20) }
        let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard st == noErr else {
            throw NSError(domain: "LiveCore", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "Cannot select aux output device (OSStatus \(st))"])
        }
        engine.prepare()
        try engine.start()
    }

    func stop() { engine.stop() }

    deinit { engine.stop() }

    /// Real-time (device IO thread): no allocation, no locks, no logging.
    private func render(frames: Int, output: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let out = UnsafeMutableAudioBufferListPointer(output)
        guard frames <= AudioMixerEngine.maxFrames, out.count >= 2,
              let outL = out[0].mData?.assumingMemoryBound(to: Float.self),
              let outR = out[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        let avail = min(ringL.availableToRead, ringR.availableToRead)
        if flushPending {
            // Drop whatever was left in the ring from an earlier session.
            ringL.skip(avail); ringR.skip(avail)
            flushPending = false
            outL.update(repeating: 0, count: frames); outR.update(repeating: 0, count: frames)
            return noErr
        }
        if !primed {
            guard avail >= primeFrames else {
                outL.update(repeating: 0, count: frames); outR.update(repeating: 0, count: frames)
                return noErr
            }
            primed = true
            drift.reset()
        }
        if avail > maxBufferedFrames {
            let excess = avail - primeFrames * 2
            ringL.skip(excess); ringR.skip(excess)
        }
        if !drift.render(ringL: ringL, ringR: ringR, outL: outL, outR: outR, frames: frames) {
            underruns.add()
            primed = false
        }
        return noErr
    }
}
#endif
