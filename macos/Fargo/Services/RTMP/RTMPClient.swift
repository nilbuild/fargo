import Foundation
import CoreMedia
import CoreVideo

final class RTMPClient: @unchecked Sendable {

    struct Config {
        var url: String
        var streamKey: String
        var width: Int = 1920
        var height: Int = 1080
        var videoBitrate: Int = 4_500_000
        var audioBitrate: Int = 160_000
        var fps: Int = 30
        var sampleRate: Int = 48000
        var channels: Int = 2
    }

    enum ClientState: Equatable {
        case disconnected
        case connecting
        case reconnecting(attempt: Int)
        case live
        case error(String)
    }

    struct StreamHealth {
        var droppedFrames: Int = 0
        var totalFrames: Int = 0
        var currentBitrate: Int = 0
        var queuedBytes: Int = 0
        var uptimeSeconds: Double = 0
        var reconnectAttempts: Int = 0

        var dropRate: Double {
            guard totalFrames > 0 else { return 0 }
            return Double(droppedFrames) / Double(totalFrames)
        }
    }

    var onStateChanged: ((ClientState) -> Void)?
    var onHealthUpdated: ((StreamHealth) -> Void)?

    private(set) var state: ClientState = .disconnected {
        didSet {
            if state != oldValue {
                onStateChanged?(state)
            }
        }
    }

    private(set) var health = StreamHealth()

    let config: Config
    let id: UUID

    private var connection = RTMPConnection()
    private var videoEncoder: H264Encoder?
    private var audioEncoder: AACEncoder?

    private var streamStartTime: CMTime = .invalid
    private var hasSentSequenceHeaders = false
    private var liveStartTime: Date?

    private let sendQueue = DispatchQueue(label: "com.fargo.rtmpclient.send", qos: .userInitiated)
    private var queuedBytes: Int = 0
    private let maxQueuedBytes = 5_000_000

    private var currentBitrate: Int
    private var bitrateFloor: Int
    private var bitrateCeiling: Int
    private var lastBitrateAdjust: Date = .distantPast
    private let bitrateAdjustInterval: TimeInterval = 3.0
    private var consecutiveLowQueue: Int = 0
    private var consecutiveHighQueue: Int = 0

    private var reconnectAttempt: Int = 0
    private let maxReconnectAttempts = 10
    private var reconnectTimer: DispatchSourceTimer?
    private var intentionalDisconnect = false

    init(config: Config, id: UUID = UUID()) {
        self.config = config
        self.id = id
        self.currentBitrate = config.videoBitrate
        self.bitrateFloor = config.videoBitrate / 4
        self.bitrateCeiling = config.videoBitrate

        setupConnection()
        setupEncoders()
    }

    deinit {
        intentionalDisconnect = true
        reconnectTimer?.cancel()
        reconnectTimer = nil
        disconnect()
    }

    // MARK: - Setup

    private func setupConnection() {
        connection.onStateChanged = { [weak self] connState in
            guard let self else { return }
            switch connState {
            case .disconnected:
                if !self.intentionalDisconnect {
                    self.scheduleReconnect()
                } else {
                    self.state = .disconnected
                }
            case .connecting, .handshaking, .connected:
                self.state = .connecting
            case .publishing:
                print("[RTMPClient] Publishing accepted, sending metadata")
                self.reconnectAttempt = 0
                self.liveStartTime = Date()
                self.sendMetadataOnly()
                self.state = .live
            case .error(let msg):
                if !self.intentionalDisconnect {
                    print("[RTMPClient] Error: \(msg), will attempt reconnect")
                    self.scheduleReconnect()
                } else {
                    self.state = .error(msg)
                }
            }
        }
    }

