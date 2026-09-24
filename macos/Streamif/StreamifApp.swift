import SwiftUI
import AppKit

@main
struct StreamifApp: App {
    @State private var pipeline = MediaPipeline()
    @State private var destinations = DestinationStore()
    @State private var updater = Updater.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(pipeline)
                .environment(destinations)
                .task {
                    appDelegate.pipeline = pipeline
                    destinations.load()
                    await pipeline.start()
                }
                .onChange(of: pipeline.streamStatus.isLive) { _, isLive in
                    NSApp.dockTile.badgeLabel = isLive ? "LIVE" : nil
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 750)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            CommandMenu("Stream") {
                Button("Go Live") {
                    NotificationCenter.default.post(name: .goLive, object: false)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(pipeline.streamStatus.isLive)

                Button("Go Live & Record") {
                    NotificationCenter.default.post(name: .goLive, object: true)
                }
                .disabled(pipeline.streamStatus.isLive)

                Button("End Stream") {
                    NotificationCenter.default.post(name: .endStream, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!pipeline.streamStatus.isLive)

                Divider()

                Button(pipeline.isRecording ? "Stop Recording" : "Start Recording") {
                    if pipeline.isRecording {
                        pipeline.stopRecording()
                    } else {
                        pipeline.startRecording()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Toggle Mute") {
                    pipeline.toggleMute()
                }
                .keyboardShortcut("m", modifiers: [])
            }

            CommandMenu("Scene") {
                ForEach(Array(pipeline.canvases.prefix(9).enumerated()), id: \.element.id) { index, canvas in
                    Button(canvas.name) {
                        Task { await pipeline.setCanvas(canvas.id) }
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
                    .disabled(pipeline.streamStatus.isLive)
                }
            }
        }

        SwiftUI.Settings {
            SettingsView()
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var pipeline: MediaPipeline?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // The MP4 index is written when the recording finishes. Quitting without waiting for
    // it leaves a file nothing can play.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let pipeline, pipeline.isRecording else {
            return .terminateNow
        }
        pipeline.stopRecording {
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

// MARK: - Destination Store

@Observable
final class DestinationStore {
    var destinations: [StreamDestination] = []

    func add(from preset: PlatformPreset, rtmpUrl: String? = nil, streamKey: String,
             quality: StreamQuality? = nil) {
        destinations.append(StreamDestination(from: preset, rtmpUrl: rtmpUrl,
                                              streamKey: streamKey, quality: quality))
        save()
    }

    func remove(_ id: UUID) {
        destinations.removeAll { $0.id == id }
        save()
    }

    func toggle(_ id: UUID) {
        if let idx = destinations.firstIndex(where: { $0.id == id }) {
            destinations[idx].enabled.toggle()
            save()
        }
    }

    var enabledDestination: StreamDestination? {
        destinations.first { $0.enabled }
    }

    func save() { Persistence.saveDestinations(destinations) }
    func load() {
        destinations = Persistence.loadDestinations()
        var upgraded = false
        for i in destinations.indices {
            if let bitrate = StreamQuality.upgradedBitrate(for: destinations[i]) {
                destinations[i].videoBitrate = bitrate
                upgraded = true
            }
        }
        if upgraded {
            save()
        }
    }
}
