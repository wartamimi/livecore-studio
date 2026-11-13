/// MPEG-2 transport stream demuxer for SRT inputs (0.54.0): PAT → PMT → the first video
/// (H.264 / HEVC) and first audio (AAC ADTS) stream of the first program, reassembled into PES
/// payloads with their PTS/DTS. Packets are resynchronised on the 0x47 sync byte; a continuity
/// counter gap marks the access unit being built as damaged.
public final class MPEGTSDemuxer {
    public enum Codec: Equatable, Sendable {
        case h264, hevc, aac, other(UInt8)
        init(streamType: UInt8) {
            switch streamType {
            case 0x1B: self = .h264
            case 0x24: self = .hevc
            case 0x0F: self = .aac
            default: self = .other(streamType)
            }
        }
        public var isVideo: Bool { self == .h264 || self == .hevc }
        public var name: String {
            switch self {
            case .h264: return "H.264"
            case .hevc: return "HEVC"
            case .aac: return "AAC"
            case let .other(t): return "type 0x" + String(t, radix: 16, uppercase: true)
            }
        }
    }

    public struct AccessUnit: Sendable {
        public var codec: Codec
        public var pid: UInt16
        /// 90 kHz, 33-bit.
        public var pts: Int64?
        public var dts: Int64?
        public var data: [UInt8]
        /// Some TS packets of this unit were lost.
        public var damaged: Bool
    }

    public private(set) var pmtPID: UInt16?
    public private(set) var videoPID: UInt16?
    public private(set) var audioPID: UInt16?
    public private(set) var videoCodec: Codec?
    public private(set) var audioCodec: Codec?
    /// Every stream the PMT lists (pid → codec), for the input's signal info.
    public private(set) var streams: [UInt16: Codec] = [:]
    public private(set) var continuityErrors = 0

    private var pending: [UInt8] = []
    private var pes: [UInt16: (data: [UInt8], damaged: Bool)] = [:]
    private var cc: [UInt16: UInt8] = [:]

    public init() {}

    /// Feeds bytes (any split); returns complete access units in stream order.
    public func feed<C: Collection>(_ bytes: C) -> [AccessUnit] where C.Element == UInt8 {
        pending.append(contentsOf: bytes)
        var out: [AccessUnit] = []
        var i = 0
        let n = pending.count
        pending.withUnsafeBufferPointer { b in
            while i + 188 <= n {
                if b[i] != 0x47 { i += 1; continue }
                packet(UnsafeBufferPointer(rebasing: b[i..<(i + 188)]), into: &out)
                i += 188
            }
        }
        pending.removeFirst(i)
        return out
    }

    /// Hands out whatever PES data is still collected (end of stream).
    public func flush() -> [AccessUnit] {
        var out: [AccessUnit] = []
        for pid in pes.keys.sorted() { emit(pid, into: &out) }
        return out
    }

    private func packet(_ p: UnsafeBufferPointer<UInt8>, into out: inout [AccessUnit]) {
        let tei = p[1] & 0x80 != 0
        let pusi = p[1] & 0x40 != 0
        let pid = UInt16(p[1] & 0x1F) << 8 | UInt16(p[2])
        let afc = (p[3] >> 4) & 0x3
        let counter = p[3] & 0x0F
        guard pid != 0x1FFF, !tei else { return }
        var o = 4
        if afc & 0x2 != 0 {
            o += 1 + Int(p[4])
        }
        guard afc & 0x1 != 0, o < 188 else { return }
        // Continuity (only packets with payload advance the counter; duplicates are allowed).
        let discontinuity = afc & 0x2 != 0 && p[4] > 0 && p[5] & 0x80 != 0
        if let last = cc[pid], !discontinuity {
            if counter == last { return }                       // duplicate packet
            if counter != (last + 1) & 0x0F {
                continuityErrors += 1
                if pes[pid] != nil { pes[pid]!.damaged = true }
            }
        }
        cc[pid] = counter
        let payload = UnsafeBufferPointer(rebasing: p[o...])

        if pid == 0 {
            if pusi { parsePAT(payload) }
            return
        }
        if pid == pmtPID {
            if pusi { parsePMT(payload) }
            return
        }
        guard pid == videoPID || pid == audioPID else { return }
        if pusi {
            emit(pid, into: &out)
            pes[pid] = (Array(payload), false)
        } else if pes[pid] != nil {
            pes[pid]!.data.append(contentsOf: payload)
        }
        // Audio PES usually carry their length: hand them out as soon as they are complete.
        if let cur = pes[pid], cur.data.count >= 6 {
            let len = Int(cur.data[4]) << 8 | Int(cur.data[5])
            if len > 0, cur.data.count >= 6 + len { emit(pid, into: &out) }
        }
    }

    private func section(_ payload: UnsafeBufferPointer<UInt8>) -> [UInt8]? {
        guard payload.count >= 1 else { return nil }
        let pointer = Int(payload[0])
        let start = 1 + pointer
        guard start + 3 <= payload.count else { return nil }
        let len = Int(payload[start + 1] & 0x0F) << 8 | Int(payload[start + 2])
        guard start + 3 + len <= payload.count, len >= 9 else { return nil }
        return Array(payload[start..<(start + 3 + len)])
    }

