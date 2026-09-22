import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            StreamSettingsView()
                .tabItem { Label("Stream", systemImage: "antenna.radiowaves.left.and.right") }

            ShortcutsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 420)
    }
}

struct GeneralSettingsView: View {
    @State private var recordingPath: String = AppSettings.shared.recordingPath
    @State private var countdownSeconds: Int = AppSettings.shared.countdownSeconds
    @State private var updater = Updater.shared

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Quit when window is closed", isOn: .constant(true))
                    .disabled(true)
                Toggle("Remember window position", isOn: .constant(true))
                    .disabled(true)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)

                HStack {
                    Text("Current version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                        .foregroundStyle(.secondary)
                    Button("Check Now") {
                        updater.checkForUpdates()
                    }
                    .contentShape(Rectangle())
                    .disabled(!updater.canCheckForUpdates)
                }
            }

            Section("Recording") {
                HStack {
                    Text("Save location")
                    Spacer()
                    Text(recordingPath).foregroundStyle(.secondary).lineLimit(1)
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            recordingPath = url.path
                            AppSettings.shared.recordingPath = url.path
                        }
                    }
                    .controlSize(.small)
                }
                InfoRow("Format", "H.264 MP4")
            }

            Section("Go Live") {
                Picker("Countdown", selection: $countdownSeconds) {
                    Text("None").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                .onChange(of: countdownSeconds) { _, val in
                    AppSettings.shared.countdownSeconds = val
                }
            }

            Section {
                Button("Reset to Defaults") {
                    AppSettings.shared.resetGeneral()
                    recordingPath = AppSettings.shared.recordingPath
                    countdownSeconds = AppSettings.shared.countdownSeconds
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}

struct StreamSettingsView: View {
    @State private var maxReconnectAttempts: Int = AppSettings.shared.maxReconnectAttempts

    var body: some View {
        Form {
            Section("Streaming") {
                InfoRow("Video Encoder", "H.264 VideoToolbox (hardware)")
                InfoRow("Audio Codec", "AAC-LC 48kHz stereo")
                InfoRow("Quality", "Per-destination (set in platform presets)")
            }

            Section("Local Recording") {
                InfoRow("Video Codec", "HEVC 4K")
                InfoRow("Quality", "Maximum (encoder-driven)")
                InfoRow("Audio", "AAC 48kHz stereo 320kbps VBR")
                InfoRow("Keyframe Interval", "1 second")
            }

            Section("Connection") {
                InfoRow("Protocol", "RTMP / RTMPS")

                Stepper("Max Reconnect Attempts: \(maxReconnectAttempts)", value: $maxReconnectAttempts, in: 1...20)
                    .onChange(of: maxReconnectAttempts) { _, val in
                        AppSettings.shared.maxReconnectAttempts = val
                    }

                InfoRow("Reconnect Backoff", "Exponential (2^n seconds)")
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutsView: View {
    var body: some View {
        Form {
            Section("Stream") {
                ShortcutRow("Go Live / End Stream", "⇧⌘L")
                ShortcutRow("Start/Stop Recording", "⇧⌘R")
                ShortcutRow("Toggle Mute", "M")
            }

            Section("Scenes") {
                ShortcutRow("Camera", "1")
                ShortcutRow("Screen", "2")
                ShortcutRow("PiP", "3")
                ShortcutRow("Media", "4")
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }

            Text("Streamif")
                .font(.system(size: 22, weight: .bold))

            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("Native macOS streaming studio")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Divider().frame(width: 200)

            VStack(spacing: 4) {
                Text("Powered by")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("AVFoundation · VideoToolbox · Metal · ScreenCaptureKit")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text("No FFmpeg. Native AVFoundation, VideoToolbox and Metal throughout.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.blue.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Helper Views

private struct InfoRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary) }
    }
}

private struct ShortcutRow: View {
    let label: String
    let shortcut: String
    init(_ label: String, _ shortcut: String) { self.label = label; self.shortcut = shortcut }
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(shortcut)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
