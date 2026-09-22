import Foundation
import Testing

@Suite("Platform presets")
struct PlatformPresetTests {

    @Test("presets match the documented ingest limits")
    func presetsMatchDocumentedLimits() throws {
        // The documented maximum RTMP ingest settings per platform (see README.md).
        // A preset drifting above a platform's ceiling means silently rejected streams.
        let documented: [(id: String, width: Int, height: Int, videoBitrate: Int, audioBitrate: Int, fps: Int)] = [
            ("youtube", 3840, 2160, 20_000_000, 320_000, 60),
            ("twitch", 1920, 1080, 8_500_000, 320_000, 60),
            ("kick", 1920, 1080, 8_000_000, 320_000, 60),
            ("facebook", 1920, 1080, 8_000_000, 320_000, 30),
        ]

        for limit in documented {
            let preset = try #require(PlatformPreset.presets.first { $0.id == limit.id }, "missing preset \(limit.id)")

            #expect(preset.videoWidth == limit.width, "\(limit.id) width")
            #expect(preset.videoHeight == limit.height, "\(limit.id) height")
            #expect(preset.videoBitrate == limit.videoBitrate, "\(limit.id) video bitrate")
            #expect(preset.audioBitrate == limit.audioBitrate, "\(limit.id) audio bitrate")
            #expect(preset.fps == limit.fps, "\(limit.id) fps")
        }
    }

    @Test("preset ids are unique")
    func presetIdsAreUnique() {
        let ids = PlatformPreset.presets.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("built-in rtmp urls use an rtmp scheme")
    func rtmpUrlsUseRTMPScheme() {
        for preset in PlatformPreset.presets where !preset.rtmpUrl.isEmpty {
            let isRTMP = preset.rtmpUrl.hasPrefix("rtmp://") || preset.rtmpUrl.hasPrefix("rtmps://")
            #expect(isRTMP, "\(preset.id) has a non-RTMP ingest url: \(preset.rtmpUrl)")
        }
    }

    @Test("only YouTube exceeds 1080p, matching StreamManager's resolution routing")
    func onlyYouTubeIsAbove1080p() {
        let above1080p = PlatformPreset.presets.filter { $0.videoHeight > 1080 }.map(\.id)
        #expect(above1080p == ["youtube"])
    }

    @Test("every preset declares a landscape 16:9 frame")
    func presetsAre16By9() {
        for preset in PlatformPreset.presets {
            #expect(preset.videoWidth * 9 == preset.videoHeight * 16, "\(preset.id) is not 16:9")
        }
    }
}

@Suite("Stream destinations")
struct StreamDestinationTests {

    private func preset(_ id: String) throws -> PlatformPreset {
        try #require(PlatformPreset.presets.first { $0.id == id })
    }

    @Test("a destination inherits the preset's encoder settings")
    func inheritsPresetSettings() throws {
        let youtube = try preset("youtube")
        let destination = StreamDestination(from: youtube, streamKey: "abc-123")

        #expect(destination.name == youtube.name)
        #expect(destination.platformId == youtube.id)
        #expect(destination.rtmpUrl == youtube.rtmpUrl)
        #expect(destination.videoWidth == youtube.videoWidth)
        #expect(destination.videoHeight == youtube.videoHeight)
        #expect(destination.videoBitrate == youtube.videoBitrate)
        #expect(destination.audioBitrate == youtube.audioBitrate)
        #expect(destination.fps == youtube.fps)
        #expect(destination.streamKey == "abc-123")
        #expect(destination.enabled)
    }

    @Test("an explicit rtmp url overrides the preset's")
    func explicitURLOverridesPreset() throws {
        let custom = try preset("custom")
        let destination = StreamDestination(from: custom, rtmpUrl: "rtmp://example.test/live", streamKey: "key")

        #expect(destination.rtmpUrl == "rtmp://example.test/live")
    }

    @Test("destinations survive a Codable round-trip")
    func codableRoundTrip() throws {
        let original = StreamDestination(from: try preset("twitch"), streamKey: "live_123")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StreamDestination.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.platformId == original.platformId)
        #expect(decoded.rtmpUrl == original.rtmpUrl)
        #expect(decoded.streamKey == original.streamKey)
        #expect(decoded.videoBitrate == original.videoBitrate)
        #expect(decoded.audioBitrate == original.audioBitrate)
        #expect(decoded.videoWidth == original.videoWidth)
        #expect(decoded.videoHeight == original.videoHeight)
        #expect(decoded.fps == original.fps)
        #expect(decoded.enabled == original.enabled)
    }
}

@Suite("Stream status")
struct StreamStatusTests {

    @Test("isLive is true only while live")
    func isLiveOnlyWhenLive() {
        #expect(StreamStatus.live(startTime: Date()).isLive)
        #expect(!StreamStatus.idle.isLive)
        #expect(!StreamStatus.connecting.isLive)
        #expect(!StreamStatus.error("boom").isLive)
    }

    @Test("two live states compare equal regardless of start time")
    func liveEqualityIgnoresStartTime() {
        let early = StreamStatus.live(startTime: Date(timeIntervalSince1970: 0))
        let late = StreamStatus.live(startTime: Date(timeIntervalSince1970: 10_000))

        #expect(early == late)
    }

    @Test("error states compare by message")
    func errorEqualityComparesMessage() {
        #expect(StreamStatus.error("connection refused") == StreamStatus.error("connection refused"))
        #expect(StreamStatus.error("connection refused") != StreamStatus.error("timeout"))
        #expect(StreamStatus.error("connection refused") != StreamStatus.idle)
    }
}
