import Foundation

@MainActor @Observable
final class TwitchChatService {
    private(set) var messages: [YouTubeChatMessage] = []
    private(set) var isConnected = false
    private(set) var error: String?

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sessionDelegate: WebSocketDelegate?
    private var channel: String?
    private let maxBufferSize = 100

    // MARK: - Public API

    func connect(token: String, username: String, channel: String) {
        guard !isConnected else { return }

        self.channel = channel.lowercased()
        self.messages = []
        self.error = nil

        let url = URL(string: "wss://irc-ws.chat.twitch.tv:443")!
        let config = URLSessionConfiguration.default
        let delegate = WebSocketDelegate { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isConnected = true

                self.sendIRC("CAP REQ :twitch.tv/tags twitch.tv/commands")
                self.sendIRC("PASS oauth:\(token)")
                self.sendIRC("NICK \(username.lowercased())")
                self.sendIRC("JOIN #\(self.channel!)")

                self.receiveLoop()
            }
        } onClose: { [weak self] (reason: String?) in
            Task { @MainActor [weak self] in
                guard let self, self.webSocket != nil else { return }
                self.error = reason ?? "Connection failed"
                self.isConnected = false
            }
        }
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.sessionDelegate = delegate
        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()
    }

    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil
        isConnected = false
        channel = nil
    }

    func clearMessages() {
        messages = []
    }

    // MARK: - WebSocket

    private func sendIRC(_ message: String) {
        let msg = URLSessionWebSocketTask.Message.string(message)
        webSocket?.send(msg) { _ in }
    }

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.webSocket != nil else { return }

                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleRawMessage(text)
                    default:
                        break
                    }
                    self.receiveLoop()

                case .failure(let error):
                    if self.isConnected {
                        self.error = error.localizedDescription
                        self.isConnected = false
                    }
                }
            }
        }
    }

    // MARK: - IRC Parsing

    private func handleRawMessage(_ raw: String) {
        let lines = raw.components(separatedBy: "\r\n")
        for line in lines {
            if line.isEmpty { continue }

            if line.hasPrefix("PING") {
                sendIRC("PONG :tmi.twitch.tv")
                continue
            }

            if line.contains("NOTICE") {
                handleAuthFailure(line)
            }

            if line.contains("PRIVMSG") {
                if let chatMessage = parsePRIVMSG(line) {
                    messages.append(chatMessage)
                    if messages.count > maxBufferSize {
                        messages.removeFirst(messages.count - maxBufferSize)
                    }
                }
            }
        }
    }

    private func handleAuthFailure(_ line: String) {
        if line.contains("Login authentication failed") || line.contains("NOTICE * :Login unsuccessful") {
            error = "Twitch authentication failed. Try signing out and back in."
            isConnected = false
            disconnect()
        }
    }

    private func parsePRIVMSG(_ line: String) -> YouTubeChatMessage? {
        // Format: @tags :user!user@user.tmi.twitch.tv PRIVMSG #channel :message
        var tags: [String: String] = [:]
        var remaining = line

        if remaining.hasPrefix("@") {
            remaining.removeFirst()
            if let spaceIdx = remaining.firstIndex(of: " ") {
                let tagString = String(remaining[remaining.startIndex..<spaceIdx])
                remaining = String(remaining[remaining.index(after: spaceIdx)...])

                for pair in tagString.components(separatedBy: ";") {
                    let parts = pair.components(separatedBy: "=")
                    if parts.count == 2 {
                        tags[parts[0]] = parts[1]
                    }
                }
            }
        }

        guard let privmsgRange = remaining.range(of: "PRIVMSG #") else { return nil }
        let afterPrivmsg = remaining[privmsgRange.upperBound...]
        guard let colonIdx = afterPrivmsg.firstIndex(of: ":") else { return nil }
        let messageText = String(afterPrivmsg[afterPrivmsg.index(after: colonIdx)...])

        let displayName = tags["display-name"] ?? "Unknown"
        let messageId = tags["id"] ?? UUID().uuidString
        let isMod = tags["mod"] == "1"
        let badges = tags["badges"] ?? ""
        let isBroadcaster = badges.contains("broadcaster")
        let isSubscriber = badges.contains("subscriber")

        let bitsAmount = tags["bits"]

        let type: YouTubeChatMessage.ChatMessageType
        if bitsAmount != nil {
            type = .superChat
        } else {
            type = .text
        }

        return YouTubeChatMessage(
            id: "twitch_\(messageId)",
            authorName: displayName,
            authorImageUrl: "",
            message: messageText,
            publishedAt: Date(),
            type: type,
            isModerator: isMod,
            isOwner: isBroadcaster,
            superChatAmount: bitsAmount.map { "\($0) bits" }
        )
    }
}

// MARK: - WebSocket Delegate

private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    let onOpen: () -> Void
    let onClose: (String?) -> Void

    init(onOpen: @escaping () -> Void, onClose: @escaping (String?) -> Void) {
        self.onOpen = onOpen
        self.onClose = onClose
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) }
        onClose(reasonString)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            onClose(error.localizedDescription)
        }
    }
}
