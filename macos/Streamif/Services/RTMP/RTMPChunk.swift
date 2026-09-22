import Foundation

enum RTMPChunk {

    // MARK: - Constants

    static let controlStreamId: UInt16 = 2
    static let commandStreamId: UInt16 = 3
    static let audioStreamId: UInt16 = 4
    static let videoStreamId: UInt16 = 5
    static let dataStreamId: UInt16 = 8

    static let typeSetChunkSize: UInt8 = 0x01
    static let typeAbort: UInt8 = 0x02
    static let typeAck: UInt8 = 0x03
    static let typeUserControl: UInt8 = 0x04
    static let typeWindowAckSize: UInt8 = 0x05
    static let typeSetPeerBandwidth: UInt8 = 0x06
    static let typeAudio: UInt8 = 0x08
    static let typeVideo: UInt8 = 0x09
    static let typeDataAMF0: UInt8 = 0x12
    static let typeCommandAMF0: UInt8 = 0x14

    // MARK: - Message

    struct Message {
        var chunkStreamId: UInt16
        var timestamp: UInt32
        var messageTypeId: UInt8
        var messageStreamId: UInt32
        var payload: Data
    }

    // MARK: - Chunk Writer

    struct ChunkStreamState {
        var lastTimestamp: UInt32 = 0
        var lastMessageLength: UInt32 = 0
        var lastMessageTypeId: UInt8 = 0
        var lastMessageStreamId: UInt32 = 0
        var hasSentFirst = false
    }

    static func chunkMessage(
        _ message: Message,
        chunkSize: Int,
        state: inout ChunkStreamState
    ) -> Data {
        var result = Data()
        let payload = message.payload
        var offset = 0

        while offset < payload.count {
            let isFirst = (offset == 0)
            let remaining = payload.count - offset
            let chunkPayloadSize = min(remaining, chunkSize)

            if isFirst {
                let headerData: Data
                if !state.hasSentFirst {
                    headerData = encodeType0Header(message)
                    state.hasSentFirst = true
                } else if message.messageStreamId != state.lastMessageStreamId {
                    headerData = encodeType0Header(message)
                } else if message.payload.count != Int(state.lastMessageLength) || message.messageTypeId != state.lastMessageTypeId {
                    headerData = encodeType1Header(message, prevTimestamp: state.lastTimestamp)
                } else if message.timestamp != state.lastTimestamp {
                    headerData = encodeType2Header(message, prevTimestamp: state.lastTimestamp)
                } else {
                    headerData = encodeType3Header(message.chunkStreamId)
                }

                result.append(headerData)

                state.lastTimestamp = message.timestamp
                state.lastMessageLength = UInt32(payload.count)
                state.lastMessageTypeId = message.messageTypeId
                state.lastMessageStreamId = message.messageStreamId
            } else {
                result.append(encodeType3Header(message.chunkStreamId))
            }

            result.append(payload[offset..<offset+chunkPayloadSize])
            offset += chunkPayloadSize
        }

        return result
    }

    // MARK: - Header Encoding

    private static func encodeType0Header(_ msg: Message) -> Data {
        var data = Data()
        data.append(basicHeader(fmt: 0, csid: msg.chunkStreamId))

        let ts = msg.timestamp < 0xFFFFFF ? msg.timestamp : 0xFFFFFF
        data.append(UInt8((ts >> 16) & 0xFF))
        data.append(UInt8((ts >> 8) & 0xFF))
        data.append(UInt8(ts & 0xFF))

        let len = UInt32(msg.payload.count)
        data.append(UInt8((len >> 16) & 0xFF))
        data.append(UInt8((len >> 8) & 0xFF))
        data.append(UInt8(len & 0xFF))

        data.append(msg.messageTypeId)

        // Message stream ID is little-endian
        let sid = msg.messageStreamId
        data.append(UInt8(sid & 0xFF))
        data.append(UInt8((sid >> 8) & 0xFF))
        data.append(UInt8((sid >> 16) & 0xFF))
        data.append(UInt8((sid >> 24) & 0xFF))

        if msg.timestamp >= 0xFFFFFF {
            var ext = msg.timestamp.bigEndian
            data.append(Data(bytes: &ext, count: 4))
        }

        return data
    }

