import Foundation

final class YouTubeAPI {
    private let baseUrl = "https://www.googleapis.com/youtube/v3"
    private let auth: YouTubeAuth

    init(auth: YouTubeAuth) {
        self.auth = auth
    }

    // MARK: - Broadcasts

    func listBroadcasts(status: String = "upcoming") async throws -> [YouTubeBroadcast] {
        let token = try await requireToken()

        var components = URLComponents(string: "\(baseUrl)/liveBroadcasts")!
        // liveBroadcasts.list takes exactly one filter. Sending mine alongside
        // broadcastStatus is rejected, and broadcastStatus already scopes the
        // results to the signed-in channel.
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet,status,contentDetails"),
            URLQueryItem(name: "broadcastStatus", value: status),
            URLQueryItem(name: "maxResults", value: "10"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await URLSession.shared.data(for: request)
        try Self.throwIfError(data: data, response: httpResponse)
        let response = try JSONDecoder().decode(YouTubeListResponse<YouTubeBroadcastItem>.self, from: data)

        return response.items?.map { item in
            YouTubeBroadcast(
                id: item.id,
                title: item.snippet?.title ?? "",
                description: item.snippet?.description ?? "",
                privacyStatus: item.status?.privacyStatus ?? "public",
                liveChatId: item.snippet?.liveChatId,
                scheduledStartTime: parseDate(item.snippet?.scheduledStartTime),
                lifecycleStatus: item.status?.lifeCycleStatus
            )
        } ?? []
    }

    func createBroadcast(title: String, description: String, privacyStatus: String = "public") async throws -> YouTubeBroadcast {
        let token = try await requireToken()

        var request = URLRequest(url: URL(string: "\(baseUrl)/liveBroadcasts?part=snippet,status,contentDetails")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "snippet": [
                "title": title,
                "description": description,
                "scheduledStartTime": ISO8601DateFormatter().string(from: Date()),
            ],
            "status": [
                "privacyStatus": privacyStatus,
                "selfDeclaredMadeForKids": false,
            ],
            "contentDetails": [
                "enableAutoStart": true,
                "enableAutoStop": true,
                "enableDvr": true,
                "enableEmbed": true,
                "recordFromStart": true,
                "monitorStream": [
                    "enableMonitorStream": false,
                    "broadcastStreamDelayMs": 0,
                ],
            ],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let item = try JSONDecoder().decode(YouTubeBroadcastItem.self, from: data)

        return YouTubeBroadcast(
            id: item.id,
            title: item.snippet?.title ?? title,
            description: item.snippet?.description ?? description,
            privacyStatus: item.status?.privacyStatus ?? privacyStatus,
            liveChatId: item.snippet?.liveChatId,
            scheduledStartTime: parseDate(item.snippet?.scheduledStartTime),
            lifecycleStatus: item.status?.lifeCycleStatus
        )
    }

    func updateBroadcast(id: String, title: String, description: String, privacyStatus: String = "public") async throws -> YouTubeBroadcast {
        let token = try await requireToken()

        var request = URLRequest(url: URL(string: "\(baseUrl)/liveBroadcasts?part=snippet,status")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "id": id,
            "snippet": [
                "title": title,
                "description": description,
                "scheduledStartTime": ISO8601DateFormatter().string(from: Date()),
            ],
            "status": [
                "privacyStatus": privacyStatus,
            ],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let item = try JSONDecoder().decode(YouTubeBroadcastItem.self, from: data)

        return YouTubeBroadcast(
            id: item.id,
            title: item.snippet?.title ?? title,
            description: item.snippet?.description ?? description,
            privacyStatus: item.status?.privacyStatus ?? privacyStatus,
            liveChatId: item.snippet?.liveChatId,
            scheduledStartTime: parseDate(item.snippet?.scheduledStartTime),
            lifecycleStatus: item.status?.lifeCycleStatus
        )
    }

    // MARK: - Streams

    func listStreams() async throws -> [YouTubeStream] {
        let token = try await requireToken()

        var components = URLComponents(string: "\(baseUrl)/liveStreams")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet,cdn,status"),
            URLQueryItem(name: "mine", value: "true"),
            URLQueryItem(name: "maxResults", value: "10"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(YouTubeListResponse<YouTubeStreamItem>.self, from: data)

        return response.items?.compactMap { item in
            guard let ingestion = item.cdn?.ingestionInfo?.ingestionAddress ?? item.cdn?.ingestionInfo?.rtmpsIngestionAddress,
                  let streamName = item.cdn?.ingestionInfo?.streamName else {
                return nil
            }
            return YouTubeStream(
                id: item.id,
                title: item.snippet?.title ?? "",
                ingestionAddress: ingestion,
                streamName: streamName,
                streamStatus: item.status?.streamStatus
            )
        } ?? []
    }

    func createStream(title: String = "Streamif Stream") async throws -> YouTubeStream {
        let token = try await requireToken()

        var request = URLRequest(url: URL(string: "\(baseUrl)/liveStreams?part=snippet,cdn,status")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "snippet": [
                "title": title,
            ],
            "cdn": [
                "ingestionType": "rtmp",
                "resolution": "1080p",
                "frameRate": "60fps",
            ],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let item = try JSONDecoder().decode(YouTubeStreamItem.self, from: data)

        guard let ingestion = item.cdn?.ingestionInfo?.ingestionAddress ?? item.cdn?.ingestionInfo?.rtmpsIngestionAddress,
              let streamName = item.cdn?.ingestionInfo?.streamName else {
            throw YouTubeAPIError.invalidResponse
        }

        return YouTubeStream(
            id: item.id,
            title: item.snippet?.title ?? title,
            ingestionAddress: ingestion,
            streamName: streamName,
            streamStatus: item.status?.streamStatus
        )
    }

    // MARK: - Bind & Transition

    func bindStreamToBroadcast(broadcastId: String, streamId: String) async throws {
        let token = try await requireToken()

        var components = URLComponents(string: "\(baseUrl)/liveBroadcasts/bind")!
        components.queryItems = [
            URLQueryItem(name: "id", value: broadcastId),
            URLQueryItem(name: "part", value: "id,contentDetails"),
            URLQueryItem(name: "streamId", value: streamId),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, _) = try await URLSession.shared.data(for: request)
    }

    func transitionBroadcast(id: String, to status: String) async throws {
        let token = try await requireToken()

        var components = URLComponents(string: "\(baseUrl)/liveBroadcasts/transition")!
        components.queryItems = [
            URLQueryItem(name: "broadcastStatus", value: status),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "part", value: "status"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, _) = try await URLSession.shared.data(for: request)
    }

    // MARK: - Chat

    func fetchChatMessages(liveChatId: String, pageToken: String?) async throws -> YouTubeChatListResponse {
        let token = try await requireToken()

        var components = URLComponents(string: "\(baseUrl)/liveChat/messages")!
        var queryItems = [
            URLQueryItem(name: "liveChatId", value: liveChatId),
            URLQueryItem(name: "part", value: "snippet,authorDetails"),
            URLQueryItem(name: "maxResults", value: "200"),
        ]
        if let pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(YouTubeChatListResponse.self, from: data)
    }

    // MARK: - Active Broadcast Helper

    func getActiveBroadcast() async throws -> YouTubeBroadcast? {
        let active = try await listBroadcasts(status: "active")
        if let broadcast = active.first {
            return broadcast
        }

        let upcoming = try await listBroadcasts(status: "upcoming")
        return upcoming.first
    }

    // MARK: - Setup Broadcast (create or reuse)

    func setupBroadcast(title: String, description: String, privacyStatus: String) async throws -> (broadcast: YouTubeBroadcast, stream: YouTubeStream) {
        let broadcast = try await createBroadcast(
            title: title,
            description: description,
            privacyStatus: privacyStatus
        )

        let streams = try await listStreams()
        let stream: YouTubeStream
        if let existing = streams.first {
            stream = existing
        } else {
            stream = try await createStream()
        }

        try await bindStreamToBroadcast(broadcastId: broadcast.id, streamId: stream.id)

        return (broadcast, stream)
    }

    // MARK: - Helpers

    private func requireToken() async throws -> String {
        guard let token = await auth.getAccessToken() else {
            throw YouTubeAPIError.notAuthenticated
        }
        return token
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

// MARK: - Errors

enum YouTubeAPIError: LocalizedError {
    case notAuthenticated
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in to YouTube"
        case .invalidResponse: return "Invalid response from YouTube API"
        case .apiError(let msg): return msg
        }
    }
}

extension YouTubeAPI {
    /// Turns a non-2xx response into the message YouTube put in the body,
    /// instead of letting it decode into an empty result set.
    static func throwIfError(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw YouTubeAPIError.apiError("YouTube API \(http.statusCode): \(message)")
        }
        throw YouTubeAPIError.apiError("YouTube API returned \(http.statusCode)")
    }
}
