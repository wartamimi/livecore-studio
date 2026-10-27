/// AAC helpers: AudioSpecificConfig (ISO/IEC 14496-3) and ADTS parsing.
public enum AAC {
    public static let sampleRates: [Int] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
                                            16000, 12000, 11025, 8000, 7350]

    public static func frequencyIndex(_ rate: Int) -> Int? { sampleRates.firstIndex(of: rate) }

    /// 2-byte AudioSpecificConfig for AAC-LC (object type 2).
    public static func audioSpecificConfig(sampleRate: Int, channels: Int, objectType: Int = 2) -> [UInt8] {
        let fi = frequencyIndex(sampleRate) ?? 3
        let v = UInt16(objectType & 0x1F) << 11 | UInt16(fi & 0xF) << 7 | UInt16(channels & 0xF) << 3
        return [UInt8(v >> 8), UInt8(v & 0xFF)]
    }

    public struct ADTSFrame: Equatable {
        public var sampleRate: Int
        public var channels: Int
        public var objectType: Int
        public var payload: ArraySlice<UInt8>   // raw AAC frame, ADTS header removed
    }

    /// Splits an ADTS stream into raw AAC frames.
    public static func parseADTS(_ data: [UInt8]) throws -> [ADTSFrame] {
        var frames: [ADTSFrame] = []
        var i = 0
        while i + 7 <= data.count {
            guard data[i] == 0xFF, data[i + 1] & 0xF0 == 0xF0 else {
                throw ByteReaderError.malformed("ADTS sync lost at \(i)")
            }
            let protectionAbsent = data[i + 1] & 1 == 1
            let objectType = Int(data[i + 2] >> 6) + 1
            let fi = Int((data[i + 2] >> 2) & 0xF)
            let channels = Int((data[i + 2] & 1) << 2 | data[i + 3] >> 6)
            let frameLen = Int(data[i + 3] & 0x3) << 11 | Int(data[i + 4]) << 3 | Int(data[i + 5] >> 5)
            let header = protectionAbsent ? 7 : 9
            guard frameLen >= header, i + frameLen <= data.count, fi < sampleRates.count else {
                throw ByteReaderError.malformed("bad ADTS frame at \(i)")
            }
            frames.append(ADTSFrame(sampleRate: sampleRates[fi], channels: channels, objectType: objectType,
                                    payload: data[(i + header)..<(i + frameLen)]))
            i += frameLen
        }
        return frames
    }
}
