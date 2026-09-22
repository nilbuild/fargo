import Foundation

// MARK: - OAuth Tokens

struct YouTubeTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var scope: String

    var isExpired: Bool {
        return Date() >= expiresAt.addingTimeInterval(-60)
    }
}

// MARK: - Broadcast

struct YouTubeBroadcast: Identifiable, Codable {
    let id: String
    var title: String
    var description: String
    var privacyStatus: String
    var liveChatId: String?
    var scheduledStartTime: Date?
    var lifecycleStatus: String?

    var isActive: Bool {
        return lifecycleStatus == "live" || lifecycleStatus == "testing"
    }
}

// MARK: - Stream

struct YouTubeStream: Identifiable, Codable {
    let id: String
    var title: String
    var ingestionAddress: String
    var streamName: String
    var streamStatus: String?

    var rtmpUrl: String {
        return ingestionAddress
    }

    var streamKey: String {
        return streamName
    }
}

// MARK: - Chat Message

struct YouTubeChatMessage: Identifiable, Codable {
    let id: String
    let authorName: String
    let authorImageUrl: String
    let message: String
    let publishedAt: Date
    let type: ChatMessageType
    let isModerator: Bool
    let isOwner: Bool
    let superChatAmount: String?

    enum ChatMessageType: String, Codable {
        case text
        case superChat
        case superSticker
        case membership
        case unknown
    }
}

// MARK: - Channel Info

struct YouTubeChannelInfo: Codable {
    let channelId: String
    let channelTitle: String
    let thumbnailUrl: String?
}

// MARK: - API Response Wrappers

struct YouTubeListResponse<T: Decodable>: Decodable {
    let items: [T]?
    let nextPageToken: String?
    let pageInfo: PageInfo?

    struct PageInfo: Decodable {
        let totalResults: Int?
        let resultsPerPage: Int?
    }
}

struct YouTubeChatListResponse: Decodable {
    let items: [ChatItem]?
    let nextPageToken: String?
    let pollingIntervalMillis: Int?

    struct ChatItem: Decodable {
        let id: String
        let snippet: Snippet
        let authorDetails: AuthorDetails?

        struct Snippet: Decodable {
            let type: String?
            let displayMessage: String?
            let publishedAt: String?
            let textMessageDetails: TextMessageDetails?
            let superChatDetails: SuperChatDetails?
        }

        struct TextMessageDetails: Decodable {
            let messageText: String?
        }

        struct SuperChatDetails: Decodable {
            let amountDisplayString: String?
            let userComment: String?
        }

        struct AuthorDetails: Decodable {
            let channelId: String?
            let displayName: String?
            let profileImageUrl: String?
            let isChatOwner: Bool?
            let isChatModerator: Bool?
        }
    }
}

struct YouTubeBroadcastItem: Decodable {
    let id: String
    let snippet: Snippet?
    let status: Status?
    let contentDetails: ContentDetails?

    struct Snippet: Decodable {
        let title: String?
        let description: String?
        let scheduledStartTime: String?
        let liveChatId: String?
    }

    struct Status: Decodable {
        let privacyStatus: String?
        let lifeCycleStatus: String?
        let recordingStatus: String?
    }

    struct ContentDetails: Decodable {
        let boundStreamId: String?
    }
}

struct YouTubeStreamItem: Decodable {
    let id: String
    let snippet: Snippet?
    let cdn: CDN?
    let status: Status?

    struct Snippet: Decodable {
        let title: String?
    }

    struct CDN: Decodable {
        let ingestionInfo: IngestionInfo?
        let resolution: String?
        let frameRate: String?

        struct IngestionInfo: Decodable {
            let ingestionAddress: String?
            let streamName: String?
            let rtmpsIngestionAddress: String?
        }
    }

    struct Status: Decodable {
        let streamStatus: String?
    }
}

struct YouTubeChannelItem: Decodable {
    let id: String
    let snippet: Snippet?

    struct Snippet: Decodable {
        let title: String?
        let thumbnails: Thumbnails?

        struct Thumbnails: Decodable {
            let `default`: Thumbnail?

            struct Thumbnail: Decodable {
                let url: String?
            }
        }
    }
}
