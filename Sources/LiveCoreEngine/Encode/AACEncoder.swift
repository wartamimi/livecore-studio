#if os(macOS)
import AVFoundation
import LiveCoreCore

/// AAC-LC encoder using Apple's AudioToolbox codec through AVAudioConverter.
/// Input: 1024-frame Float32 stereo chunks from `ProgramAudioPump`. Output: one raw AAC frame
/// per chunk (after the encoder's initial priming latency).
public final class AACEncoder {
    public let sampleRate: Double
    public let channels: Int
    public let audioSpecificConfig: [UInt8]
    private let converter: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let aacFormat: AVAudioFormat
    private let pcm: AVAudioPCMBuffer

    public enum AACError: Error, LocalizedError {
        case setup(String)
        public var errorDescription: String? { if case let .setup(s) = self { return "AAC encoder: \(s)" }; return nil }
    }

    public init(sampleRate: Double = 48_000, channels: Int = 2, bitrateKbps: Int) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        guard let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)),
              let aacFormat = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                                       AVNumberOfChannelsKey: channels]),
              let converter = AVAudioConverter(from: pcmFormat, to: aacFormat),
              let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(ProgramAudioPump.chunkFrames))
        else { throw AACError.setup("unsupported format") }
        converter.bitRate = bitrateKbps * 1000
        self.pcmFormat = pcmFormat; self.aacFormat = aacFormat; self.converter = converter; self.pcm = pcm
        audioSpecificConfig = AAC.audioSpecificConfig(sampleRate: Int(sampleRate), channels: channels)
    }

    /// Encodes one chunk. Returns nil while the encoder is still priming.
    public func encode(_ chunk: ProgramAudioPump.Chunk) throws -> [UInt8]? {
        guard let ch = pcm.floatChannelData else { return nil }
        let n = min(chunk.frames, Int(pcm.frameCapacity))
        chunk.left.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: n) }
        chunk.right.withUnsafeBufferPointer { ch[min(1, channels - 1)].update(from: $0.baseAddress!, count: n) }
        pcm.frameLength = AVAudioFrameCount(n)

        let out = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 1, maximumPacketSize: max(converter.maximumOutputPacketSize, 1536))
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return self.pcm
        }
        if status == .error { throw error ?? AACError.setup("conversion failed") }
        guard out.packetCount > 0, out.byteLength > 0 else { return nil }
        let size = out.packetDescriptions.map { Int($0[0].mDataByteSize) } ?? Int(out.byteLength)
        return Array(UnsafeBufferPointer(start: out.data.assumingMemoryBound(to: UInt8.self), count: size))
    }
}
#endif
