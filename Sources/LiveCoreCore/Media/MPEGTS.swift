/// MPEG-2 transport stream muxer for H.264 + AAC (what SRT carries). One program: video on PID
/// 0x100 (also the PCR), audio on PID 0x101, PMT on PID 0x1000. PAT/PMT are repeated before each
/// keyframe and at least every 250 ms so a receiver can join at any time.
public struct MPEGTSMuxer {
    public static let packetSize = 188
    public static let videoPID: UInt16 = 0x100
    public static let audioPID: UInt16 = 0x101
    public static let pmtPID: UInt16 = 0x1000
    /// Presentation times run this far ahead of the PCR (decoder buffer room).
    public static let ptsOffset90k: UInt64 = 63_000

    private var continuity: [UInt16: UInt8] = [:]
    private var lastTables: UInt64?
    public let hasAudio: Bool

    public init(hasAudio: Bool = true) { self.hasAudio = hasAudio }

    // MARK: Elementary streams

    /// One H.264 access unit in AVCC form (4-byte lengths, as VideoToolbox gives it) at `pts90k`.
    /// Adds an access unit delimiter, and SPS/PPS in front of keyframes.
    public mutating func video(avcc: [UInt8], sps: [UInt8], pps: [UInt8], keyframe: Bool, pts90k: UInt64) -> [UInt8] {
        var es: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0]
        if keyframe {
            es += [0, 0, 0, 1] + sps
            es += [0, 0, 0, 1] + pps
        }
        if let nals = try? AVC.splitAVCC(avcc) {
            for n in nals { es += [0, 0, 0, 1]; es.append(contentsOf: n) }
        }
        var out: [UInt8] = []
        if keyframe || lastTables.map({ pts90k &- $0 > 22_500 }) ?? true {
            out += tables()
            lastTables = pts90k
        }
        let pes = Self.pes(streamID: 0xE0, pts: pts90k + Self.ptsOffset90k, payload: es, sizedLength: false)
        out += packetize(pid: Self.videoPID, pes, pcr: pts90k * 300, randomAccess: keyframe)
        return out
    }

    /// One raw AAC frame (no ADTS header) with its AudioSpecificConfig, at `pts90k`.
    public mutating func audio(aac: [UInt8], audioSpecificConfig asc: [UInt8], pts90k: UInt64) -> [UInt8] {
        guard let header = Self.adtsHeader(asc: asc, payloadLength: aac.count) else { return [] }
        let pes = Self.pes(streamID: 0xC0, pts: pts90k + Self.ptsOffset90k, payload: header + aac, sizedLength: true)
        return packetize(pid: Self.audioPID, pes, pcr: nil, randomAccess: false)
    }

    // MARK: Tables

    public mutating func tables() -> [UInt8] {
        // PAT: program 1 → PMT PID.
        var pat: [UInt8] = [0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01,
                            0xE0 | UInt8(Self.pmtPID >> 8), UInt8(Self.pmtPID & 0xFF)]
        pat += Self.be32(Self.crc32(pat))
        // PMT: PCR on video; H.264 (0x1B) and AAC ADTS (0x0F).
        var streams: [UInt8] = [0x1B, 0xE0 | UInt8(Self.videoPID >> 8), UInt8(Self.videoPID & 0xFF), 0xF0, 0x00]
        if hasAudio { streams += [0x0F, 0xE0 | UInt8(Self.audioPID >> 8), UInt8(Self.audioPID & 0xFF), 0xF0, 0x00] }
        let sectionLength = 9 + streams.count + 4
        var pmt: [UInt8] = [0x02, 0xB0 | UInt8(sectionLength >> 8), UInt8(sectionLength & 0xFF), 0x00, 0x01, 0xC1, 0x00, 0x00,
                            0xE0 | UInt8(Self.videoPID >> 8), UInt8(Self.videoPID & 0xFF), 0xF0, 0x00]
        pmt += streams
        pmt += Self.be32(Self.crc32(pmt))
        return section(pid: 0, pat) + section(pid: Self.pmtPID, pmt)
    }

    private mutating func section(pid: UInt16, _ table: [UInt8]) -> [UInt8] {
        var p = header(pid: pid, start: true, adaptation: false)
        p.append(0x00)   // pointer field
        p += table
        p += [UInt8](repeating: 0xFF, count: Self.packetSize - p.count)
        return p
    }

    // MARK: PES and packets

    static func pes(streamID: UInt8, pts: UInt64, payload: [UInt8], sizedLength: Bool) -> [UInt8] {
        let headerData = ptsBytes(pts)
        let length = 3 + headerData.count + payload.count
        let field = sizedLength && length <= 0xFFFF ? length : 0
        var out: [UInt8] = [0, 0, 1, streamID, UInt8(field >> 8), UInt8(field & 0xFF), 0x80, 0x80, UInt8(headerData.count)]
        out += headerData
        out += payload
        return out
    }

    static func ptsBytes(_ pts: UInt64) -> [UInt8] {
        let p = pts & 0x1_FFFF_FFFF
        return [UInt8(0x21 | ((p >> 29) & 0x0E)),
                UInt8((p >> 22) & 0xFF), UInt8(((p >> 14) & 0xFE) | 1),
                UInt8((p >> 7) & 0xFF), UInt8(((p << 1) & 0xFE) | 1)]
    }

    private mutating func header(pid: UInt16, start: Bool, adaptation: Bool) -> [UInt8] {
        let cc = continuity[pid, default: 0]
        continuity[pid] = (cc + 1) & 0x0F
        return [0x47, (start ? 0x40 : 0) | UInt8(pid >> 8), UInt8(pid & 0xFF), (adaptation ? 0x30 : 0x10) | cc]
    }

    private mutating func packetize(pid: UInt16, _ pes: [UInt8], pcr: UInt64?, randomAccess: Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity((pes.count / 184 + 2) * Self.packetSize)
        var offset = 0
        var first = true
        while offset < pes.count {
            // Adaptation field: PCR / random access on the first packet, stuffing on the last.
            var af: [UInt8] = []
            if first, pcr != nil || randomAccess {
                var flags: UInt8 = 0
                if randomAccess { flags |= 0x40 }
                var body: [UInt8] = []
                if let pcr {
                    flags |= 0x10
                    let base = (pcr / 300) & 0x1_FFFF_FFFF, ext = pcr % 300
                    body = [UInt8((base >> 25) & 0xFF), UInt8((base >> 17) & 0xFF), UInt8((base >> 9) & 0xFF),
                            UInt8((base >> 1) & 0xFF), UInt8(((base & 1) << 7) | 0x7E | (ext >> 8)), UInt8(ext & 0xFF)]
                }
                af = [UInt8(1 + body.count), flags] + body
            }
            let room = Self.packetSize - 4 - af.count
            let remaining = pes.count - offset
            if remaining < room {
                // Stuff the adaptation field so the payload fills the packet exactly.
                let stuffing = room - remaining
                if af.isEmpty {
                    af = stuffing == 1 ? [0] : [UInt8(stuffing - 1), 0x00] + [UInt8](repeating: 0xFF, count: stuffing - 2)
                } else {
                    af += [UInt8](repeating: 0xFF, count: stuffing)
                    af[0] = UInt8(af.count - 1)
                }
            }
            let take = min(Self.packetSize - 4 - af.count, remaining)
            out += header(pid: pid, start: first, adaptation: !af.isEmpty)
            out += af
            out.append(contentsOf: pes[offset..<(offset + take)])
            offset += take
            first = false
        }
        return out
    }

    // MARK: Helpers

    /// 7-byte ADTS header for a raw AAC frame described by an AudioSpecificConfig.
    public static func adtsHeader(asc: [UInt8], payloadLength: Int) -> [UInt8]? {
        guard asc.count >= 2 else { return nil }
        let objectType = Int(asc[0] >> 3)
        let frequencyIndex = Int((asc[0] & 0x07) << 1 | asc[1] >> 7)
        let channels = Int((asc[1] >> 3) & 0x0F)
        guard objectType >= 1, objectType <= 4 else { return nil }
        let length = payloadLength + 7
        guard length < 1 << 13 else { return nil }
        return [0xFF, 0xF1,
                UInt8(((objectType - 1) << 6) | (frequencyIndex << 2) | (channels >> 2)),
                UInt8(((channels & 3) << 6) | (length >> 11)),
                UInt8((length >> 3) & 0xFF),
                UInt8(((length & 7) << 5) | 0x1F),
                0xFC]
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    /// CRC-32/MPEG-2 (PSI sections).
    public static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc ^= UInt32(b) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        return crc
    }
}
