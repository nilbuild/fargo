import AVFoundation
import AppKit

struct SoundEffect: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var icon: String
    var filePath: String
    var isBuiltIn: Bool
    var volume: Float

    init(name: String, icon: String, filePath: String, isBuiltIn: Bool = false, volume: Float = 1.0) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.filePath = filePath
        self.isBuiltIn = isBuiltIn
        self.volume = volume
    }
}

@MainActor @Observable
final class SoundBoard {
    var sounds: [SoundEffect] = []
    var playingId: UUID?

    private var audioPlayer: AVAudioPlayer?
    var onAudioSample: ((CMSampleBuffer) -> Void)?

    private var mixerEngine: AVAudioEngine?
    private var mixerPlayer: AVAudioPlayerNode?

    init() {
        loadSounds()
    }

    // MARK: - Playback

    func play(_ sound: SoundEffect) {
        stop()

        let url: URL
        if sound.isBuiltIn {
            guard let bundleURL = Bundle.main.url(forResource: sound.filePath, withExtension: nil, subdirectory: "Sounds") else {
                print("[SoundBoard] Built-in sound not found: \(sound.filePath)")
                return
            }
            url = bundleURL
        } else {
            url = URL(fileURLWithPath: sound.filePath)
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = sound.volume
            player.delegate = SoundPlayerDelegate.shared
            SoundPlayerDelegate.shared.onFinished = { [weak self] in
                Task { @MainActor in
                    self?.playingId = nil
                }
            }
            player.play()
            audioPlayer = player
            playingId = sound.id
        } catch {
            print("[SoundBoard] Play error: \(error)")
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingId = nil
    }

    // MARK: - Sound Management

    func addCustomSound(name: String, url: URL) {
        let dest = soundsDirectory().appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.copyItem(at: url, to: dest)

        let sound = SoundEffect(
            name: name,
            icon: "waveform",
            filePath: dest.path,
            isBuiltIn: false
        )
        sounds.append(sound)
        saveSounds()
    }

    func removeSound(_ id: UUID) {
        guard let sound = sounds.first(where: { $0.id == id }) else { return }
        if !sound.isBuiltIn {
            try? FileManager.default.removeItem(atPath: sound.filePath)
        }
        sounds.removeAll { $0.id == id }
        saveSounds()
    }

    func updateVolume(_ id: UUID, volume: Float) {
        if let idx = sounds.firstIndex(where: { $0.id == id }) {
            sounds[idx].volume = volume
            saveSounds()
        }
    }

    // MARK: - Built-in Sounds

    static let builtInSounds: [SoundEffect] = [
        SoundEffect(name: "Alert", icon: "bell.fill", filePath: "alert-chime.mp3", isBuiltIn: true),
        SoundEffect(name: "Applause", icon: "hands.clap.fill", filePath: "applause.mp3", isBuiltIn: true),
        SoundEffect(name: "Drum Roll", icon: "music.note", filePath: "drum-roll.mp3", isBuiltIn: true),
        SoundEffect(name: "Rimshot", icon: "music.mic", filePath: "rimshot.mp3", isBuiltIn: true),
        SoundEffect(name: "Fanfare", icon: "trophy.fill", filePath: "fanfare.mp3", isBuiltIn: true),
        SoundEffect(name: "Ding", icon: "bell.badge.fill", filePath: "notification-ding.mp3", isBuiltIn: true),
        SoundEffect(name: "Buzzer", icon: "xmark.octagon.fill", filePath: "buzzer.mp3", isBuiltIn: true),
        SoundEffect(name: "Fail", icon: "face.dashed", filePath: "fail.mp3", isBuiltIn: true),
    ]

    // MARK: - Persistence

    private func soundsDirectory() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Streamif/Sounds")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadSounds() {
        if let data = UserDefaults.standard.data(forKey: "streamif.soundboard"),
           let saved = try? JSONDecoder().decode([SoundEffect].self, from: data) {
            sounds = saved
        } else {
            sounds = Self.builtInSounds
            saveSounds()
        }
    }

    private func saveSounds() {
        guard let data = try? JSONEncoder().encode(sounds) else { return }
        UserDefaults.standard.set(data, forKey: "streamif.soundboard")
    }
}

// AVAudioPlayerDelegate needs to be a class, not an actor
private class SoundPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    static let shared = SoundPlayerDelegate()
    var onFinished: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinished?()
    }
}
