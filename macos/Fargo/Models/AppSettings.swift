import Foundation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - General

    var recordingPath: String {
        get { defaults.string(forKey: "fargo.recordingPath") ?? "~/Movies/" }
        set { defaults.set(newValue, forKey: "fargo.recordingPath") }
    }

    var countdownSeconds: Int {
        get {
            if defaults.object(forKey: "fargo.countdownSeconds") == nil { return 3 }
            return defaults.integer(forKey: "fargo.countdownSeconds")
        }
        set { defaults.set(newValue, forKey: "fargo.countdownSeconds") }
    }

    // MARK: - Stream

    var defaultVideoBitrate: Int {
        get {
            let val = defaults.integer(forKey: "fargo.defaultVideoBitrate")
            return val > 0 ? val : 8_000_000
        }
        set { defaults.set(newValue, forKey: "fargo.defaultVideoBitrate") }
    }

    var defaultAudioBitrate: Int {
        get {
            let val = defaults.integer(forKey: "fargo.defaultAudioBitrate")
            return val > 0 ? val : 320_000
        }
        set { defaults.set(newValue, forKey: "fargo.defaultAudioBitrate") }
    }

    var defaultFps: Int {
        get {
            let val = defaults.integer(forKey: "fargo.defaultFps")
            return val > 0 ? val : 60
        }
        set { defaults.set(newValue, forKey: "fargo.defaultFps") }
    }

    var defaultResolution: String {
        get { defaults.string(forKey: "fargo.defaultResolution") ?? "1920x1080" }
        set { defaults.set(newValue, forKey: "fargo.defaultResolution") }
    }

    var maxReconnectAttempts: Int {
        get {
            let val = defaults.integer(forKey: "fargo.maxReconnectAttempts")
            return val > 0 ? val : 5
        }
        set { defaults.set(newValue, forKey: "fargo.maxReconnectAttempts") }
    }

    // MARK: - Reset

    func resetGeneral() {
        defaults.removeObject(forKey: "fargo.recordingPath")
        defaults.removeObject(forKey: "fargo.countdownSeconds")
    }

    func resetStream() {
        defaults.removeObject(forKey: "fargo.defaultVideoBitrate")
        defaults.removeObject(forKey: "fargo.defaultAudioBitrate")
        defaults.removeObject(forKey: "fargo.defaultFps")
        defaults.removeObject(forKey: "fargo.defaultResolution")
        defaults.removeObject(forKey: "fargo.maxReconnectAttempts")
    }

    func resetAll() {
        resetGeneral()
        resetStream()
    }
}
