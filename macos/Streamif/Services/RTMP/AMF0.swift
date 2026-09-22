import Foundation

enum AMF0 {

    // MARK: - Type Markers

    static let typeNumber: UInt8     = 0x00
    static let typeBoolean: UInt8    = 0x01
    static let typeString: UInt8     = 0x02
    static let typeObject: UInt8     = 0x03
    static let typeNull: UInt8       = 0x05
    static let typeUndefined: UInt8  = 0x06
    static let typeECMAArray: UInt8  = 0x08
    static let typeObjectEnd: UInt8  = 0x09

    // MARK: - AMF0 Value

    enum Value {
        case number(Double)
        case boolean(Bool)
        case string(String)
        case object([(String, Value)])
        case null
        case ecmaArray([(String, Value)])
    }

    // MARK: - Writer

    static func encode(_ values: [Value]) -> Data {
        var data = Data()
        for value in values {
            encode(value, into: &data)
        }
        return data
    }

    static func encode(_ value: Value, into data: inout Data) {
        switch value {
        case .number(let n):
            data.append(typeNumber)
            var big = n.bitPattern.bigEndian
            data.append(Data(bytes: &big, count: 8))

        case .boolean(let b):
            data.append(typeBoolean)
            data.append(b ? 0x01 : 0x00)

        case .string(let s):
            let utf8 = s.utf8
            if utf8.count > 0xFFFF {
                // Long string
                data.append(0x0C)
                var len = UInt32(utf8.count).bigEndian
                data.append(Data(bytes: &len, count: 4))
            } else {
                data.append(typeString)
                var len = UInt16(utf8.count).bigEndian
                data.append(Data(bytes: &len, count: 2))
            }
            data.append(contentsOf: utf8)

        case .object(let pairs):
            data.append(typeObject)
            for (key, val) in pairs {
                encodeString(key, into: &data)
                encode(val, into: &data)
            }
            // Object end marker: 0x00 0x00 0x09
            data.append(contentsOf: [0x00, 0x00, typeObjectEnd])

        case .null:
            data.append(typeNull)

        case .ecmaArray(let pairs):
            data.append(typeECMAArray)
            var count = UInt32(pairs.count).bigEndian
            data.append(Data(bytes: &count, count: 4))
            for (key, val) in pairs {
                encodeString(key, into: &data)
                encode(val, into: &data)
            }
            data.append(contentsOf: [0x00, 0x00, typeObjectEnd])
        }
    }

    private static func encodeString(_ s: String, into data: inout Data) {
        let utf8 = s.utf8
        var len = UInt16(utf8.count).bigEndian
        data.append(Data(bytes: &len, count: 2))
        data.append(contentsOf: utf8)
    }

    // MARK: - Reader

    static func decode(from data: Data) -> [Value] {
        var offset = 0
        var values: [Value] = []
        while offset < data.count {
            if let value = decodeValue(from: data, offset: &offset) {
                values.append(value)
            } else {
                break
            }
        }
        return values
    }

    static func decodeValue(from data: Data, offset: inout Int) -> Value? {
        guard offset < data.count else { return nil }
        let type = data[offset]
        offset += 1

        switch type {
        case typeNumber:
            guard offset + 8 <= data.count else { return nil }
            let bits = readUInt64(from: data, at: offset)
            offset += 8
            return .number(Double(bitPattern: bits))

        case typeBoolean:
            guard offset < data.count else { return nil }
            let val = data[offset] != 0
            offset += 1
            return .boolean(val)

        case typeString:
            guard let s = decodeString(from: data, offset: &offset) else { return nil }
            return .string(s)

        case typeObject:
            var pairs: [(String, Value)] = []
            while offset + 2 < data.count {
                if data[offset] == 0x00 && data[offset+1] == 0x00 && offset + 2 < data.count && data[offset+2] == typeObjectEnd {
                    offset += 3
                    break
                }
                guard let key = decodeString(from: data, offset: &offset),
                      let val = decodeValue(from: data, offset: &offset) else { break }
                pairs.append((key, val))
            }
            return .object(pairs)

        case typeNull, typeUndefined:
            return .null

        case typeECMAArray:
            guard offset + 4 <= data.count else { return nil }
            // skip count (4 bytes)
            offset += 4
            var pairs: [(String, Value)] = []
            while offset + 2 < data.count {
                if data[offset] == 0x00 && data[offset+1] == 0x00 && offset + 2 < data.count && data[offset+2] == typeObjectEnd {
                    offset += 3
                    break
                }
                guard let key = decodeString(from: data, offset: &offset),
                      let val = decodeValue(from: data, offset: &offset) else { break }
                pairs.append((key, val))
            }
            return .ecmaArray(pairs)

        default:
            return nil
        }
    }

