/// FLV tag payload builders (Adobe Flash Video File Format Specification v10.1).
/// The same payloads are used as RTMP message bodies (RTMP audio/video messages carry FLV tag data).
public enum FLV {
    public enum TagType: UInt8 { case audio = 8, video = 9, script = 18 }

    public static let videoCodecAVC: Double = 7
    public static let audioCodecAAC: Double = 10

    /// Video tag body. `cts` = composition time offset in ms (0 when B-frames are disabled).
    public static func avcVideoBody(keyframe: Bool, sequenceHeader: Bool, cts: Int32 = 0, data: [UInt8]) -> [UInt8] {
        var w = ByteWriter(reservingCapacity: data.count + 5)
        w.u8((keyframe ? 0x10 : 0x20) | 0x07)
        w.u8(sequenceHeader ? 0 : 1)
        w.i24(sequenceHeader ? 0 : cts)
        w.append(data)
        return w.bytes
    }

    /// Audio tag body for AAC. Header byte 0xAF = AAC, 44 kHz flag (always for AAC), 16-bit, stereo.
    public static func aacAudioBody(sequenceHeader: Bool, data: [UInt8]) -> [UInt8] {
        var w = ByteWriter(reservingCapacity: data.count + 2)
        w.u8(0xAF)
        w.u8(sequenceHeader ? 0 : 1)
        w.append(data)
        return w.bytes
    }

    public struct Metadata: Equatable, Sendable {
        public var width: Int, height: Int, frameRate: Double
        public var videoBitrateKbps: Int, audioBitrateKbps: Int
        public var audioSampleRate: Int, audioChannels: Int
        public var encoder: String
        public init(width: Int, height: Int, frameRate: Double, videoBitrateKbps: Int, audioBitrateKbps: Int,
                    audioSampleRate: Int, audioChannels: Int, encoder: String = "LiveCore Studio") {
            self.width = width; self.height = height; self.frameRate = frameRate
            self.videoBitrateKbps = videoBitrateKbps; self.audioBitrateKbps = audioBitrateKbps
            self.audioSampleRate = audioSampleRate; self.audioChannels = audioChannels; self.encoder = encoder
        }

        var properties: [(String, AMF0Value)] {
            [("duration", .number(0)), ("width", .number(Double(width))), ("height", .number(Double(height))),
             ("videodatarate", .number(Double(videoBitrateKbps))), ("framerate", .number(frameRate)),
             ("videocodecid", .number(FLV.videoCodecAVC)), ("audiodatarate", .number(Double(audioBitrateKbps))),
             ("audiosamplerate", .number(Double(audioSampleRate))), ("audiosamplesize", .number(16)),
             ("stereo", .boolean(audioChannels > 1)), ("audiocodecid", .number(FLV.audioCodecAAC)),
             ("encoder", .string(encoder)), ("filesize", .number(0))]
        }
    }

    /// `onMetaData` script body for FLV files.
    public static func onMetaDataBody(_ m: Metadata) -> [UInt8] {
        AMF0.encode([.string("onMetaData"), .ecmaArray(m.properties)])
    }

    /// `@setDataFrame` body for RTMP publishing (server rewrites it to onMetaData).
    public static func setDataFrameBody(_ m: Metadata) -> [UInt8] {
        AMF0.encode([.string("@setDataFrame"), .string("onMetaData"), .ecmaArray(m.properties)])
    }
}

/// Minimal FLV file writer (header + tags + PreviousTagSize). Used by the RTMP validation tool
/// and tests; the app's local recording uses MP4/MOV via AVAssetWriter.
public struct FLVFileWriter {
    public private(set) var bytes: [UInt8] = []

    public init(hasAudio: Bool = true, hasVideo: Bool = true) {
        var w = ByteWriter()
        w.append(Array("FLV".utf8)); w.u8(1)
        w.u8((hasAudio ? 0x04 : 0) | (hasVideo ? 0x01 : 0))
        w.u32(9)
        w.u32(0) // PreviousTagSize0
        bytes = w.bytes
    }

    public mutating func appendTag(type: FLV.TagType, timestampMs: UInt32, body: [UInt8]) {
        var w = ByteWriter(reservingCapacity: body.count + 15)
        w.u8(type.rawValue)
        w.u24(UInt32(body.count))
        w.u24(timestampMs & 0xFF_FFFF)
        w.u8(UInt8((timestampMs >> 24) & 0xFF))
        w.u24(0) // StreamID
        w.append(body)
        w.u32(UInt32(11 + body.count))
        bytes.append(contentsOf: w.bytes)
    }
}