    private static func encodeType1Header(_ msg: Message, prevTimestamp: UInt32) -> Data {
        var data = Data()
        data.append(basicHeader(fmt: 1, csid: msg.chunkStreamId))

        let delta = msg.timestamp &- prevTimestamp
        let ts = delta < 0xFFFFFF ? delta : 0xFFFFFF
        data.append(UInt8((ts >> 16) & 0xFF))
        data.append(UInt8((ts >> 8) & 0xFF))
        data.append(UInt8(ts & 0xFF))

        let len = UInt32(msg.payload.count)
        data.append(UInt8((len >> 16) & 0xFF))
        data.append(UInt8((len >> 8) & 0xFF))
        data.append(UInt8(len & 0xFF))

        data.append(msg.messageTypeId)

        if delta >= 0xFFFFFF {
            var ext = delta.bigEndian
            data.append(Data(bytes: &ext, count: 4))
        }

        return data
    }

    private static func encodeType2Header(_ msg: Message, prevTimestamp: UInt32) -> Data {
        var data = Data()
        data.append(basicHeader(fmt: 2, csid: msg.chunkStreamId))

        let delta = msg.timestamp &- prevTimestamp
        let ts = delta < 0xFFFFFF ? delta : 0xFFFFFF
        data.append(UInt8((ts >> 16) & 0xFF))
        data.append(UInt8((ts >> 8) & 0xFF))
        data.append(UInt8(ts & 0xFF))

        if delta >= 0xFFFFFF {
            var ext = delta.bigEndian
            data.append(Data(bytes: &ext, count: 4))
        }

        return data
    }

    private static func encodeType3Header(_ csid: UInt16) -> Data {
        var data = Data()
        data.append(basicHeader(fmt: 3, csid: csid))
        return data
    }

    private static func basicHeader(fmt: UInt8, csid: UInt16) -> Data {
        var data = Data()
        if csid < 64 {
            data.append((fmt << 6) | UInt8(csid))
        } else if csid < 320 {
            data.append(fmt << 6) // csid field = 0 means 1-byte extended
            data.append(UInt8(csid - 64))
        } else {
            data.append((fmt << 6) | 1) // csid field = 1 means 2-byte extended
            let extended = csid - 64
            data.append(UInt8(extended & 0xFF))
            data.append(UInt8((extended >> 8) & 0xFF))
        }
        return data
    }

    // MARK: - Protocol Control Messages

    static func setChunkSize(_ size: UInt32) -> Message {
        var payload = Data()
        var big = size.bigEndian
        payload.append(Data(bytes: &big, count: 4))
        return Message(chunkStreamId: controlStreamId, timestamp: 0,
                       messageTypeId: typeSetChunkSize, messageStreamId: 0, payload: payload)
    }

    static func windowAckSize(_ size: UInt32) -> Message {
        var payload = Data()
        var big = size.bigEndian
        payload.append(Data(bytes: &big, count: 4))
        return Message(chunkStreamId: controlStreamId, timestamp: 0,
                       messageTypeId: typeWindowAckSize, messageStreamId: 0, payload: payload)
    }

    static func acknowledgement(_ sequenceNumber: UInt32) -> Message {
        var payload = Data()
        var big = sequenceNumber.bigEndian
        payload.append(Data(bytes: &big, count: 4))
        return Message(chunkStreamId: controlStreamId, timestamp: 0,
                       messageTypeId: typeAck, messageStreamId: 0, payload: payload)
    }

    // MARK: - Chunk Reader

