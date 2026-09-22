import Foundation
import AVFoundation

// MARK: - Platform Presets

struct PlatformPreset: Identifiable {
    let id: String
    let name: String
    let icon: String
    let rtmpUrl: String
    let streamKeyUrl: String
    let tutorialUrl: String
    let videoWidth: Int
    let videoHeight: Int
    let videoBitrate: Int
    let audioBitrate: Int
    let fps: Int

    static let presets: [PlatformPreset] = [
        PlatformPreset(
            id: "youtube", name: "YouTube", icon: "play.rectangle.fill",
            rtmpUrl: "rtmp://a.rtmp.youtube.com/live2",
            streamKeyUrl: "https://studio.youtube.com/channel/UC/livestreaming",
            tutorialUrl: "https://www.youtube.com/results?search_query=how+to+get+youtube+stream+key",
            videoWidth: 3840, videoHeight: 2160, videoBitrate: 20_000_000,
            audioBitrate: 320_000, fps: 60
        ),
        PlatformPreset(
            id: "twitch", name: "Twitch", icon: "gamecontroller.fill",
            rtmpUrl: "rtmp://live.twitch.tv/app",
            streamKeyUrl: "https://dashboard.twitch.tv/u/_/settings/stream",
            tutorialUrl: "https://www.youtube.com/results?search_query=how+to+get+twitch+stream+key",
            videoWidth: 1920, videoHeight: 1080, videoBitrate: 8_500_000,
            audioBitrate: 320_000, fps: 60
        ),
        PlatformPreset(
            id: "kick", name: "Kick", icon: "bolt.fill",
            rtmpUrl: "rtmp://fa723fc1b171.global-contribute.live-video.net/app",
            streamKeyUrl: "https://kick.com/dashboard/settings/stream",
            tutorialUrl: "https://www.youtube.com/results?search_query=how+to+get+kick+stream+key",
            videoWidth: 1920, videoHeight: 1080, videoBitrate: 8_000_000,
            audioBitrate: 320_000, fps: 60
        ),
        PlatformPreset(
            id: "facebook", name: "Facebook", icon: "person.2.fill",
            rtmpUrl: "rtmps://live-api-s.facebook.com:443/rtmp",
            streamKeyUrl: "https://www.facebook.com/live/producer",
            tutorialUrl: "https://www.youtube.com/results?search_query=how+to+get+facebook+live+stream+key",
            videoWidth: 1920, videoHeight: 1080, videoBitrate: 8_000_000,
            audioBitrate: 320_000, fps: 30
        ),
        PlatformPreset(
            id: "x", name: "X (Twitter)", icon: "bubble.left.fill",
            rtmpUrl: "",
            streamKeyUrl: "https://studio.x.com/producer",
            tutorialUrl: "https://www.youtube.com/results?search_query=how+to+stream+to+x+twitter",
            videoWidth: 1920, videoHeight: 1080, videoBitrate: 9_000_000,
            audioBitrate: 128_000, fps: 30
        ),
        PlatformPreset(
            id: "custom", name: "Custom", icon: "antenna.radiowaves.left.and.right",
            rtmpUrl: "",
            streamKeyUrl: "",
            tutorialUrl: "",
            videoWidth: 1920, videoHeight: 1080, videoBitrate: 6_000_000,
            audioBitrate: 160_000, fps: 30
        ),
    ]
}

// MARK: - Stream Destination

struct StreamDestination: Identifiable, Codable {
    let id: UUID
    var name: String
    var platformId: String
    var rtmpUrl: String
    var streamKey: String
    var videoBitrate: Int
    var audioBitrate: Int
    var videoWidth: Int
    var videoHeight: Int
    var fps: Int
    var enabled: Bool

    init(from preset: PlatformPreset, rtmpUrl: String? = nil, streamKey: String) {
        self.id = UUID()
        self.name = preset.name
        self.platformId = preset.id
        self.rtmpUrl = rtmpUrl ?? preset.rtmpUrl
        self.streamKey = streamKey
        self.videoBitrate = preset.videoBitrate
        self.audioBitrate = preset.audioBitrate
        self.videoWidth = preset.videoWidth
        self.videoHeight = preset.videoHeight
        self.fps = preset.fps
        self.enabled = true
    }
}

// MARK: - Devices

struct CameraDevice: Identifiable {
    let id: String
    let name: String
    let device: AVCaptureDevice
}

struct AudioDevice: Identifiable {
    let id: String
    let name: String
    let device: AVCaptureDevice
}

// MARK: - Stream Status

enum StreamStatus: Equatable {
    case idle
    case connecting
    case live(startTime: Date)
    case error(String)

    static func == (lhs: StreamStatus, rhs: StreamStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.connecting, .connecting): return true
        case (.live, .live): return true
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }
}
