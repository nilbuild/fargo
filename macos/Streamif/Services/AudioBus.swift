import Foundation
import CoreMedia

final class AudioBus {
    typealias Handler = (CMSampleBuffer) -> Void

    private struct Entry {
        let id: UUID
        let handler: Handler
    }

    private let lock = NSLock()
    private var subscribers: [Entry] = []

    @discardableResult
    func subscribe(_ handler: @escaping Handler) -> AudioBusSubscription {
        let id = UUID()
        lock.lock()
        subscribers.append(Entry(id: id, handler: handler))
        lock.unlock()
        return AudioBusSubscription { [weak self] in
            self?.unsubscribe(id)
        }
    }

    func publish(_ sampleBuffer: CMSampleBuffer) {
        // Snapshot under the lock so a concurrent subscribe/cancel can't
        // mutate the array while we're iterating.
        lock.lock()
        let snapshot = subscribers
        lock.unlock()

        for entry in snapshot {
            entry.handler(sampleBuffer)
        }
    }

    private func unsubscribe(_ id: UUID) {
        lock.lock()
        subscribers.removeAll { $0.id == id }
        lock.unlock()
    }
}

final class AudioBusSubscription {
    private let onCancel: () -> Void
    private var cancelled = false
    private let lock = NSLock()

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        lock.lock()
        let alreadyCancelled = cancelled
        cancelled = true
        lock.unlock()
        if !alreadyCancelled {
            onCancel()
        }
    }

    deinit {
        cancel()
    }
}