    private func setupEncoders() {
        videoEncoder = H264Encoder(
            width: config.width,
            height: config.height,
            bitrate: config.videoBitrate,
            fps: config.fps
        )

        videoEncoder?.onEncodedFrame = { [weak self] sampleBuffer, isKeyframe in
            self?.handleEncodedVideo(sampleBuffer, isKeyframe: isKeyframe)
        }

        audioEncoder = AACEncoder(
            sampleRate: config.sampleRate,
            channels: config.channels,
            bitrate: config.audioBitrate
        )

        audioEncoder?.onEncodedFrame = { [weak self] aacData, presentationTime in
            self?.handleEncodedAudio(aacData, presentationTime: presentationTime)
        }
    }

    // MARK: - Connect / Disconnect

    func connect() {
        connection.connect(url: config.url, streamKey: config.streamKey)
    }

    func disconnect() {
        intentionalDisconnect = true
        reconnectTimer?.cancel()
        reconnectTimer = nil

        if hasSentSequenceHeaders {
            let eos = FLVTag.avcEndOfSequence()
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(
                CMClockGetTime(CMClockGetHostTimeClock()), streamStartTime))
            let timestamp = UInt32(max(0, elapsed * 1000))
            connection.sendVideo(eos, timestamp: timestamp)
        }

        audioEncoder?.flush()

