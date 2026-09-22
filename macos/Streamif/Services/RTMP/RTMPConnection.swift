import Foundation
import Network

final class RTMPConnection: @unchecked Sendable {

    enum State: Equatable {
        case disconnected
        case connecting
        case handshaking
        case connected
        case publishing
        case error(String)
    }

    var onStateChanged: ((State) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var state: State = .disconnected {
        didSet { onStateChanged?(state) }
    }

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.streamif.rtmp", qos: .userInitiated)

    private var chunkSize: Int = 128
    private var serverChunkSize: Int = 128
    private var windowAckSize: UInt32 = 250_000
    private var bytesReceived: UInt32 = 0
    private var lastAckSent: UInt32 = 0
    private var nextTransactionId: Double = 1
    private var messageStreamId: UInt32 = 0

    private var writeStates: [UInt16: RTMPChunk.ChunkStreamState] = [:]
    private let sendLock = NSLock()

    private var readStates: [UInt16: RTMPChunk.ChunkStreamState] = [:]
    private var pendingMessages: [UInt16: (header: RTMPChunk.Message, accumulated: Data)] = [:]
    private var readBuffer = Data()

    private var host: String = ""
    private var port: UInt16 = 1935
    private var app: String = ""
    private var streamKey: String = ""
    private var tcUrl: String = ""
    private var useTLS: Bool = false

    private var pendingCommands: [Double: (AMF0.Value?) -> Void] = [:]

    // MARK: - Connect

    func connect(url: String, streamKey: String) {
        switch state {
        case .disconnected, .error:
            break
        default:
            print("[RTMP] Already connecting/connected, ignoring connect call")
            return
        }

        guard let parsed = parseURL(url, streamKey: streamKey) else {
            state = .error("Invalid RTMP URL")
            return
        }

        self.host = parsed.host
        self.port = parsed.port
        self.app = parsed.app
        self.streamKey = streamKey
        self.tcUrl = parsed.tcUrl
        self.useTLS = parsed.useTLS

        state = .connecting
        resetState()

        let params: NWParameters
        if useTLS {
            params = NWParameters(tls: .init())
        } else {
            params = .tcp
        }
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        // Force IPv4 - some ISPs/routers break IPv6 for long-lived RTMP connections
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }

        let conn = NWConnection(host: .init(host), port: .init(integerLiteral: port), using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] nwState in
            guard let self else { return }
            print("[RTMP] NWConnection state: \(nwState)")
            switch nwState {
            case .ready:
                print("[RTMP] TCP connected to \(self.host):\(self.port), starting handshake")
                self.state = .handshaking
                self.performHandshake()
            case .failed(let error):
                print("[RTMP/\(self.host)] TCP connection failed (state=\(self.state)): \(error)")
                self.state = .error("Connection failed: \(error.localizedDescription)")
            case .cancelled:
                self.state = .disconnected
            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    func disconnect() {
        guard let connection else {
            state = .disconnected
            return
        }

        if state == .publishing {
            // Send FCUnpublish (required by YouTube to end the stream)
            let fcCmd = AMF0.encode([
                .string("FCUnpublish"),
                .number(0),
                .null,
                .string(streamKey),
            ])
            sendMessage(RTMPChunk.Message(
                chunkStreamId: RTMPChunk.commandStreamId, timestamp: 0,
                messageTypeId: RTMPChunk.typeCommandAMF0, messageStreamId: 0,
                payload: fcCmd
            ))

            let cmd = AMF0.deleteStreamCommand(transactionId: nextTransactionId, streamId: Double(messageStreamId))
            sendMessage(RTMPChunk.Message(
                chunkStreamId: RTMPChunk.commandStreamId, timestamp: 0,
                messageTypeId: RTMPChunk.typeCommandAMF0, messageStreamId: messageStreamId,
                payload: cmd
            ))

            // Give the server time to process before closing TCP
            let conn = connection
            queue.asyncAfter(deadline: .now() + 0.5) {
                conn.cancel()
            }
        } else {
            connection.cancel()
        }

        self.connection = nil
        state = .disconnected
    }

    private func resetState() {
        chunkSize = 128
        serverChunkSize = 128
        bytesReceived = 0
        lastAckSent = 0
        nextTransactionId = 1
        messageStreamId = 0
        writeStates = [:]
        readStates = [:]
        pendingMessages = [:]
        readBuffer = Data()
        pendingCommands = [:]
    }

    // MARK: - URL Parsing

    private struct ParsedURL {
        let host: String
        let port: UInt16
        let app: String
        let tcUrl: String
        let useTLS: Bool
    }

    private func parseURL(_ urlString: String, streamKey: String) -> ParsedURL? {
        var cleanUrl = urlString
        let useTLS = cleanUrl.hasPrefix("rtmps://")

        if cleanUrl.hasSuffix("/" + streamKey) {
            cleanUrl = String(cleanUrl.dropLast(streamKey.count + 1))
        }

        guard let url = URL(string: cleanUrl) else { return nil }
        guard let host = url.host else { return nil }

        let port = UInt16(url.port ?? (useTLS ? 443 : 1935))
        let app = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path

        return ParsedURL(host: host, port: port, app: app, tcUrl: cleanUrl, useTLS: useTLS)
    }

    // MARK: - Handshake

    private func performHandshake() {
        let (c0c1, _) = RTMPHandshake.generateC0C1()
        print("[RTMP] Sending C0+C1 (\(c0c1.count) bytes)")

        send(c0c1) { [weak self] in
            print("[RTMP] C0+C1 sent, waiting for S0+S1+S2")
            self?.receiveHandshakeResponse()
        }
    }

    private func receiveHandshakeResponse() {
        // Expect S0 + S1 + S2 = 3073 bytes
        receiveExactly(RTMPHandshake.serverResponseSize) { [weak self] data in
            guard let self else { return }
            guard let data else {
                print("[RTMP] Handshake failed: no response data")
                self.state = .error("Handshake failed: no response")
                return
            }

            print("[RTMP] Received \(data.count) bytes for handshake")

            guard let s0s1 = RTMPHandshake.parseS0S1(from: data) else {
                print("[RTMP] Failed to parse S0/S1")
                self.state = .error("Handshake failed: invalid S0/S1")
                return
            }

            print("[RTMP] Server version: \(s0s1.version), sending C2")

            let c2 = RTMPHandshake.generateC2(from: s0s1.s1)
            self.send(c2) { [weak self] in
                guard let self else { return }
                print("[RTMP] C2 sent, handshake complete. Sending connect command")
                self.state = .connected
                self.startReadLoop()
                self.sendConnect()
            }
        }
    }

    // MARK: - RTMP Commands

    private func sendConnect() {
        // Set chunk size and window ack size before connect
        setChunkSize(4096)
        sendMessage(RTMPChunk.windowAckSize(windowAckSize))

        let txId = nextTransactionId
        nextTransactionId += 1

        let cmd = AMF0.connectCommand(app: app, tcUrl: tcUrl)
        print("[RTMP] Sending connect: app='\(app)' tcUrl='\(tcUrl)' payloadSize=\(cmd.count)")
        sendMessage(RTMPChunk.Message(
            chunkStreamId: RTMPChunk.commandStreamId, timestamp: 0,
            messageTypeId: RTMPChunk.typeCommandAMF0, messageStreamId: 0,
            payload: cmd
        ))

        pendingCommands[txId] = { [weak self] result in
            guard let self else { return }
            print("[RTMP/\(self.host)] Connect succeeded, sending createStream")
            self.sendCreateStream()
        }
    }

    private func setChunkSize(_ size: Int) {
        chunkSize = size
        let msg = RTMPChunk.setChunkSize(UInt32(size))
        sendMessage(msg)
    }

    private func sendCreateStream() {
        // Send releaseStream before createStream (expected by YouTube/Twitch)
        let releaseTxId = nextTransactionId
        nextTransactionId += 1
        let releaseCmd = AMF0.encode([
            .string("releaseStream"),
            .number(releaseTxId),
            .null,
            .string(streamKey),
        ])
        sendMessage(RTMPChunk.Message(
            chunkStreamId: RTMPChunk.commandStreamId, timestamp: 0,
            messageTypeId: RTMPChunk.typeCommandAMF0, messageStreamId: 0,
            payload: releaseCmd
        ))

        // Send FCPublish (required by most ingest servers)
        let fcTxId = nextTransactionId
        nextTransactionId += 1
        let fcCmd = AMF0.encode([
            .string("FCPublish"),
            .number(fcTxId),
            .null,
            .string(streamKey),
        ])
        sendMessage(RTMPChunk.Message(
            chunkStreamId: RTMPChunk.commandStreamId, timestamp: 0,
            messageTypeId: RTMPChunk.typeCommandAMF0, messageStreamId: 0,
            payload: fcCmd
        ))

        let txId = nextTransactionId
        nextTransactionId += 1

        let cmd = AMF0.createStreamCommand(transactionId: txId)
        sendMessage(RTMPChunk.Message(
            chunkStreamId: RTMPChunk.commandStreamId, timestamp: 0,
            messageTypeId: RTMPChunk.typeCommandAMF0, messageStreamId: 0,
            payload: cmd
        ))

        pendingCommands[txId] = { [weak self] result in
            guard let self else { return }
            if case .number(let streamId) = result {
                self.messageStreamId = UInt32(streamId)
            } else {
                self.messageStreamId = 1
            }
            self.sendPublish()
        }
    }

    private func sendPublish() {
        let cmd = AMF0.publishCommand(transactionId: 0, streamKey: streamKey)
        sendMessage(RTMPChunk.Message(
            chunkStreamId: RTMPChunk.commandStreamId, timestamp: 0,
            messageTypeId: RTMPChunk.typeCommandAMF0, messageStreamId: messageStreamId,
            payload: cmd
        ))
    }

    // MARK: - Send Media

    func sendMetadata(width: Int, height: Int, videoBitrate: Int, audioBitrate: Int,
                      fps: Int, sampleRate: Int, channels: Int) {
        let metadata = AMF0.metadataCommand(
            width: width, height: height,
            videoBitrate: videoBitrate, audioBitrate: audioBitrate,
            fps: fps, sampleRate: sampleRate, channels: channels
        )
        sendMessage(RTMPChunk.Message(
            chunkStreamId: RTMPChunk.dataStreamId, timestamp: 0,
            messageTypeId: RTMPChunk.typeDataAMF0, messageStreamId: messageStreamId,
            payload: metadata
        ))
    }

    func sendVideo(_ flvData: Data, timestamp: UInt32) {
        sendMessage(RTMPChunk.Message(
            chunkStreamId: RTMPChunk.videoStreamId, timestamp: timestamp,
            messageTypeId: RTMPChunk.typeVideo, messageStreamId: messageStreamId,
            payload: flvData
        ))
    }

    func sendAudio(_ flvData: Data, timestamp: UInt32) {
        sendMessage(RTMPChunk.Message(
            chunkStreamId: RTMPChunk.audioStreamId, timestamp: timestamp,
            messageTypeId: RTMPChunk.typeAudio, messageStreamId: messageStreamId,
            payload: flvData
        ))
    }

    // MARK: - Message Send/Receive

    private func sendMessage(_ message: RTMPChunk.Message) {
        // Serialize all chunk encoding through the sendLock to prevent
        // concurrent modification of writeStates from multiple threads
        sendLock.lock()
        var state = writeStates[message.chunkStreamId] ?? RTMPChunk.ChunkStreamState()
        let chunked = RTMPChunk.chunkMessage(message, chunkSize: chunkSize, state: &state)
        writeStates[message.chunkStreamId] = state
        sendLock.unlock()
        send(chunked, completion: nil)
    }

    private func send(_ data: Data, completion: (() -> Void)?) {
        guard let connection else {
            print("[RTMP/\(host)] Send failed: no connection")
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                guard let self else { return }
                print("[RTMP/\(self.host)] Send error (\(data.count) bytes): \(error)")
                self.queue.async {
                    self.state = .error("Send failed: \(error.localizedDescription)")
                }
            } else {
                completion?()
            }
        })
    }

