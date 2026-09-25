import Foundation

struct ViewerSample: Identifiable {
    let date: Date
    let viewers: Int

    var id: Date { date }
}

struct ChatterCount: Identifiable {
    let name: String
    let count: Int

    var id: String { name }
}

/// What happened during one stream, shown once the stream ends.
struct StreamSummary: Identifiable {
    let id = UUID()
    let startedAt: Date
    let endedAt: Date
    let viewerSamples: [ViewerSample]
    let messageCount: Int
    let chatterCount: Int
    let topChatters: [ChatterCount]
    let checklistDone: Int
    let checklistTotal: Int

    var duration: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }

    var peakViewers: Int? {
        viewerSamples.map(\.viewers).max()
    }

    var averageViewers: Int? {
        if viewerSamples.isEmpty {
            return nil
        }
        let sum = viewerSamples.reduce(0) { $0 + $1.viewers }
        return Int((Double(sum) / Double(viewerSamples.count)).rounded())
    }

    var formattedDuration: String {
        let total = Int(duration)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Plain-text version for the clipboard.
    var plainText: String {
        var lines = [
            "Stream summary, \(startedAt.formatted(date: .abbreviated, time: .shortened))",
            "Duration: \(formattedDuration)",
        ]
        if let peakViewers, let averageViewers {
            lines.append("Peak viewers: \(peakViewers.formatted())")
            lines.append("Average viewers: \(averageViewers.formatted())")
        }
        lines.append("Chat messages: \(messageCount.formatted()) from \(chatterCount.formatted()) chatters")
        if !topChatters.isEmpty {
            let names = topChatters.map { "\($0.name) (\($0.count))" }.joined(separator: ", ")
            lines.append("Top chatters: \(names)")
        }
        if checklistTotal > 0 {
            lines.append("Checklist: \(checklistDone) of \(checklistTotal) done")
        }
        return lines.joined(separator: "\n")
    }
}

/// Collects viewer counts and chat activity while live, and turns them into a summary
/// when the stream ends.
@MainActor
final class StreamSessionTracker {
    private(set) var startedAt: Date?
    private var viewerSamples: [ViewerSample] = []
    private var seenMessageIds: Set<String> = []
    private var messagesByAuthor: [String: Int] = [:]
    private var messageCount = 0

    var isActive: Bool {
        startedAt != nil
    }

    /// Messages already in chat when the stream starts are not counted.
    func begin(existingMessages: [YouTubeChatMessage]) {
        startedAt = Date()
        viewerSamples = []
        seenMessageIds = Set(existingMessages.map(\.id))
        messagesByAuthor = [:]
        messageCount = 0
    }

    func recordViewers(_ viewers: Int, at date: Date) {
        guard isActive else { return }
        viewerSamples.append(ViewerSample(date: date, viewers: viewers))
    }

    func recordMessages(_ messages: [YouTubeChatMessage]) {
        guard isActive else { return }
        for msg in messages where !seenMessageIds.contains(msg.id) {
            seenMessageIds.insert(msg.id)
            messageCount += 1
            messagesByAuthor[msg.authorName, default: 0] += 1
        }
    }

    func finish(checklist: [ChecklistItem]) -> StreamSummary? {
        guard let startedAt else { return nil }
        self.startedAt = nil

        let topChatters = messagesByAuthor
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(5)
            .map { ChatterCount(name: $0.key, count: $0.value) }

        return StreamSummary(
            startedAt: startedAt,
            endedAt: Date(),
            viewerSamples: viewerSamples,
            messageCount: messageCount,
            chatterCount: messagesByAuthor.count,
            topChatters: Array(topChatters),
            checklistDone: checklist.filter(\.isDone).count,
            checklistTotal: checklist.count
        )
    }
}