    static func parseMessages(
        from data: Data,
        chunkSize: Int,
        states: inout [UInt16: ChunkStreamState],
        pendingMessages: inout [UInt16: (header: Message, accumulated: Data)],
        maxMessages: Int = Int.max
    ) -> (consumed: Int, messages: [Message]) {
        var offset = 0
        var messages: [Message] = []

        while offset < data.count && messages.count < maxMessages {
            let startOffset = offset

            guard offset < data.count else { break }
            let firstByte = data[offset]
            offset += 1

            let fmt = (firstByte >> 6) & 0x03
            var csid: UInt16

            let csidField = firstByte & 0x3F
            if csidField == 0 {
                guard offset < data.count else { offset = startOffset; break }
                csid = UInt16(data[offset]) + 64
                offset += 1
            } else if csidField == 1 {
                guard offset + 1 < data.count else { offset = startOffset; break }
                csid = UInt16(data[offset]) + UInt16(data[offset+1]) * 256 + 64
                offset += 2
            } else {
                csid = UInt16(csidField)
            }

            let state = states[csid] ?? ChunkStreamState()

            var timestamp: UInt32 = state.lastTimestamp
            var messageLength: UInt32 = state.lastMessageLength
            var messageTypeId: UInt8 = state.lastMessageTypeId
            var messageStreamId: UInt32 = state.lastMessageStreamId

            switch fmt {
            case 0:
                guard offset + 11 <= data.count else { offset = startOffset; break }
                timestamp = UInt32(data[offset]) << 16 | UInt32(data[offset+1]) << 8 | UInt32(data[offset+2])
                offset += 3
                messageLength = UInt32(data[offset]) << 16 | UInt32(data[offset+1]) << 8 | UInt32(data[offset+2])
                offset += 3
                messageTypeId = data[offset]
                offset += 1
                messageStreamId = UInt32(data[offset]) | UInt32(data[offset+1]) << 8 |
                    UInt32(data[offset+2]) << 16 | UInt32(data[offset+3]) << 24
                offset += 4

                if timestamp == 0xFFFFFF {
                    guard offset + 4 <= data.count else { offset = startOffset; break }
                    timestamp = UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16 |
                        UInt32(data[offset+2]) << 8 | UInt32(data[offset+3])
                    offset += 4
                }

            case 1:
                guard offset + 7 <= data.count else { offset = startOffset; break }
                timestamp = state.lastTimestamp &+ (UInt32(data[offset]) << 16 | UInt32(data[offset+1]) << 8 | UInt32(data[offset+2]))
                offset += 3
                messageLength = UInt32(data[offset]) << 16 | UInt32(data[offset+1]) << 8 | UInt32(data[offset+2])
                offset += 3
                messageTypeId = data[offset]
                offset += 1
                messageStreamId = state.lastMessageStreamId

            case 2:
                guard offset + 3 <= data.count else { offset = startOffset; break }
                timestamp = state.lastTimestamp &+ (UInt32(data[offset]) << 16 | UInt32(data[offset+1]) << 8 | UInt32(data[offset+2]))
                offset += 3
                messageLength = state.lastMessageLength
                messageTypeId = state.lastMessageTypeId
                messageStreamId = state.lastMessageStreamId

            case 3:
                timestamp = state.lastTimestamp
                messageLength = state.lastMessageLength
                messageTypeId = state.lastMessageTypeId
                messageStreamId = state.lastMessageStreamId

            default:
                break
                // Unreachable, fmt is a 2-bit field
            }

            let pending = pendingMessages[csid]
            let alreadyReceived = pending?.accumulated.count ?? 0
            let remaining = Int(messageLength) - alreadyReceived
            let toRead = min(remaining, chunkSize)

            guard offset + toRead <= data.count else { offset = startOffset; break }

            let chunkPayload = data[offset..<offset+toRead]
            offset += toRead

            var accumulated = pending?.accumulated ?? Data()
            accumulated.append(chunkPayload)

            var updatedState = state
            updatedState.lastTimestamp = timestamp
            updatedState.lastMessageLength = messageLength
            updatedState.lastMessageTypeId = messageTypeId
            updatedState.lastMessageStreamId = messageStreamId
            updatedState.hasSentFirst = true
            states[csid] = updatedState

            if accumulated.count >= Int(messageLength) {
                messages.append(Message(
                    chunkStreamId: csid,
                    timestamp: timestamp,
                    messageTypeId: messageTypeId,
                    messageStreamId: messageStreamId,
                    payload: accumulated
                ))
                pendingMessages.removeValue(forKey: csid)
            } else {
                pendingMessages[csid] = (
                    header: Message(chunkStreamId: csid, timestamp: timestamp,
                                    messageTypeId: messageTypeId, messageStreamId: messageStreamId, payload: Data()),
                    accumulated: accumulated
                )
            }
        }

        return (consumed: offset, messages: messages)
    }
}
