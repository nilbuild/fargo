import SwiftUI
import AppKit

// MARK: - Chat Pop-out Window

/// A floating window that keeps live chat in front of the streamer, above other apps
/// and full-screen spaces.
@MainActor @Observable
final class ChatPopout {
    static let shared = ChatPopout()

    private static let showInScreenShareKey = "streamif.chatPopout.showInScreenShare"

    private(set) var isOpen = false

    /// Whether the window shows up in screen captures, both Streamif's own display capture
    /// and other screen-sharing apps. Off by default, so chat stays private to the streamer.
    var showInScreenShare = UserDefaults.standard.bool(forKey: showInScreenShareKey) {
        didSet {
            UserDefaults.standard.set(showInScreenShare, forKey: Self.showInScreenShareKey)
            applySharingType()
            refreshCaptures()
        }
    }

    var windowNumber: Int? { isOpen ? panel?.windowNumber : nil }

    private var panel: NSPanel?
    private weak var pipeline: MediaPipeline?

    func toggle(pipeline: MediaPipeline) {
        isOpen ? close() : open(pipeline: pipeline)
    }

    func open(pipeline: MediaPipeline) {
        self.pipeline = pipeline
        if panel == nil {
            panel = makePanel(pipeline: pipeline)
        }
        applySharingType()
        panel?.orderFrontRegardless()
        isOpen = true
        refreshCaptures()
    }

    func close() {
        panel?.close()
    }

    private func makePanel(pipeline: MediaPipeline) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Live Chat"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(white: 0.05, alpha: 1)
        panel.contentMinSize = NSSize(width: 260, height: 240)
        panel.contentView = NSHostingView(rootView: ChatPopoutView().environment(pipeline))
        if !panel.setFrameUsingName("StreamifChatPopout") {
            panel.center()
        }
        panel.setFrameAutosaveName("StreamifChatPopout")

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isOpen = false
                self?.refreshCaptures()
            }
        }
        return panel
    }

    private func applySharingType() {
        panel?.sharingType = showInScreenShare ? .readOnly : .none
    }

    private func refreshCaptures() {
        guard let pipeline else { return }
        Task { await pipeline.refreshScreenCaptureExclusions() }
    }
}

// MARK: - Chat Pop-out View

struct ChatPopoutView: View {
    @Environment(MediaPipeline.self) private var pipeline
    @Bindable private var popout = ChatPopout.shared

    private var hasAnyChat: Bool {
        pipeline.youtubeChatService.isPolling || pipeline.twitchChatService.isConnected
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: popout.showInScreenShare ? "eye" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(popout.showInScreenShare ? .orange : .white.opacity(0.4))
                    .frame(width: 14)
                Text(popout.showInScreenShare ? "Visible in screen share" : "Hidden from screen share")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Toggle("", isOn: $popout.showInScreenShare)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Show this window when your screen is captured or shared")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(white: 0.04))
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !hasAnyChat {
                        TabEmptyState(
                            icon: "bubble.left.and.bubble.right",
                            title: "No chat sources",
                            subtitle: "Connect YouTube or Twitch in the Chat tab"
                        )
                    } else if pipeline.allChatMessages.isEmpty {
                        TabEmptyState(
                            icon: "bubble.left.and.bubble.right",
                            title: "Waiting for messages",
                            subtitle: "Chat messages will appear here"
                        )
                    }

                    ForEach(pipeline.allChatMessages.reversed()) { msg in
                        ChatMessageRow(
                            message: msg,
                            source: msg.id.hasPrefix("twitch_") ? .twitch : .youtube,
                            isFeatured: pipeline.featuredChatMessage?.id == msg.id,
                            onFeature: { pipeline.featureChatMessage(msg) }
                        )
                    }
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.05))
    }
}
