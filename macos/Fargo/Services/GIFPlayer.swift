import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

final class GIFPlayer: @unchecked Sendable {
    private struct Frame {
        let image: CGImage
        let duration: TimeInterval
    }

    private var frames: [Frame] = []
    private var currentIndex: Int = 0
    private var _frameVersion: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.fargo.gifplayer", qos: .userInteractive)
    private let lock = NSLock()

    private(set) var isPlaying = false

    var currentFrame: CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty else { return nil }
        return frames[currentIndex].image
    }

    var frameVersion: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _frameVersion
    }

    func load(path: String) -> Bool {
        stop()

        guard let url = CFURLCreateWithFileSystemPath(nil, path as CFString, .cfurlposixPathStyle, false),
              let source = CGImageSourceCreateWithURL(url, nil) else {
            return false
        }

        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return false }

        var loadedFrames: [Frame] = []
        for i in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }

            var delay: TimeInterval = 0.1
            if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
               let gifProps = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                if let d = gifProps[kCGImagePropertyGIFUnclampedDelayTime] as? TimeInterval, d > 0 {
                    delay = d
                } else if let d = gifProps[kCGImagePropertyGIFDelayTime] as? TimeInterval, d > 0 {
                    delay = d
                }
            }

            loadedFrames.append(Frame(image: image, duration: delay))
        }

        guard !loadedFrames.isEmpty else { return false }

        lock.lock()
        frames = loadedFrames
        currentIndex = 0
        lock.unlock()

        startPlayback()
        return true
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isPlaying = false

        lock.lock()
        frames = []
        currentIndex = 0
        lock.unlock()
    }

    private func startPlayback() {
        isPlaying = true
        scheduleNext()
    }

    private func scheduleNext() {
        lock.lock()
        guard !frames.isEmpty else {
            lock.unlock()
            return
        }
        let delay = frames[currentIndex].duration
        lock.unlock()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + delay)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.frames.isEmpty else {
                self.lock.unlock()
                return
            }
            self.currentIndex = (self.currentIndex + 1) % self.frames.count
            self._frameVersion += 1
            self.lock.unlock()
            self.scheduleNext()
        }
        t.resume()
        timer?.cancel()
        timer = t
    }

    static func isGIF(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "gif"
    }

    deinit {
        timer?.cancel()
    }
}
