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

    init(from preset: PlatformPreset, rtmpUrl: String? = nil, streamKey: String,
         quality: StreamQuality? = nil) {
        self.id = UUID()
        self.name = preset.name
        self.platformId = preset.id
        self.rtmpUrl = rtmpUrl ?? preset.rtmpUrl
        self.streamKey = streamKey
        self.audioBitrate = preset.audioBitrate
        self.videoBitrate = quality?.videoBitrate ?? preset.videoBitrate
        self.videoWidth = quality?.width ?? preset.videoWidth
        self.videoHeight = quality?.height ?? preset.videoHeight
        self.fps = quality?.fps ?? preset.fps
        self.enabled = true
    }
}

// MARK: - Stream Quality

/// A resolution and bitrate a destination can be sent at. Presets carry each
/// platform's maximum, which is rarely what a given broadcast is configured for.
struct StreamQuality: Identifiable, Hashable {
    let id: String
    let label: String
    let width: Int
    let height: Int
    let fps: Int
    let videoBitrate: Int

    static let all: [StreamQuality] = [
        StreamQuality(id: "720p30", label: "720p30", width: 1280, height: 720, fps: 30, videoBitrate: 3_000_000),
        StreamQuality(id: "1080p30", label: "1080p30", width: 1920, height: 1080, fps: 30, videoBitrate: 4_500_000),
        StreamQuality(id: "1080p60", label: "1080p60", width: 1920, height: 1080, fps: 60, videoBitrate: 6_000_000),
        StreamQuality(id: "1440p60", label: "1440p60", width: 2560, height: 1440, fps: 60, videoBitrate: 9_000_000),
        StreamQuality(id: "2160p60", label: "4K60", width: 3840, height: 2160, fps: 60, videoBitrate: 20_000_000),
    ]

    /// Options a platform actually accepts, never above its documented ceiling.
    static func options(for preset: PlatformPreset) -> [StreamQuality] {
        let allowed = all.filter { $0.height <= preset.videoHeight && $0.fps <= preset.fps }
        return allowed.isEmpty ? [all[0]] : allowed
    }

    /// 1080p60 where the platform allows it. The platform maximum is a ceiling,
    /// not a sensible default, and it has to match how the broadcast was set up.
    static func defaultOption(for preset: PlatformPreset) -> StreamQuality {
        let opts = options(for: preset)
        return opts.first { $0.id == "1080p60" } ?? opts.last ?? all[0]
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
