import Foundation
import CoreMedia
import CoreVideo

final class StreamManager: @unchecked Sendable {
    private var outputs: [any StreamOutput] = []
    private let lock = NSLock()

    var onStatusChanged: ((StreamStatus) -> Void)?

    // MARK: - Destination Management

    func addDestination(_ output: any StreamOutput) {
        lock.lock()
        outputs.append(output)
        lock.unlock()

        output.onStateChanged = { [weak self] _ in
            self?.updateAggregateStatus()
        }

        output.connect()
    }

    func removeDestination(id: UUID) {
        lock.lock()
        guard let idx = outputs.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let output = outputs.remove(at: idx)
        lock.unlock()

        output.disconnect()
        updateAggregateStatus()
    }

    func removeAll() {
        lock.lock()
        let all = outputs
        outputs.removeAll()
        lock.unlock()

        for output in all {
            output.disconnect()
        }
        updateAggregateStatus()
    }

    var destinations: [any StreamOutput] {
        lock.lock()
        defer { lock.unlock() }
        return outputs
    }

    var isLive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outputs.contains { $0.connectionState == .live }
    }

    var isConnecting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outputs.contains { $0.connectionState == .connecting }
    }

    // MARK: - Media Distribution

    func sendVideo(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        lock.lock()
        let current = outputs
        lock.unlock()

        for output in current {
            output.sendVideo(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
        }
    }

    func sendVideo(fullResBuffer: CVPixelBuffer, streamingBuffer: CVPixelBuffer, presentationTime: CMTime) {
        lock.lock()
        let current = outputs
        lock.unlock()

        for output in current {
            if output.targetHeight > 1080 {
                output.sendVideo(pixelBuffer: fullResBuffer, presentationTime: presentationTime)
            } else {
                output.sendVideo(pixelBuffer: streamingBuffer, presentationTime: presentationTime)
            }
        }
    }

    func sendAudio(sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let current = outputs
        lock.unlock()

        for output in current {
            output.sendAudio(sampleBuffer: sampleBuffer)
        }
    }

    // MARK: - Keyframe

    func forceKeyframe() {
        lock.lock()
        let current = outputs
        lock.unlock()

        for output in current {
            output.forceKeyframe()
        }
    }

    // MARK: - Health

    var aggregateHealth: [UUID: RTMPClient.StreamHealth] {
        lock.lock()
        let current = outputs
        lock.unlock()

        var result: [UUID: RTMPClient.StreamHealth] = [:]
        for output in current {
            result[output.id] = output.streamHealth
        }
        return result
    }

    // MARK: - Status Aggregation

    private func updateAggregateStatus() {
        lock.lock()
        let current = outputs
        lock.unlock()

        let status: StreamStatus
        if current.isEmpty {
            status = .idle
        } else if current.contains(where: { $0.connectionState == .live }) {
            status = .live(startTime: Date())
        } else if current.contains(where: { $0.connectionState == .connecting }) {
            status = .connecting
        } else if current.contains(where: {
            if case .reconnecting = $0.connectionState { return true }
            return false
        }) {
            status = .connecting
        } else if let errorOutput = current.first(where: {
            if case .error = $0.connectionState { return true }
            return false
        }) {
            if case .error(let msg) = errorOutput.connectionState {
                status = .error(msg)
            } else {
                status = .idle
            }
        } else {
            status = .idle
        }

        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?(status)
        }
    }
}