    private func receiveExactly(_ count: Int, handler: @escaping (Data?) -> Void) {
        connection?.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            if let error {
                handler(nil)
                return
            }
            handler(data)
        }
    }

    // MARK: - Read Loop

    private func startReadLoop() {
        readFromConnection()
    }

    private func readFromConnection() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data {
                self.readBuffer.append(data)
                self.processReadBuffer()
            }

            if isComplete {
                print("[RTMP/\(self.host)] Server closed read end (state=\(self.state))")
                if self.state != .publishing {
                    self.state = .disconnected
                }
                return
            }

            if let error {
                print("[RTMP] Read error: \(error)")
                return
            }

            self.readFromConnection()
        }
    }

    private func processReadBuffer() {
        // Parse one message at a time so Set Chunk Size takes effect
        // before parsing subsequent messages
        var didWork = true
        while didWork && !readBuffer.isEmpty {
            didWork = false

            let (consumed, messages) = RTMPChunk.parseMessages(
                from: readBuffer, chunkSize: serverChunkSize,
                states: &readStates, pendingMessages: &pendingMessages,
                maxMessages: 1
            )

            if consumed > 0 {
                readBuffer = Data(readBuffer.dropFirst(consumed))
                bytesReceived += UInt32(consumed)
                didWork = true

                if bytesReceived - lastAckSent >= windowAckSize {
                    sendMessage(RTMPChunk.acknowledgement(bytesReceived))
                    lastAckSent = bytesReceived
                }
            }

            for message in messages {
                handleMessage(message)
            }
        }
    }

    private func handleMessage(_ message: RTMPChunk.Message) {
        print("[RTMP/\(host)] msg type=0x\(String(message.messageTypeId, radix: 16)) len=\(message.payload.count) csid=\(message.chunkStreamId)")
        switch message.messageTypeId {
        case RTMPChunk.typeSetChunkSize:
            if message.payload.count >= 4 {
                serverChunkSize = Int(readUInt32(message.payload, 0))
                print("[RTMP/\(host)] Server chunk size changed to \(serverChunkSize)")
            }

        case RTMPChunk.typeWindowAckSize:
            if message.payload.count >= 4 {
                windowAckSize = readUInt32(message.payload, 0)
            }

        case RTMPChunk.typeSetPeerBandwidth:
            if message.payload.count >= 4 {
                let bw = readUInt32(message.payload, 0)
                sendMessage(RTMPChunk.windowAckSize(bw))
            }

        case RTMPChunk.typeCommandAMF0:
            let values = AMF0.decode(from: message.payload)
            handleCommand(values)

        case RTMPChunk.typeUserControl:
            if message.payload.count >= 6 {
                let eventType = UInt16(message.payload[0]) << 8 | UInt16(message.payload[1])
                if eventType == 6 { // PingRequest
                    var pong = Data()
                    var pongType = UInt16(7).bigEndian // PingResponse
                    pong.append(Data(bytes: &pongType, count: 2))
                    pong.append(message.payload[2..<6]) // Echo timestamp
                    sendMessage(RTMPChunk.Message(
                        chunkStreamId: RTMPChunk.controlStreamId, timestamp: 0,
                        messageTypeId: RTMPChunk.typeUserControl, messageStreamId: 0,
                        payload: pong
                    ))
                }
            }

        default:
            break
        }
    }

    private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16 |
               UInt32(data[offset+2]) << 8 | UInt32(data[offset+3])
    }

    private func handleCommand(_ values: [AMF0.Value]) {
        guard let name = AMF0.commandName(from: values) else { return }
        print("[RTMP/\(host)] command: \(name)")

        switch name {
        case "_result":
            if let txId = AMF0.transactionId(from: values),
               let handler = pendingCommands.removeValue(forKey: txId) {
                let result = values.count > 3 ? values[3] : nil
                handler(result)
            }

        case "_error":
            if let txId = AMF0.transactionId(from: values) {
                pendingCommands.removeValue(forKey: txId)
            }
            var errorMsg = "RTMP error"
            if values.count > 3, case .object(let pairs) = values[3] {
                for (key, val) in pairs {
                    if key == "description", case .string(let desc) = val {
                        errorMsg = desc
                        break
                    }
                }
            }
            state = .error(errorMsg)

        case "onStatus":
            // Servers put the code at index 1 or 3, depending on the server
            var code = ""
            var description = ""
            for value in values {
                if case .object(let pairs) = value {
                    for (key, val) in pairs {
                        if key == "code", case .string(let c) = val { code = c }
                        if key == "description", case .string(let d) = val { description = d }
                    }
                }
            }

            print("[RTMP/\(host)] onStatus code='\(code)' desc='\(description)'")

            switch code {
            case "NetStream.Publish.Start":
                state = .publishing

            case "NetStream.Publish.BadName":
                state = .error("Invalid stream key")

            case "NetConnection.Connect.Rejected":
                state = .error("Connection rejected")

            case "NetStream.Publish.Denied":
                state = .error("Publish denied")

            default:
                if code.contains("Error") || code.contains("Failed") || code.contains("Rejected") {
                    state = .error(code)
                }
            }

        case "onBWDone":
            // Respond with _checkbw (some servers require this)
            let checkBw = AMF0.encode([
                .string("_checkbw"),
                .number(0),
                .null,
            ])
            sendMessage(RTMPChunk.Message(
                chunkStreamId: RTMPChunk.commandStreamId, timestamp: 0,
                messageTypeId: RTMPChunk.typeCommandAMF0, messageStreamId: 0,
                payload: checkBw
            ))

        default:
            break
        }
    }
}
