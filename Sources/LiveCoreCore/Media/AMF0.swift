/// AMF0 values (Adobe Action Message Format, version 0) as used by RTMP commands and FLV metadata.
/// Spec: "Action Message Format -- AMF 0" (Adobe, 2006).
public indirect enum AMF0Value: Equatable, Sendable {
    case number(Double)
    case boolean(Bool)
    case string(String)
    case object([(String, AMF0Value)])
    case null
    case undefined
    case ecmaArray([(String, AMF0Value)])
    case strictArray([AMF0Value])

    public static func == (a: AMF0Value, b: AMF0Value) -> Bool {
        switch (a, b) {
        case let (.number(x), .number(y)): return x == y
        case let (.boolean(x), .boolean(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case (.null, .null), (.undefined, .undefined): return true
        case let (.object(x), .object(y)), let (.ecmaArray(x), .ecmaArray(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.strictArray(x), .strictArray(y)): return x == y
        default: return false
        }
    }

    /// Property lookup for objects / ECMA arrays.
    public subscript(key: String) -> AMF0Value? {
        switch self {
        case let .object(props), let .ecmaArray(props): return props.first(where: { $0.0 == key })?.1
        default: return nil
        }
    }
    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var numberValue: Double? { if case let .number(n) = self { return n }; return nil }
}

public enum AMF0 {
    enum Marker: UInt8 {
        case number = 0x00, boolean = 0x01, string = 0x02, object = 0x03, null = 0x05,
             undefined = 0x06, ecmaArray = 0x08, objectEnd = 0x09, strictArray = 0x0A, longString = 0x0C
    }

    public static func encode(_ values: [AMF0Value]) -> [UInt8] {
        var w = ByteWriter()
        for v in values { encode(v, into: &w) }
        return w.bytes
    }

    public static func encode(_ value: AMF0Value, into w: inout ByteWriter) {
        switch value {
        case let .number(n): w.u8(Marker.number.rawValue); w.f64(n)
        case let .boolean(b): w.u8(Marker.boolean.rawValue); w.u8(b ? 1 : 0)
        case let .string(s):
            let utf8 = Array(s.utf8)
            if utf8.count > 0xFFFF {
                w.u8(Marker.longString.rawValue); w.u32(UInt32(utf8.count))
            } else {
                w.u8(Marker.string.rawValue); w.u16(UInt16(utf8.count))
            }
            w.append(utf8)
        case let .object(props):
            w.u8(Marker.object.rawValue)
            writeProps(props, into: &w)
        case .null: w.u8(Marker.null.rawValue)
        case .undefined: w.u8(Marker.undefined.rawValue)
        case let .ecmaArray(props):
            w.u8(Marker.ecmaArray.rawValue); w.u32(UInt32(props.count))
            writeProps(props, into: &w)
        case let .strictArray(items):
            w.u8(Marker.strictArray.rawValue); w.u32(UInt32(items.count))
            for i in items { encode(i, into: &w) }
        }
    }

    private static func writeProps(_ props: [(String, AMF0Value)], into w: inout ByteWriter) {
        for (k, v) in props {
            let key = Array(k.utf8)
            w.u16(UInt16(key.count)); w.append(key)
            encode(v, into: &w)
        }
        w.u16(0); w.u8(Marker.objectEnd.rawValue)
    }

    public static func decodeAll(_ bytes: [UInt8]) throws -> [AMF0Value] {
        var r = ByteReader(bytes)
        var out: [AMF0Value] = []
        while !r.isAtEnd { out.append(try decode(&r)) }
        return out
    }

    public static func decode(_ r: inout ByteReader) throws -> AMF0Value {
        let m = try r.u8()
        guard let marker = Marker(rawValue: m) else { throw ByteReaderError.malformed("AMF0 marker 0x\(String(m, radix: 16))") }
        switch marker {
        case .number: return .number(try r.f64())
        case .boolean: return .boolean(try r.u8() != 0)
        case .string: return .string(try readUTF8(&r, count: Int(try r.u16())))
        case .longString: return .string(try readUTF8(&r, count: Int(try r.u32())))
        case .object: return .object(try readProps(&r))
        case .null: return .null
        case .undefined: return .undefined
        case .ecmaArray:
            _ = try r.u32() // approximate count; terminated by object-end like an object
            return .ecmaArray(try readProps(&r))
        case .strictArray:
            let n = Int(try r.u32())
            var items: [AMF0Value] = []
            for _ in 0..<n { items.append(try decode(&r)) }
            return .strictArray(items)
        case .objectEnd: throw ByteReaderError.malformed("unexpected AMF0 object end")
        }
    }

    private static func readUTF8(_ r: inout ByteReader, count: Int) throws -> String {
        String(decoding: try r.bytes(count), as: UTF8.self)
    }

    private static func readProps(_ r: inout ByteReader) throws -> [(String, AMF0Value)] {
        var props: [(String, AMF0Value)] = []
        while true {
            let keyLen = Int(try r.u16())
            if keyLen == 0 {
                let end = try r.u8()
                guard end == Marker.objectEnd.rawValue else { throw ByteReaderError.malformed("missing AMF0 object end") }
                return props
            }
            let key = try readUTF8(&r, count: keyLen)
            props.append((key, try decode(&r)))
        }
    }
}
