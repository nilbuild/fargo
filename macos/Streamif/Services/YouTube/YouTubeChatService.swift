import Foundation

@MainActor @Observable
final class YouTubeChatService {
    private(set) var messages: [YouTubeChatMessage] = []
    private(set) var isPolling = false
    private(set) var error: String?

    private var api: YouTubeAPI?
    private var liveChatId: String?
    private var nextPageToken: String?
    private var pollingTask: Task<Void, Never>?
    private var pollingInterval: TimeInterval = 6.0
    private let maxBufferSize = 100

    // MARK: - Public API

    func start(api: YouTubeAPI, liveChatId: String) {
        guard !isPolling else { return }

        self.api = api
        self.liveChatId = liveChatId
        self.nextPageToken = nil
        self.messages = []
        self.error = nil
        self.isPolling = true

        pollingTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
        liveChatId = nil
        nextPageToken = nil
    }

    func clearMessages() {
        messages = []
    }

    // MARK: - Polling

    private func pollLoop() async {
        guard let api, let liveChatId else { return }

        while !Task.isCancelled && isPolling {
            do {
                let response = try await api.fetchChatMessages(
                    liveChatId: liveChatId,
                    pageToken: nextPageToken
                )

                if let items = response.items {
                    let newMessages = items.compactMap { item -> YouTubeChatMessage? in
                        let type: YouTubeChatMessage.ChatMessageType
                        switch item.snippet.type {
                        case "textMessageEvent": type = .text
                        case "superChatEvent": type = .superChat
                        case "superStickerEvent": type = .superSticker
                        case "newSponsorEvent", "memberMilestoneChatEvent": type = .membership
                        default: type = .unknown
                        }

                        let messageText = item.snippet.displayMessage
                            ?? item.snippet.textMessageDetails?.messageText
                            ?? item.snippet.superChatDetails?.userComment
                            ?? ""

                        if messageText.isEmpty && type == .unknown {
                            return nil
                        }

                        return YouTubeChatMessage(
                            id: item.id,
                            authorName: item.authorDetails?.displayName ?? "Unknown",
                            authorImageUrl: item.authorDetails?.profileImageUrl ?? "",
                            message: messageText,
                            publishedAt: parseDate(item.snippet.publishedAt) ?? Date(),
                            type: type,
                            isModerator: item.authorDetails?.isChatModerator ?? false,
                            isOwner: item.authorDetails?.isChatOwner ?? false,
                            superChatAmount: item.snippet.superChatDetails?.amountDisplayString
                        )
                    }

                    if !newMessages.isEmpty {
                        let existingIds = Set(messages.map(\.id))
                        let truly = newMessages.filter { !existingIds.contains($0.id) }
                        if !truly.isEmpty {
                            messages.append(contentsOf: truly)
                            if messages.count > maxBufferSize {
                                messages.removeFirst(messages.count - maxBufferSize)
                            }
                        }
                    }
                }

                nextPageToken = response.nextPageToken

                if let interval = response.pollingIntervalMillis {
                    pollingInterval = max(3.0, Double(interval) / 1000.0)
                }

                error = nil
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }

            try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
        }
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
