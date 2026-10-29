#if os(macOS)
import AVFoundation
import CoreAudio
import Darwin
import Foundation

/// Takes the sound of the app's web inputs into one mixer channel ("Web audio"), like vMix's
/// browser input audio. Uses a Core Audio process tap (macOS 14.2+) on the WebKit processes that
/// LiveCore Studio started; the tapped sound is muted on the speakers, so it is heard only through
/// the mixer. WebKit plays every page's media in one shared process, so all web inputs share the
/// channel. macOS asks once for "System Audio Recording" permission.
@available(macOS 14.2, *)
final class WebAudioCapture {
    private let channel: MixerChannel
    /// Extra process ids reported by the web views (used when the responsibility lookup is missing).
    var knownPIDs: () -> [pid_t] = { [] }
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "livecore.webaudio", qos: .userInteractive)
    private var timer: Timer?
    private var tapped: Set<AudioObjectID> = []
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var reportedError = false

    init(channel: MixerChannel) { self.channel = channel }

    /// Main thread. Looks for WebKit processes every 2 s, since they start when a page first plays.
    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
        teardown()
        tapped = []
    }

    deinit { timer?.invalidate(); teardown() }

    private func refresh() {
        let found = Set(Self.webKitProcessObjects(extraPIDs: knownPIDs()))
        guard found != tapped else { return }
        teardown()
        tapped = found
        guard !found.isEmpty else { return }
        do {
            try build(processes: Array(found))
        } catch {
            teardown()
            if !reportedError {
                reportedError = true
                onError?("Web audio: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Core Audio

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func build(processes: [AudioObjectID]) throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.name = "LiveCore Studio web audio"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else {
            throw Failure(message: "cannot tap the web pages' sound (error \(err)); allow LiveCore Studio in System Settings › Privacy & Security › Screen & System Audio Recording")
        }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let inFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw Failure(message: "cannot read the tap format (error \(err))")
        }
        guard let outputUID = Self.defaultOutputUID() else { throw Failure(message: "no audio output device") }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LiveCore Web Audio",
            kAudioAggregateDeviceUIDKey: "studio.livecore.webaudio.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                              kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard err == noErr else { throw Failure(message: "cannot create the capture device (error \(err))") }
        aggregateID = agg

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw Failure(message: "unsupported audio format") }
        let channel = self.channel
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { _, inData, _, _, _ in
            guard let input = AVAudioPCMBuffer(pcmFormat: inFormat, bufferListNoCopy: inData, deallocator: nil),
                  input.frameLength > 0 else { return }
            let capacity = AVAudioFrameCount(Double(input.frameLength) * 48_000 / inFormat.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            _ = converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return input
            }
            guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { return }
            let n = Int(out.frameLength)
            channel.ringL.write(data[0], count: n)
            channel.ringR.write(data[1], count: n)
        }
        guard err == noErr, let proc else { throw Failure(message: "cannot start capture (error \(err))") }
        procID = proc
        err = AudioDeviceStart(agg, proc)
        guard err == noErr else { throw Failure(message: "cannot start capture (error \(err))") }
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Process lookup

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsiblePID: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    /// Core Audio process objects of the WebKit helpers that belong to this app.
    static func webKitProcessObjects(extraPIDs: [pid_t]) -> [AudioObjectID] {
        let me = getpid()
        let extra = Set(extraPIDs)
        return processObjects().filter { obj in
            guard let pid = pid(of: obj), pid != me else { return false }
            if extra.contains(pid) { return true }
            guard let bundle = bundleID(of: obj), bundle.hasPrefix("com.apple.WebKit"), let responsible = responsiblePID else { return false }
            return responsible(pid) == me
        }
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    private static func pid(of obj: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &pid) == noErr ? pid : nil
    }

    private static func bundleID(of obj: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func defaultOutputUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return nil }
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr, let u = uid else { return nil }
        return u.takeRetainedValue() as String
    }
}
#endif
