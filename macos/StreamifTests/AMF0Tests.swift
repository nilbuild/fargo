import Foundation
import Testing

private extension AMF0.Value {
    var asNumber: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var asBool: Bool? {
        if case .boolean(let b) = self { return b }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var pairs: [(String, AMF0.Value)]? {
        switch self {
        case .object(let pairs), .ecmaArray(let pairs): return pairs
        default: return nil
        }
    }
}

private func orderedPairs(of values: [AMF0.Value], at index: Int) throws -> [(String, AMF0.Value)] {
    let value = try #require(values.indices.contains(index) ? values[index] : nil)
    return try #require(value.pairs)
}

private func fieldMap(of values: [AMF0.Value], at index: Int) throws -> [String: AMF0.Value] {
    Dictionary(uniqueKeysWithValues: try orderedPairs(of: values, at: index))
}

@Suite("AMF0 round-trips")
struct AMF0RoundTripTests {

    @Test("numbers survive encode/decode")
    func numberRoundTrip() {
        let inputs: [Double] = [0, 1, -1, 3.5, 1_234_567, -0.000_25, Double(UInt32.max)]
        let decoded = AMF0.decode(from: AMF0.encode(inputs.map { .number($0) }))

        #expect(decoded.count == inputs.count)
        for (value, expected) in zip(decoded, inputs) {
            #expect(value.asNumber == expected)
        }
    }

    @Test("booleans survive encode/decode")
    func booleanRoundTrip() {
        let decoded = AMF0.decode(from: AMF0.encode([.boolean(true), .boolean(false)]))

        #expect(decoded.count == 2)
        #expect(decoded.first?.asBool == true)
        #expect(decoded.last?.asBool == false)
    }

    // AMF0 string lengths are a UTF-8 byte count, not a character count. Getting that
    // wrong desyncs everything after the string.
    @Test("multi-byte strings use a byte length prefix")
    func multiByteStringRoundTrip() {
        let text = "café ☕️ 日本"
        let encoded = AMF0.encode([.string(text), .number(42)])

        let length = Int(encoded[1]) << 8 | Int(encoded[2])
        #expect(length == text.utf8.count)
        #expect(length != text.count)

        let decoded = AMF0.decode(from: encoded)
        #expect(decoded.count == 2)
        #expect(decoded.first?.asString == text)
        #expect(decoded.last?.asNumber == 42)
    }

    // Strings over 64 KiB switch to the long-string marker, which has a 4 byte
    // length instead of 2. The decoder has to read the same shape back.
    @Test("long strings survive encode/decode")
    func longStringRoundTrip() {
        let text = String(repeating: "a", count: 0xFFFF + 1)
        let encoded = AMF0.encode([.string(text), .number(7)])

        #expect(encoded[0] == AMF0.typeLongString)
        let length = Int(encoded[1]) << 24 | Int(encoded[2]) << 16 | Int(encoded[3]) << 8 | Int(encoded[4])
        #expect(length == text.utf8.count)

        let decoded = AMF0.decode(from: encoded)
        #expect(decoded.count == 2)
        #expect(decoded.first?.asString == text)
        #expect(decoded.last?.asNumber == 7)
    }

    @Test("objects preserve key order")
    func objectPreservesKeyOrder() throws {
        let value = AMF0.Value.object([
            ("zeta", .string("z")),
            ("alpha", .number(1)),
            ("mid", .boolean(true)),
            ("nothing", .null),
        ])

        let decoded = AMF0.decode(from: AMF0.encode([value]))
        let pairs = try orderedPairs(of: decoded, at: 0)

        #expect(pairs.map(\.0) == ["zeta", "alpha", "mid", "nothing"])
        #expect(pairs[0].1.asString == "z")
        #expect(pairs[1].1.asNumber == 1)
        #expect(pairs[2].1.asBool == true)
        #expect(pairs[3].1.isNull)
    }

    @Test("an empty object decodes to no pairs")
    func emptyObjectRoundTrip() throws {
        let decoded = AMF0.decode(from: AMF0.encode([.object([])]))
        let pairs = try orderedPairs(of: decoded, at: 0)
        #expect(pairs.isEmpty)
    }

    @Test("ECMA arrays carry an associative count prefix")
    func ecmaArrayCountPrefix() throws {
        let value = AMF0.Value.ecmaArray([("a", .number(1)), ("b", .number(2)), ("c", .number(3))])
        let encoded = AMF0.encode([value])

        #expect(encoded[0] == AMF0.typeECMAArray)
        let count = UInt32(encoded[1]) << 24 | UInt32(encoded[2]) << 16 | UInt32(encoded[3]) << 8 | UInt32(encoded[4])
        #expect(count == 3)

        let pairs = try orderedPairs(of: AMF0.decode(from: encoded), at: 0)
        #expect(pairs.map(\.0) == ["a", "b", "c"])
    }
}

@Suite("AMF0 command builders")
struct AMF0CommandTests {

