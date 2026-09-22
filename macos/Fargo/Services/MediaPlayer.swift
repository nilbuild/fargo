import AVFoundation
import CoreVideo
import CoreMedia

final class MediaPlayer: @unchecked Sendable {
    enum State: Equatable {
        case empty
        case loaded(URL)
        case playing
        case paused
        case finished
    }

    private(set) var state: State = .empty
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CVDisplayLink?
    private let outputQueue = DispatchQueue(label: "com.fargo.mediaplayer", qos: .userInteractive)

    var onFrame: ((CVPixelBuffer) -> Void)?
    var onStateChanged: ((State) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?

    var volume: Float = 1.0 {
        didSet { player?.volume = volume }
    }

    var isLooping = false

    var duration: Double {
        guard let item = player?.currentItem else { return 0 }
        let d = CMTimeGetSeconds(item.duration)
        return d.isNaN ? 0 : d
    }

    var currentTime: Double {
        guard let player else { return 0 }
        let t = CMTimeGetSeconds(player.currentTime())
        return t.isNaN ? 0 : t
    }

    private var latestPixelBuffer: CVPixelBuffer?
    private let lock = NSLock()

    // MARK: - Load

    func load(url: URL) {
        stop()

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)
        videoOutput = output

        let p = AVPlayer(playerItem: item)
        p.volume = volume
        player = p

        NotificationCenter.default.addObserver(
            self, selector: #selector(playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime, object: item
        )

        state = .loaded(url)
        onStateChanged?(state)
    }

    // MARK: - Transport

    func play() {
        guard let player else { return }
        if case .finished = state {
            player.seek(to: .zero)
        }
        player.play()
        startFramePolling()
        state = .playing
        onStateChanged?(state)
    }

    func pause() {
        player?.pause()
        stopFramePolling()
        state = .paused
        onStateChanged?(state)
    }

    func stop() {
        player?.pause()
        stopFramePolling()
        if let item = player?.currentItem, let output = videoOutput {
            item.remove(output)
        }
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        player = nil
        videoOutput = nil
        lock.lock()
        latestPixelBuffer = nil
        lock.unlock()
        state = .empty
        onStateChanged?(state)
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Frame Access

    func latestFrame() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latestPixelBuffer
    }

    // MARK: - Frame Polling

    private var frameTimer: DispatchSourceTimer?

    private func startFramePolling() {
        stopFramePolling()
        let timer = DispatchSource.makeTimerSource(queue: outputQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33)) // ~30fps
        timer.setEventHandler { [weak self] in
            self?.pollFrame()
        }
        timer.resume()
        frameTimer = timer
    }

    private func stopFramePolling() {
        frameTimer?.cancel()
        frameTimer = nil
    }

    private func pollFrame() {
        guard let output = videoOutput, let player else { return }
        let time = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time) else { return }
        guard let pb = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }

        lock.lock()
        latestPixelBuffer = pb
        lock.unlock()

        onFrame?(pb)
    }

    // MARK: - Playback Events

    @objc private func playerDidFinish() {
        if isLooping {
            player?.seek(to: .zero)
            player?.play()
        } else {
            stopFramePolling()
            state = .finished
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onStateChanged?(self.state)
            }
        }
    }

    deinit {
        stop()
    }
}