    private static func decodeString(from data: Data, offset: inout Int) -> String? {
        guard offset + 2 <= data.count else { return nil }
        let len = Int(readUInt16(from: data, at: offset))
        offset += 2
        guard offset + len <= data.count else { return nil }
        let s = String(data: data[offset..<offset+len], encoding: .utf8)
        offset += len
        return s
    }

    // MARK: - Safe byte reads (no alignment requirements)

    private static func readUInt16(from data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16 |
        UInt32(data[offset+2]) << 8 | UInt32(data[offset+3])
    }

    private static func readUInt64(from data: Data, at offset: Int) -> UInt64 {
        UInt64(data[offset]) << 56 | UInt64(data[offset+1]) << 48 |
        UInt64(data[offset+2]) << 40 | UInt64(data[offset+3]) << 32 |
        UInt64(data[offset+4]) << 24 | UInt64(data[offset+5]) << 16 |
        UInt64(data[offset+6]) << 8 | UInt64(data[offset+7])
    }

    // MARK: - Command Builders

    static func connectCommand(app: String, tcUrl: String) -> Data {
        encode([
            .string("connect"),
            .number(1), // transaction ID
            .object([
                ("app", .string(app)),
                ("flashVer", .string("FMLE/3.0 (compatible; Streamif/1.0)")),
                ("tcUrl", .string(tcUrl)),
                ("fpad", .boolean(false)),
                ("capabilities", .number(239)),
                ("audioCodecs", .number(3191)),
                ("videoCodecs", .number(252)),
                ("videoFunction", .number(1)),
                ("objectEncoding", .number(0)),
            ]),
        ])
    }

    static func createStreamCommand(transactionId: Double) -> Data {
        encode([
            .string("createStream"),
            .number(transactionId),
            .null,
        ])
    }

    static func publishCommand(transactionId: Double, streamKey: String) -> Data {
        encode([
            .string("publish"),
            .number(transactionId),
            .null,
            .string(streamKey),
            .string("live"),
        ])
    }

    static func deleteStreamCommand(transactionId: Double, streamId: Double) -> Data {
        encode([
            .string("deleteStream"),
            .number(transactionId),
            .null,
            .number(streamId),
        ])
    }

    static func metadataCommand(
        width: Int, height: Int,
        videoBitrate: Int, audioBitrate: Int,
        fps: Int, sampleRate: Int, channels: Int
    ) -> Data {
        encode([
            .string("@setDataFrame"),
            .string("onMetaData"),
            .ecmaArray([
                ("duration", .number(0)),
                ("width", .number(Double(width))),
                ("height", .number(Double(height))),
                ("videocodecid", .number(7)), // AVC
                ("videodatarate", .number(Double(videoBitrate) / 1000.0)),
                ("framerate", .number(Double(fps))),
                ("audiocodecid", .number(10)), // AAC
                ("audiodatarate", .number(Double(audioBitrate) / 1000.0)),
                ("audiosamplerate", .number(Double(sampleRate))),
                ("audiosamplesize", .number(16)),
                ("audiochannels", .number(Double(channels))),
                ("stereo", .boolean(channels > 1)),
                ("encoder", .string("Streamif/1.0")),
            ]),
        ])
    }

    // MARK: - Response Helpers

    static func commandName(from values: [Value]) -> String? {
        if case .string(let name) = values.first { return name }
        return nil
    }

    static func transactionId(from values: [Value]) -> Double? {
        if values.count > 1, case .number(let id) = values[1] { return id }
        return nil
    }
}