        connection.disconnect()
        videoEncoder?.invalidate()
        videoEncoder = nil
        audioEncoder = nil
        streamStartTime = .invalid
        hasSentSequenceHeaders = false
        queuedBytes = 0
        liveStartTime = nil
    }

    // MARK: - Send Media

    func sendVideo(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard state == .live else { return }

        health.totalFrames += 1

        if queuedBytes > maxQueuedBytes {
            health.droppedFrames += 1
            adjustBitrate()
            return
        }

        adjustBitrate()
        videoEncoder?.encode(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
    }

    func sendAudio(sampleBuffer: CMSampleBuffer) {
        guard state == .live else { return }
        audioEncoder?.encode(sampleBuffer: sampleBuffer)
    }

    // MARK: - Encoded Frame Handlers

    private func handleEncodedVideo(_ sampleBuffer: CMSampleBuffer, isKeyframe: Bool) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        let effectiveDTS = dts.isValid ? dts : pts

        if streamStartTime == .invalid {
            streamStartTime = effectiveDTS
        }

        if !hasSentSequenceHeaders && isKeyframe {
            sendVideoSequenceHeader()
        }

        guard hasSentSequenceHeaders else { return }

        // RTMP timestamps must be DTS-based (monotonically increasing)
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(effectiveDTS, streamStartTime))
        let timestamp = UInt32(max(0, elapsed * 1000))

        // Composition time offset: PTS - DTS (0 when B-frames are disabled)
        var compositionTime: Int32 = 0
        if dts.isValid && dts != pts {
            compositionTime = Int32(CMTimeGetSeconds(CMTimeSubtract(pts, dts)) * 1000)
        }

        guard let flvData = FLVTag.avcNALU(sampleBuffer: sampleBuffer, isKeyframe: isKeyframe,
                                            compositionTimeMs: compositionTime) else { return }

        sendQueue.async { [weak self] in
            self?.queuedBytes += flvData.count
            self?.connection.sendVideo(flvData, timestamp: timestamp)
            self?.queuedBytes -= flvData.count
        }
    }

    private func handleEncodedAudio(_ aacData: Data, presentationTime: CMTime) {
        if streamStartTime == .invalid {
            streamStartTime = presentationTime
        }

        guard hasSentSequenceHeaders else { return }

        // Audio timestamps use PTS (audio has no B-frames)
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(presentationTime, streamStartTime))
        let timestamp = UInt32(max(0, elapsed * 1000))

        let flvData = FLVTag.aacRawFrame(data: aacData, sampleRate: config.sampleRate, channels: config.channels)

        sendQueue.async { [weak self] in
            self?.connection.sendAudio(flvData, timestamp: timestamp)
        }
    }

    // MARK: - Sequence Headers

    // Send metadata as soon as publish is accepted. Servers expect data quickly,
    // so don't wait for SPS/PPS.
    private func sendMetadataOnly() {
        connection.sendMetadata(
            width: config.width, height: config.height,
            videoBitrate: config.videoBitrate, audioBitrate: config.audioBitrate,
            fps: config.fps, sampleRate: config.sampleRate, channels: config.channels
        )

        let audioHeader = FLVTag.aacSequenceHeader(sampleRate: config.sampleRate, channels: config.channels)
        connection.sendAudio(audioHeader, timestamp: 0)

        print("[RTMPClient] Sent metadata + audio header, waiting for first keyframe for video header")
    }

    private func sendVideoSequenceHeader() {
        guard let sps = videoEncoder?.sps, let pps = videoEncoder?.pps else { return }

        let videoHeader = FLVTag.avcSequenceHeader(sps: sps, pps: pps)
        connection.sendVideo(videoHeader, timestamp: 0)

        hasSentSequenceHeaders = true
        print("[RTMPClient] Sent video sequence header (SPS=\(sps.count)b PPS=\(pps.count)b)")
    }

    // MARK: - Force Keyframe

    func forceKeyframe() {
        videoEncoder?.forceKeyframe()
    }

    // MARK: - Adaptive Bitrate

    private func adjustBitrate() {
        let now = Date()
        guard now.timeIntervalSince(lastBitrateAdjust) >= bitrateAdjustInterval else { return }
        lastBitrateAdjust = now

        let queueRatio = Double(queuedBytes) / Double(maxQueuedBytes)

        if queueRatio > 0.7 {
            consecutiveHighQueue += 1
            consecutiveLowQueue = 0
        } else if queueRatio < 0.2 {
            consecutiveLowQueue += 1
            consecutiveHighQueue = 0
        } else {
            consecutiveHighQueue = 0
            consecutiveLowQueue = 0
        }

        var newBitrate = currentBitrate

        if consecutiveHighQueue >= 2 {
            newBitrate = max(bitrateFloor, currentBitrate * 3 / 4)
            consecutiveHighQueue = 0
        } else if consecutiveLowQueue >= 4 {
            newBitrate = min(bitrateCeiling, currentBitrate * 11 / 10)
            consecutiveLowQueue = 0
        }

        if newBitrate != currentBitrate {
            print("[RTMPClient] Adaptive bitrate: \(currentBitrate / 1000)k → \(newBitrate / 1000)k (queue \(Int(queueRatio * 100))%)")
            currentBitrate = newBitrate
            videoEncoder?.updateBitrate(newBitrate)
        }

        emitHealth()
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        guard reconnectAttempt < maxReconnectAttempts else {
            print("[RTMPClient] Max reconnect attempts reached (\(maxReconnectAttempts))")
            state = .error("Connection lost after \(maxReconnectAttempts) retries")
            return
        }

        reconnectAttempt += 1
        health.reconnectAttempts = reconnectAttempt
        let delay = min(30.0, pow(2.0, Double(reconnectAttempt - 1)))
        print("[RTMPClient] Reconnecting in \(Int(delay))s (attempt \(reconnectAttempt)/\(maxReconnectAttempts))")
        state = .reconnecting(attempt: reconnectAttempt)

        streamStartTime = .invalid
        hasSentSequenceHeaders = false
        queuedBytes = 0

        let timer = DispatchSource.makeTimerSource(queue: sendQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.reconnectTimer = nil

            self.connection.disconnect()

            self.connection = RTMPConnection()
            self.setupConnection()
            self.setupEncoders()

            self.connection.connect(url: self.config.url, streamKey: self.config.streamKey)
        }
        timer.resume()
        reconnectTimer = timer
    }

    // MARK: - Health Reporting

    private func emitHealth() {
        health.currentBitrate = currentBitrate
        health.queuedBytes = queuedBytes
        if let start = liveStartTime {
            health.uptimeSeconds = Date().timeIntervalSince(start)
        }
        onHealthUpdated?(health)
    }
}