    @Test("connect carries the app name and tcUrl")
    func connectCommand() throws {
        let values = AMF0.decode(from: AMF0.connectCommand(app: "live2", tcUrl: "rtmp://a.rtmp.youtube.com/live2"))

        #expect(AMF0.commandName(from: values) == "connect")
        #expect(AMF0.transactionId(from: values) == 1)

        let command = try fieldMap(of: values, at: 2)
        #expect(command["app"]?.asString == "live2")
        #expect(command["tcUrl"]?.asString == "rtmp://a.rtmp.youtube.com/live2")
        // objectEncoding must stay 0. AMF3 (3) breaks these RTMP ingest endpoints.
        #expect(command["objectEncoding"]?.asNumber == 0)
    }

    @Test("publish sends the stream key and a live type")
    func publishCommand() {
        let values = AMF0.decode(from: AMF0.publishCommand(transactionId: 4, streamKey: "abcd-efgh"))

        #expect(values.count == 5)
        #expect(AMF0.commandName(from: values) == "publish")
        #expect(AMF0.transactionId(from: values) == 4)
        #expect(values[2].isNull)
        #expect(values[3].asString == "abcd-efgh")
        #expect(values[4].asString == "live")
    }

    @Test("createStream and deleteStream keep their transaction ids")
    func streamLifecycleCommands() {
        let create = AMF0.decode(from: AMF0.createStreamCommand(transactionId: 2))
        #expect(AMF0.commandName(from: create) == "createStream")
        #expect(AMF0.transactionId(from: create) == 2)

        let delete = AMF0.decode(from: AMF0.deleteStreamCommand(transactionId: 7, streamId: 1))
        #expect(AMF0.commandName(from: delete) == "deleteStream")
        #expect(AMF0.transactionId(from: delete) == 7)
        #expect(delete.count == 4)
        #expect(delete[3].asNumber == 1)
    }

    @Test("onMetaData reports bitrates in kbps")
    func metadataUsesKilobits() throws {
        let data = AMF0.metadataCommand(
            width: 1920, height: 1080,
            videoBitrate: 8_500_000, audioBitrate: 320_000,
            fps: 60, sampleRate: 48_000, channels: 2
        )
        let values = AMF0.decode(from: data)

        #expect(values.first?.asString == "@setDataFrame")
        #expect(values.count > 1 && values[1].asString == "onMetaData")

        let meta = try fieldMap(of: values, at: 2)
        #expect(meta["width"]?.asNumber == 1920)
        #expect(meta["height"]?.asNumber == 1080)
        #expect(meta["videodatarate"]?.asNumber == 8500)
        #expect(meta["audiodatarate"]?.asNumber == 320)
        #expect(meta["framerate"]?.asNumber == 60)
        #expect(meta["audiosamplerate"]?.asNumber == 48_000)
        #expect(meta["videocodecid"]?.asNumber == 7)
        #expect(meta["audiocodecid"]?.asNumber == 10)
        #expect(meta["stereo"]?.asBool == true)
    }

    @Test("mono metadata clears the stereo flag")
    func monoMetadataIsNotStereo() throws {
        let data = AMF0.metadataCommand(
            width: 1280, height: 720,
            videoBitrate: 4_000_000, audioBitrate: 128_000,
            fps: 30, sampleRate: 44_100, channels: 1
        )
        let meta = try fieldMap(of: AMF0.decode(from: data), at: 2)

        #expect(meta["stereo"]?.asBool == false)
        #expect(meta["audiochannels"]?.asNumber == 1)
    }

    @Test("a server _result decodes into name, transaction and status object")
    func serverResultDecodes() throws {
        let response = AMF0.encode([
            .string("_result"),
            .number(1),
            .null,
            .object([
                ("level", .string("status")),
                ("code", .string("NetConnection.Connect.Success")),
            ]),
        ])
        let values = AMF0.decode(from: response)

        #expect(AMF0.commandName(from: values) == "_result")
        #expect(AMF0.transactionId(from: values) == 1)

        let info = try fieldMap(of: values, at: 3)
        #expect(info["level"]?.asString == "status")
        #expect(info["code"]?.asString == "NetConnection.Connect.Success")
    }
}