    private func parsePAT(_ payload: UnsafeBufferPointer<UInt8>) {
        guard let s = section(payload), s[0] == 0x00 else { return }
        let end = s.count - 4                      // CRC
        var o = 8
        while o + 4 <= end {
            let program = Int(s[o]) << 8 | Int(s[o + 1])
            let pid = UInt16(s[o + 2] & 0x1F) << 8 | UInt16(s[o + 3])
            if program != 0 {
                if pmtPID != pid { pmtPID = pid; cc[pid] = nil }
                return
            }
            o += 4
        }
    }

    private func parsePMT(_ payload: UnsafeBufferPointer<UInt8>) {
        guard let s = section(payload), s[0] == 0x02 else { return }
        let end = s.count - 4
        let infoLen = Int(s[10] & 0x0F) << 8 | Int(s[11])
        var o = 12 + infoLen
        var found: [UInt16: Codec] = [:]
        var video: (UInt16, Codec)?, audio: (UInt16, Codec)?
        while o + 5 <= end {
            let type = s[o]
            let pid = UInt16(s[o + 1] & 0x1F) << 8 | UInt16(s[o + 2])
            let esLen = Int(s[o + 3] & 0x0F) << 8 | Int(s[o + 4])
            let codec = Codec(streamType: type)
            found[pid] = codec
            if codec.isVideo, video == nil { video = (pid, codec) }
            if codec == .aac, audio == nil { audio = (pid, codec) }
            o += 5 + esLen
        }
        streams = found
        if videoPID != video?.0 { if let v = videoPID { pes[v] = nil }; videoPID = video?.0 }
        if audioPID != audio?.0 { if let a = audioPID { pes[a] = nil }; audioPID = audio?.0 }
        videoCodec = video?.1
        audioCodec = audio?.1
    }

    private func emit(_ pid: UInt16, into out: inout [AccessUnit]) {
        guard let cur = pes.removeValue(forKey: pid) else { return }
        let d = cur.data
        guard d.count >= 9, d[0] == 0, d[1] == 0, d[2] == 1 else { return }
        let flags = d[7]
        let headerLen = Int(d[8])
        let start = 9 + headerLen
        guard start <= d.count else { return }
        var pts: Int64?, dts: Int64?
        if flags & 0x80 != 0, d.count >= 14 { pts = Self.timestamp(d, 9) }
        if flags & 0x40 != 0, d.count >= 19 { dts = Self.timestamp(d, 14) }
        var end = d.count
        let len = Int(d[4]) << 8 | Int(d[5])
        if len > 0 { end = min(end, 6 + len) }
        guard start < end else { return }
        let codec: Codec = pid == videoPID ? (videoCodec ?? .h264) : (audioCodec ?? .aac)
        out.append(AccessUnit(codec: codec, pid: pid, pts: pts, dts: dts ?? pts, data: Array(d[start..<end]), damaged: cur.damaged))
    }

    static func timestamp(_ d: [UInt8], _ o: Int) -> Int64 {
        var v = Int64(d[o] >> 1) & 0x07
        v = v << 15 | (Int64(d[o + 1]) << 7 | Int64(d[o + 2] >> 1))
        v = v << 15 | (Int64(d[o + 3]) << 7 | Int64(d[o + 4] >> 1))
        return v
    }
}

/// AAC in ADTS framing (what MPEG-TS carries): header fields and raw frames.
public enum ADTS {
    public struct Frame: Equatable, Sendable {
        /// 1 = AAC Main, 2 = AAC LC, 3 = SSR, 4 = LTP.
        public var objectType: Int
        public var sampleRate: Int
        public var channels: Int
        /// The raw AAC frame without the ADTS header.
        public var payload: ArraySlice<UInt8>

        /// AudioSpecificConfig (2 bytes) for the decoder.
        public var audioSpecificConfig: [UInt8] {
            let idx = ADTS.rates.firstIndex(of: sampleRate) ?? 4
            return [UInt8(objectType << 3 | idx >> 1), UInt8((idx & 1) << 7 | channels << 3)]
        }
    }

    public static let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// Every ADTS frame in `data` (a PES payload may hold several).
    public static func frames(_ data: [UInt8]) -> [Frame] {
        var out: [Frame] = []
        var o = 0
        while o + 7 <= data.count {
            guard data[o] == 0xFF, data[o + 1] & 0xF6 == 0xF0 else { o += 1; continue }
            let protectionAbsent = data[o + 1] & 0x01 != 0
            let profile = Int(data[o + 2] >> 6)
            let rateIndex = Int((data[o + 2] >> 2) & 0x0F)
            let channels = Int(data[o + 2] & 0x01) << 2 | Int(data[o + 3] >> 6)
            let length = Int(data[o + 3] & 0x03) << 11 | Int(data[o + 4]) << 3 | Int(data[o + 5] >> 5)
            let header = protectionAbsent ? 7 : 9
            guard length >= header, o + length <= data.count, rateIndex < rates.count else { break }
            out.append(Frame(objectType: profile + 1, sampleRate: rates[rateIndex], channels: max(channels, 1),
                             payload: data[(o + header)..<(o + length)]))
            o += length
        }
        return out
    }
}

/// HEVC NAL helpers (H.264 lives in `AVC`).
public enum HEVC {
    @inline(__always) public static func nalType(_ firstByte: UInt8) -> UInt8 { (firstByte >> 1) & 0x3F }
    public static let vps: UInt8 = 32, sps: UInt8 = 33, pps: UInt8 = 34
    /// IRAP pictures (BLA / IDR / CRA): decoding can start here.
    public static func isKeyframe(_ type: UInt8) -> Bool { type >= 16 && type <= 23 }
}
