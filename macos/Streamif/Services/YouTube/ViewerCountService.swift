import Foundation

/// Polls live viewer counts for the connected chat sources, so the chat views can show
/// how many people are watching on each platform.
@MainActor @Observable
final class ViewerCountService {
    private static let isVisibleKey = "streamif.chat.showViewerCount"
    private static let refreshInterval: TimeInterval = 30

    /// nil means the platform is not connected, or did not report a count.
    private(set) var youtube: Int?
    private(set) var twitch: Int?
    private(set) var lastUpdated: Date?

    var isVisible = UserDefaults.standard.object(forKey: isVisibleKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isVisible, forKey: Self.isVisibleKey)
        }
    }

    var total: Int? {
        if youtube == nil && twitch == nil {
            return nil
        }
        return (youtube ?? 0) + (twitch ?? 0)
    }

    private var lastSourcesKey = ""
    private var lastRefresh = Date.distantPast
    private var isRefreshing = false

    /// Called on a short tick. Fetches when the connected sources change, or when the
    /// refresh interval has passed, and only while the count is shown or the stream is
    /// live, since the post-stream summary needs the counts too.
    func tick(youtubeAPI: YouTubeAPI?, youtubeVideoId: String?, twitchAuth: TwitchAuth, twitchChannel: String?, isLive: Bool) async {
        if youtubeVideoId == nil {
            youtube = nil
        }
        if twitchChannel == nil {
            twitch = nil
        }

        guard isVisible || isLive, !isRefreshing else { return }

        let sourcesKey = "\(youtubeVideoId ?? "")|\(twitchChannel ?? "")"
        let isDue = Date().timeIntervalSince(lastRefresh) >= Self.refreshInterval
        guard sourcesKey != lastSourcesKey || isDue else { return }

        lastSourcesKey = sourcesKey
        lastRefresh = Date()
        isRefreshing = true
        defer { isRefreshing = false }

        if let api = youtubeAPI, let videoId = youtubeVideoId {
            do {
                youtube = try await api.fetchConcurrentViewers(videoId: videoId)
            } catch {
                print("[Viewers] YouTube fetch failed: \(error)")
            }
        }

        if let channel = twitchChannel {
            do {
                twitch = try await fetchTwitchViewers(auth: twitchAuth, channel: channel)
            } catch {
                print("[Viewers] Twitch fetch failed: \(error)")
            }
        }

        if youtubeVideoId != nil || twitchChannel != nil {
            lastUpdated = Date()
        }
    }

    // MARK: - Twitch

    private struct TwitchStreamsResponse: Decodable {
        let data: [Stream]

        struct Stream: Decodable {
            let viewer_count: Int
        }
    }

    /// Returns 0 when the channel is offline, since Helix omits offline streams.
    private func fetchTwitchViewers(auth: TwitchAuth, channel: String) async throws -> Int? {
        guard let token = await auth.getAccessToken() else { return nil }

        var components = URLComponents(string: "https://api.twitch.tv/helix/streams")!
        components.queryItems = [URLQueryItem(name: "user_login", value: channel)]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(TwitchAuth.clientId, forHTTPHeaderField: "Client-Id")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw YouTubeAPIError.apiError("Twitch API returned \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(TwitchStreamsResponse.self, from: data)
        return decoded.data.first?.viewer_count ?? 0
    }
}
