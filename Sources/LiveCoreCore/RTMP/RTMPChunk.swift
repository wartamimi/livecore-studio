/// RTMP message and chunk stream framing (Adobe RTMP Specification 1.0, sections 5.3 & 6.1).
public struct RTMPMessage: Equatable, Sendable {
    public enum TypeID: UInt8, Sendable {
        case setChunkSize = 1, abort = 2, acknowledgement = 3, userControl = 4
        case windowAckSize = 5, setPeerBandwidth = 6
        case audio = 8, video = 9
        case dataAMF3 = 15, sharedObjectAMF3 = 16, commandAMF3 = 17
        case dataAMF0 = 18, sharedObjectAMF0 = 19, commandAMF0 = 20, aggregate = 22
    }

    public var typeID: UInt8
    public var streamID: UInt32
    public var timestamp: UInt32
    public var payload: [UInt8]

    public init(type: TypeID, streamID: UInt32 = 0, timestamp: UInt32 = 0, payload: [UInt8]) {
        self.typeID = type.rawValue; self.streamID = streamID; self.timestamp = timestamp; self.payload = payload
    }
    public init(rawType: UInt8, streamID: UInt32, timestamp: UInt32, payload: [UInt8]) {
        self.typeID = rawType; self.streamID = streamID; self.timestamp = timestamp; self.payload = payload
    }
    public var type: TypeID? { TypeID(rawValue: typeID) }
}

/// Serializes messages into chunks. Every message starts with a type-0 header (absolute
/// timestamp), continuation chunks use type 3. This is valid per spec and avoids delta
/// bookkeeping bugs at the cost of ~8 bytes per message.
public struct RTMPChunkWriter {
    public private(set) var chunkSize: Int = 128

    public init() {}

    public mutating func setChunkSize(_ size: Int) { chunkSize = max(1, min(size, 0x7FFF_FFFF)) }

    public func encode(_ msg: RTMPMessage, chunkStreamID csid: UInt32) -> [UInt8] {
        precondition(csid >= 2 && csid <= 65599, "invalid chunk stream id")
        let extended = msg.timestamp >= 0xFF_FFFF
        let chunks = max(1, (msg.payload.count + chunkSize - 1) / chunkSize)
        var w = ByteWriter(reservingCapacity: msg.payload.count + 18 + chunks * (4 + (extended ? 4 : 0)))
        writeBasicHeader(&w, fmt: 0, csid: csid)
        w.u24(extended ? 0xFF_FFFF : msg.timestamp)
        w.u24(UInt32(msg.payload.count))
        w.u8(msg.typeID)
        w.u32LE(msg.streamID)
        if extended { w.u32(msg.timestamp) }
        var offset = 0
        while true {
            let n = min(chunkSize, msg.payload.count - offset)
            w.append(msg.payload[offset..<offset + n])
            offset += n
            if offset >= msg.payload.count { break }
            writeBasicHeader(&w, fmt: 3, csid: csid)
            if extended { w.u32(msg.timestamp) }
        }
        return w.bytes
    }

    private func writeBasicHeader(_ w: inout ByteWriter, fmt: UInt8, csid: UInt32) {
        if csid < 64 {
            w.u8(fmt << 6 | UInt8(csid))
        } else if csid < 320 {
            w.u8(fmt << 6); w.u8(UInt8(csid - 64))
        } else {
            w.u8(fmt << 6 | 1); let v = csid - 64; w.u8(UInt8(v & 0xFF)); w.u8(UInt8(v >> 8))
        }
    }
}

/// Incremental de-chunker. Feed raw bytes as they arrive; pull complete messages.
public struct RTMPChunkReader {
    struct StreamState {
        var timestamp: UInt32 = 0
        var timestampDelta: UInt32 = 0
        var length: Int = 0
        var typeID: UInt8 = 0
        var streamID: UInt32 = 0
        var extended = false
        var partial: [UInt8] = []
    }

    public private(set) var chunkSize = 128
    public var maxMessageSize = 16 * 1024 * 1024
    private var buffer: [UInt8] = []
    private var readOffset = 0
    private var streams: [UInt32: StreamState] = [:]

    public init() {}

    public mutating func setChunkSize(_ size: Int) { chunkSize = max(1, size) }

    public mutating func feed(_ bytes: [UInt8]) {
        if readOffset > 64 * 1024 && readOffset > buffer.count / 2 {
            buffer.removeFirst(readOffset); readOffset = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// Returns the next complete message, or nil if more bytes are needed.
    public mutating func next() throws -> RTMPMessage? {
        while true {
            var r = ByteReader(buffer, offset: readOffset)
            guard let result = try readChunk(&r) else { return nil }   // incomplete chunk: wait
            readOffset = r.offset
            if let msg = result { return msg }
            // chunk consumed but message not yet complete: continue
        }
    }

    /// nil = need more data; .some(nil) = a chunk was consumed; .some(msg) = message completed.
    private mutating func readChunk(_ r: inout ByteReader) throws -> RTMPMessage?? {
        guard r.remaining >= 1 else { return nil }
        let b0 = try r.u8()
        let fmt = b0 >> 6
        var csid = UInt32(b0 & 0x3F)
        if csid == 0 {
            guard r.remaining >= 1 else { return nil }
            csid = UInt32(try r.u8()) + 64
        } else if csid == 1 {
            guard r.remaining >= 2 else { return nil }
            let lo = UInt32(try r.u8()), hi = UInt32(try r.u8())
            csid = hi << 8 + lo + 64
        }
        var st = streams[csid] ?? StreamState()
        let headerLen = [11, 7, 3, 0][Int(fmt)]
        guard r.remaining >= headerLen else { return nil }
        var tsField: UInt32 = 0
        switch fmt {
        case 0:
            tsField = try r.u24()
            st.length = Int(try r.u24())
            st.typeID = try r.u8()
            st.streamID = try r.u32LE()
        case 1:
            tsField = try r.u24()
            st.length = Int(try r.u24())
            st.typeID = try r.u8()
        case 2:
            tsField = try r.u24()
        default:
            break
        }
        if fmt != 3 { st.extended = tsField == 0xFF_FFFF }
        var extTs: UInt32 = 0
        if st.extended {
            guard r.remaining >= 4 else { return nil }
            extTs = try r.u32()
        }
        guard st.length <= maxMessageSize else { throw ByteReaderError.malformed("RTMP message too large: \(st.length)") }

        let startingNewMessage = st.partial.isEmpty
        if startingNewMessage {
            let value = st.extended ? extTs : tsField
            switch fmt {
            case 0: st.timestamp = value; st.timestampDelta = 0
            case 1, 2: st.timestampDelta = value; st.timestamp &+= value
            default: if st.length > 0 { st.timestamp &+= st.timestampDelta } // type 3 starting a new message
            }
            st.partial.reserveCapacity(st.length)
        }
        let need = min(chunkSize, st.length - st.partial.count)
        guard r.remaining >= need else { return nil }
        st.partial.append(contentsOf: try r.bytes(need))

        if st.partial.count >= st.length {
            let msg = RTMPMessage(rawType: st.typeID, streamID: st.streamID, timestamp: st.timestamp, payload: st.partial)
            st.partial = []
            streams[csid] = st
            if msg.type == .setChunkSize, msg.payload.count >= 4 {
                var pr = ByteReader(msg.payload)
                chunkSize = Int(try pr.u32() & 0x7FFF_FFFF)
            }
            return .some(msg)
        }
        streams[csid] = st
        return .some(nil)
    }
}
