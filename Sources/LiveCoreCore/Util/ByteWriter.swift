/// Big-endian byte builder used by the FLV / AMF0 / RTMP encoders.
public struct ByteWriter {
    public private(set) var bytes: [UInt8]

    public init(reservingCapacity: Int = 256) {
        bytes = []
        bytes.reserveCapacity(reservingCapacity)
    }

    public var count: Int { bytes.count }

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) { bytes.append(UInt8(v >> 8)); bytes.append(UInt8(v & 0xFF)) }
    public mutating func u24(_ v: UInt32) {
        bytes.append(UInt8((v >> 16) & 0xFF)); bytes.append(UInt8((v >> 8) & 0xFF)); bytes.append(UInt8(v & 0xFF))
    }
    public mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(v >> 24)); bytes.append(UInt8((v >> 16) & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF)); bytes.append(UInt8(v & 0xFF))
    }
    public mutating func u32LE(_ v: UInt32) {
        bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF)); bytes.append(UInt8(v >> 24))
    }
    public mutating func i24(_ v: Int32) { u24(UInt32(bitPattern: v) & 0xFF_FFFF) }
    public mutating func f64(_ v: Double) {
        let bits = v.bitPattern
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((bits >> UInt64(shift)) & 0xFF)) }
    }
    public mutating func append<S: Sequence>(_ s: S) where S.Element == UInt8 { bytes.append(contentsOf: s) }
}

public enum ByteReaderError: Error, Equatable {
    case outOfBounds
    case malformed(String)
}

/// Big-endian byte reader over an array slice.
public struct ByteReader {
    public let data: [UInt8]
    public private(set) var offset: Int

    public init(_ data: [UInt8], offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    public var remaining: Int { data.count - offset }
    public var isAtEnd: Bool { offset >= data.count }

    public mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw ByteReaderError.outOfBounds }
        defer { offset += 1 }
        return data[offset]
    }
    public mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw ByteReaderError.outOfBounds }
        defer { offset += 2 }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }
    public mutating func u24() throws -> UInt32 {
        guard remaining >= 3 else { throw ByteReaderError.outOfBounds }
        defer { offset += 3 }
        return UInt32(data[offset]) << 16 | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2])
    }
    public mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw ByteReaderError.outOfBounds }
        defer { offset += 4 }
        return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
    public mutating func u32LE() throws -> UInt32 {
        guard remaining >= 4 else { throw ByteReaderError.outOfBounds }
        defer { offset += 4 }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
    public mutating func f64() throws -> Double {
        guard remaining >= 8 else { throw ByteReaderError.outOfBounds }
        var bits: UInt64 = 0
        for i in 0..<8 { bits = bits << 8 | UInt64(data[offset + i]) }
        offset += 8
        return Double(bitPattern: bits)
    }
    public mutating func bytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, remaining >= n else { throw ByteReaderError.outOfBounds }
        defer { offset += n }
        return Array(data[offset..<offset + n])
    }
    public mutating func skip(_ n: Int) throws {
        guard n >= 0, remaining >= n else { throw ByteReaderError.outOfBounds }
        offset += n
    }
}
