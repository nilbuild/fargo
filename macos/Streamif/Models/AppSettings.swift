import Foundation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - General

    var recordingPath: String {
        get { defaults.string(forKey: "streamif.recordingPath") ?? "~/Movies/" }
        set { defaults.set(newValue, forKey: "streamif.recordingPath") }
    }

    var countdownSeconds: Int {
        get {
            if defaults.object(forKey: "streamif.countdownSeconds") == nil { return 3 }
            return defaults.integer(forKey: "streamif.countdownSeconds")
        }
        set { defaults.set(newValue, forKey: "streamif.countdownSeconds") }
    }

    // MARK: - Stream

    var defaultVideoBitrate: Int {
        get {
            let val = defaults.integer(forKey: "streamif.defaultVideoBitrate")
            return val > 0 ? val : 8_000_000
        }
        set { defaults.set(newValue, forKey: "streamif.defaultVideoBitrate") }
    }

    var defaultAudioBitrate: Int {
        get {
            let val = defaults.integer(forKey: "streamif.defaultAudioBitrate")
            return val > 0 ? val : 320_000
        }
        set { defaults.set(newValue, forKey: "streamif.defaultAudioBitrate") }
    }

    var defaultFps: Int {
        get {
            let val = defaults.integer(forKey: "streamif.defaultFps")
            return val > 0 ? val : 60
        }
        set { defaults.set(newValue, forKey: "streamif.defaultFps") }
    }

    var defaultResolution: String {
        get { defaults.string(forKey: "streamif.defaultResolution") ?? "1920x1080" }
        set { defaults.set(newValue, forKey: "streamif.defaultResolution") }
    }

    var maxReconnectAttempts: Int {
        get {
            let val = defaults.integer(forKey: "streamif.maxReconnectAttempts")
            return val > 0 ? val : 5
        }
        set { defaults.set(newValue, forKey: "streamif.maxReconnectAttempts") }
    }

    // MARK: - Reset

    func resetGeneral() {
        defaults.removeObject(forKey: "streamif.recordingPath")
        defaults.removeObject(forKey: "streamif.countdownSeconds")
    }

    func resetStream() {
        defaults.removeObject(forKey: "streamif.defaultVideoBitrate")
        defaults.removeObject(forKey: "streamif.defaultAudioBitrate")
        defaults.removeObject(forKey: "streamif.defaultFps")
        defaults.removeObject(forKey: "streamif.defaultResolution")
        defaults.removeObject(forKey: "streamif.maxReconnectAttempts")
    }

    func resetAll() {
        resetGeneral()
        resetStream()
    }
}
