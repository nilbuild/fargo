import Foundation

enum RTMPHandshake {
    static let version: UInt8 = 3
    static let packetSize = 1536

    static func generateC0C1() -> (data: Data, c1Timestamp: UInt32) {
        var data = Data()

        // C0: version byte
        data.append(version)

        // C1: 1536 bytes
        let timestamp = UInt32(Date().timeIntervalSince1970) & 0xFFFFFFFF
        var ts = timestamp.bigEndian
        data.append(Data(bytes: &ts, count: 4))

        // 4 bytes zero (client doesn't implement version checking)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        // 1528 bytes random data
        var random = Data(count: packetSize - 8)
        for i in 0..<random.count {
            random[i] = UInt8.random(in: 0...255)
        }
        data.append(random)

        return (data, timestamp)
    }

    static func parseS0S1(from data: Data) -> (version: UInt8, s1: Data)? {
        guard data.count >= 1 + packetSize else { return nil }

        let serverVersion = data[0]
        let s1 = data[1..<1+packetSize]

        return (serverVersion, Data(s1))
    }

    static func generateC2(from s1: Data) -> Data {
        guard s1.count == packetSize else { return Data() }

        var c2 = Data()

        // Echo S1's timestamp (first 4 bytes)
        c2.append(s1[0..<4])

        // Our timestamp
        let timestamp = UInt32(Date().timeIntervalSince1970) & 0xFFFFFFFF
        var ts = timestamp.bigEndian
        c2.append(Data(bytes: &ts, count: 4))

        // Echo S1's random data (bytes 8-1535)
        c2.append(s1[8..<packetSize])

        return c2
    }

    // Some servers send garbage S2, so this only checks the length.
    static func validateS2(_ s2: Data) -> Bool {
        s2.count == packetSize
    }

    static let serverResponseSize = 1 + packetSize + packetSize
}
