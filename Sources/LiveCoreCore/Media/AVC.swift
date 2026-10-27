/// H.264 helpers: Annex-B <-> AVCC conversion and AVCDecoderConfigurationRecord (ISO/IEC 14496-15).
public enum AVC {
    public enum NALType: UInt8 {
        case slice = 1, idr = 5, sei = 6, sps = 7, pps = 8, aud = 9
    }

    @inline(__always) public static func nalType(_ firstByte: UInt8) -> UInt8 { firstByte & 0x1F }

    /// Splits an Annex-B byte stream (00 00 01 / 00 00 00 01 start codes) into NAL units (without start codes).
    public static func splitAnnexB(_ data: [UInt8]) -> [ArraySlice<UInt8>] {
        var nals: [ArraySlice<UInt8>] = []
        var i = 0
        var start = -1
        let n = data.count
        while i + 2 < n {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    while end > start, data[end - 1] == 0 { end -= 1 } // trailing zero of 4-byte start code
                    if end > start { nals.append(data[start..<end]) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < n { nals.append(data[start..<n]) }
        return nals
    }

    /// Converts NAL units into AVCC (4-byte big-endian length prefixes), as required by FLV and MP4.
    public static func avcc(from nals: [ArraySlice<UInt8>]) -> [UInt8] {
        var w = ByteWriter(reservingCapacity: nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals { w.u32(UInt32(nal.count)); w.append(nal) }
        return w.bytes
    }

    /// Parses AVCC data back into NAL units (used by tests and the recorder sanity checks).
    public static func splitAVCC(_ data: [UInt8], lengthSize: Int = 4) throws -> [ArraySlice<UInt8>] {
        var out: [ArraySlice<UInt8>] = []
        var i = 0
        while i < data.count {
            guard i + lengthSize <= data.count else { throw ByteReaderError.outOfBounds }
            var len = 0
            for k in 0..<lengthSize { len = len << 8 | Int(data[i + k]) }
            i += lengthSize
            guard i + len <= data.count else { throw ByteReaderError.outOfBounds }
            out.append(data[i..<i + len])
            i += len
        }
        return out
    }

    /// Builds an AVCDecoderConfigurationRecord from one SPS and one PPS.
    public static func decoderConfigurationRecord(sps: [UInt8], pps: [UInt8]) -> [UInt8] {
        precondition(sps.count >= 4, "SPS too short")
        var w = ByteWriter()
        w.u8(1)            // configurationVersion
        w.u8(sps[1])       // AVCProfileIndication
        w.u8(sps[2])       // profile_compatibility
        w.u8(sps[3])       // AVCLevelIndication
        w.u8(0xFF)         // 6 bits reserved + lengthSizeMinusOne = 3
        w.u8(0xE1)         // 3 bits reserved + numOfSequenceParameterSets = 1
        w.u16(UInt16(sps.count)); w.append(sps)
        w.u8(1)            // numOfPictureParameterSets
        w.u16(UInt16(pps.count)); w.append(pps)
        let profile = sps[1]
        if profile == 100 || profile == 110 || profile == 122 || profile == 144 {
            // High profiles: chroma_format_idc=1 (4:2:0), 8-bit, no SPS ext.
            w.u8(0xFC | 1); w.u8(0xF8 | 0); w.u8(0xF8 | 0); w.u8(0)
        }
        return w.bytes
    }

    /// Reads the coded width/height from an SPS (handles cropping). Used to validate encoder output.
    public static func spsDimensions(_ spsNAL: [UInt8]) -> PixelSize? {
        let rbsp = removeEmulationPrevention(Array(spsNAL.dropFirst()))
        var br = BitReader(rbsp)
        guard let profile = br.bits(8) else { return nil }
        _ = br.bits(16) // constraint flags + level
        _ = br.ue()     // seq_parameter_set_id
        var chromaFormat: UInt32 = 1
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            chromaFormat = br.ue() ?? 1
            if chromaFormat == 3 { _ = br.bits(1) }
            _ = br.ue(); _ = br.ue(); _ = br.bits(1)
            if br.bits(1) == 1 { // seq_scaling_matrix_present_flag
                for i in 0..<(chromaFormat != 3 ? 8 : 12) where br.bits(1) == 1 {
                    let size = i < 6 ? 16 : 64
                    var last: Int32 = 8, next: Int32 = 8
                    for _ in 0..<size where next != 0 {
                        let delta = br.se() ?? 0
                        next = (last + delta + 256) % 256
                        if next != 0 { last = next }
                    }
                }
            }
        }
        _ = br.ue() // log2_max_frame_num_minus4
        let pocType = br.ue() ?? 0
        if pocType == 0 { _ = br.ue() }
        else if pocType == 1 {
            _ = br.bits(1); _ = br.se(); _ = br.se()
            let n = br.ue() ?? 0
            for _ in 0..<n { _ = br.se() }
        }
        _ = br.ue(); _ = br.bits(1)
        guard let wMbs = br.ue(), let hMapUnits = br.ue(), let frameMbsOnly = br.bits(1) else { return nil }
        if frameMbsOnly == 0 { _ = br.bits(1) }
        _ = br.bits(1)
        var cropL: UInt32 = 0, cropR: UInt32 = 0, cropT: UInt32 = 0, cropB: UInt32 = 0
        if br.bits(1) == 1 {
            cropL = br.ue() ?? 0; cropR = br.ue() ?? 0; cropT = br.ue() ?? 0; cropB = br.ue() ?? 0
        }
        let cropUnitX: UInt32 = chromaFormat == 0 ? 1 : (chromaFormat == 3 ? 1 : 2)
        let cropUnitY: UInt32 = (chromaFormat == 1 ? 2 : 1) * (2 - frameMbsOnly)
        let width = (wMbs + 1) * 16 - (cropL + cropR) * cropUnitX
        let height = (2 - frameMbsOnly) * (hMapUnits + 1) * 16 - (cropT + cropB) * cropUnitY
        return PixelSize(width: Int(width), height: Int(height))
    }

    static func removeEmulationPrevention(_ d: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(d.count)
        var zeros = 0
        for b in d {
            if zeros >= 2 && b == 3 { zeros = 0; continue }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }
}

/// Exp-Golomb bit reader for SPS parsing.
struct BitReader {
    let data: [UInt8]
    var bitPos = 0
    init(_ d: [UInt8]) { data = d }
    mutating func bits(_ n: Int) -> UInt32? {
        var v: UInt32 = 0
        for _ in 0..<n {
            let byte = bitPos >> 3
            guard byte < data.count else { return nil }
            v = v << 1 | UInt32((data[byte] >> (7 - UInt8(bitPos & 7))) & 1)
            bitPos += 1
        }
        return v
    }
    mutating func ue() -> UInt32? {
        var zeros = 0
        while true {
            guard let b = bits(1) else { return nil }
            if b == 1 { break }
            zeros += 1
            if zeros > 31 { return nil }
        }
        guard let rest = bits(zeros) else { return nil }
        return (UInt32(1) << UInt32(zeros)) - 1 + rest
    }
    mutating func se() -> Int32? {
        guard let k = ue() else { return nil }
        return k & 1 == 1 ? Int32((k + 1) / 2) : -Int32(k / 2)
    }
}
