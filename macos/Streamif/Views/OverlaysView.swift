import SwiftUI
import UniformTypeIdentifiers

struct OverlaysPanel: View {
    @Environment(MediaPipeline.self) private var pipeline
    @State private var draggingOverlayId: UUID?
    @State private var dropInsertIndex: Int?
    @State private var dragLocation: CGPoint?
    @State private var rowFrames: [UUID: CGRect] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                TabSectionHeader(title: "OVERLAYS") {
                    Menu {
                        Button {
                            pipeline.addOverlay(StreamOverlay(type: .text, text: "Text"))
                        } label: {
                            Label("Text", systemImage: "textformat")
                        }

                        Button {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.png, .jpeg, .gif]
                            panel.canChooseFiles = true
                            if panel.runModal() == .OK, let url = panel.url {
                                pipeline.addOverlay(StreamOverlay(type: .image, imagePath: url.path))
                            }
                        } label: {
                            Label("Image", systemImage: "photo")
                        }

                        Button {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .avi]
                            panel.canChooseFiles = true
                            if panel.runModal() == .OK, let url = panel.url {
                                pipeline.addOverlay(StreamOverlay(type: .media, mediaPath: url.path))
                            }
                        } label: {
                            Label("Video", systemImage: "film")
                        }

                        Divider()

                        Button {
                            let hasCaptions = pipeline.overlays.contains { $0.type == .captions }
                            if !hasCaptions {
                                pipeline.addOverlay(StreamOverlay(type: .captions))
                            }
                        } label: {
                            Label("Live Captions", systemImage: "captions.bubble")
                        }
                        .disabled(pipeline.overlays.contains { $0.type == .captions })

                        Button {
                            let hasChatOverlay = pipeline.overlays.contains { $0.type == .chat }
                            if !hasChatOverlay {
                                pipeline.addOverlay(StreamOverlay(type: .chat))
                            }
                        } label: {
                            Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                        }
                        .disabled(pipeline.overlays.contains { $0.type == .chat })

                        Button {
                            pipeline.showChecklistOnStream(true)
                        } label: {
                            Label("Checklist", systemImage: "checklist")
                        }
                        .disabled(pipeline.overlays.contains { $0.type == .checklist })
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.blue)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }

                if pipeline.overlays.isEmpty {
                    TabEmptyState(
                        icon: "square.on.square.dashed",
                        title: "No overlays",
                        subtitle: "Add text, images, or chat to your stream"
                    )
                }

                let items = pipeline.overlays
                VStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, overlay in
                        OverlayRow(overlay: overlay)
                            .opacity(draggingOverlayId == overlay.id ? 0.3 : 1.0)
                            .background(GeometryReader { geo in
                                Color.clear.onAppear {
                                    rowFrames[overlay.id] = geo.frame(in: .named("overlayList"))
                                }.onChange(of: geo.frame(in: .named("overlayList"))) { _, frame in
                                    rowFrames[overlay.id] = frame
                                }
                            })
                            .overlay(alignment: .top) {
                                if dropInsertIndex == index {
                                    OverlayDropIndicator()
                                        .offset(y: -2)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if index == items.count - 1 && dropInsertIndex == items.count {
                                    OverlayDropIndicator()
                                        .offset(y: 2)
                                }
                            }
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 5, coordinateSpace: .named("overlayList"))
                                    .onChanged { value in
                                        if draggingOverlayId == nil {
                                            draggingOverlayId = overlay.id
                                        }
                                        dragLocation = value.location
                                        updateDropTarget(at: value.location, items: items)
                                    }
                                    .onEnded { _ in
                                        endDrag(items: items)
                                    }
                            )
                    }
                }
                .coordinateSpace(name: "overlayList")
            }
            .padding(12)
            .padding(.top, 22)
        }
    }

    private func updateDropTarget(at location: CGPoint, items: [StreamOverlay]) {
        guard draggingOverlayId != nil else { return }

        for (index, overlay) in items.enumerated() {
            guard let frame = rowFrames[overlay.id] else { continue }
            if location.y >= frame.minY && location.y <= frame.maxY {
                let midY = frame.midY
                let newIndex = location.y < midY ? index : index + 1
                if dropInsertIndex != newIndex {
                    dropInsertIndex = newIndex
                }
                return
            }
        }

        if let firstFrame = items.first.flatMap({ rowFrames[$0.id] }), location.y < firstFrame.minY {
            dropInsertIndex = 0
        } else if let lastFrame = items.last.flatMap({ rowFrames[$0.id] }), location.y > lastFrame.maxY {
            dropInsertIndex = items.count
        }
    }

    private func endDrag(items: [StreamOverlay]) {
        guard let draggingId = draggingOverlayId,
              let insertIndex = dropInsertIndex,
              let sourceIndex = items.firstIndex(where: { $0.id == draggingId }) else {
            draggingOverlayId = nil
            dropInsertIndex = nil
            dragLocation = nil
            return
        }

        pipeline.moveOverlay(from: sourceIndex, to: insertIndex)

        draggingOverlayId = nil
        dropInsertIndex = nil
        dragLocation = nil
    }
}

struct OverlayDropIndicator: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.blue).frame(width: 6, height: 6)
            Rectangle().fill(.blue).frame(height: 2)
            Circle().fill(.blue).frame(width: 6, height: 6)
        }
        .padding(.horizontal, 4)
        .frame(height: 6)
    }
}

struct OverlayRow: View {
    @Environment(MediaPipeline.self) private var pipeline
    let overlay: StreamOverlay
    @State private var showStyleOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { overlay.isVisible },
                    set: { val in
                        var o = overlay
                        o.isVisible = val
                        pipeline.updateOverlay(o)
                    }
                ))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()

                Image(systemName: overlay.type.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))

                Text(overlayLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)

                Spacer()

                if hasStyleOptions(overlay.type) {
                    Button {
                        showStyleOptions.toggle()
                    } label: {
                        Image(systemName: "paintpalette")
                            .font(.system(size: 10))
                            .foregroundStyle(showStyleOptions ? .blue : .white.opacity(0.3))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }

                Button { pipeline.removeOverlay(overlay.id) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }

            switch overlay.type {
            case .text:
                TextOverlayControls(overlay: overlay)
            case .image:
                EmptyView()
            case .media:
                MediaOverlayControls(overlay: overlay)
            case .chat:
                ChatOverlayControls(overlay: overlay)
            case .captions:
                CaptionsOverlayControls(overlay: overlay)
            case .checklist:
                ChecklistOverlayControls(overlay: overlay)
            }

            if showStyleOptions {
                switch overlay.type {
                case .text:
                    TextStyleOptions(overlay: overlay)
                case .chat:
                    ChatStyleOptions(overlay: overlay)
                case .captions:
                    CaptionsStyleOptions(overlay: overlay)
                case .checklist:
                    CaptionsStyleOptions(overlay: overlay, showsAlignment: false)
                case .image, .media:
                    EmptyView()
                }
                if overlay.type != .captions {
                    AnimationOptions(overlay: overlay)
                }
            }

            Text("Drag on preview to position")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.2))
        }
        .onChange(of: pipeline.isOverlayDragging) { _, dragging in
            if dragging && showStyleOptions {
                showStyleOptions = false
            }
        }
        .padding(8)
        .background(.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var overlayLabel: String {
        switch overlay.type {
        case .text: return overlay.text.isEmpty ? "Text" : overlay.text
        case .image: return "Image"
        case .media:
            if overlay.mediaPath.isEmpty { return "Video" }
            return URL(fileURLWithPath: overlay.mediaPath).deletingPathExtension().lastPathComponent
        case .chat: return "Chat"
        case .captions: return "Live Captions"
        case .checklist: return "Checklist"
        }
    }

    private func hasStyleOptions(_ type: OverlayType) -> Bool {
        return true
    }
}

// MARK: - Text Overlay Controls

struct TextOverlayControls: View {
    @Environment(MediaPipeline.self) private var pipeline
    let overlay: StreamOverlay
    @State private var textFocusToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InlineTextField(
                text: Binding(
                    get: { overlay.text },
                    set: { val in
                        var o = overlay
                        o.text = val
                        pipeline.updateOverlay(o)
                    }
                ),
                placeholder: "Text",
                font: .systemFont(ofSize: 11),
                textColor: .white.withAlphaComponent(0.9),
                focusTrigger: textFocusToken
            )
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .focusesInlineField(on: $textFocusToken)

            TextStylePresetPicker(overlay: overlay)
        }
    }
}

struct TextStyleOptions: View {
    @Environment(MediaPipeline.self) private var pipeline
    let overlay: StreamOverlay

    private static let availableFonts: [String] = {
        let families = NSFontManager.shared.availableFontFamilies
        return families.sorted()
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Font").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                Picker("", selection: Binding(
                    get: { overlay.fontFamily },
                    set: { var o = overlay; o.fontFamily = $0; pipeline.updateOverlay(o) }
                )) {
                    Text("System").tag("")
                    Divider()
                    ForEach(Self.availableFonts, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            }

            Picker("", selection: Binding(
                get: { overlay.fontWeight },
                set: { var o = overlay; o.fontWeight = $0; pipeline.updateOverlay(o) }
            )) {
                ForEach(OverlayFontWeight.allCases) { w in
                    Text(w.rawValue).tag(w)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.mini)

            HStack {
                Label("Auto-fit", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { overlay.autoFitFont },
                    set: { newValue in
                        var o = overlay
                        o.autoFitFont = newValue
                        if !newValue {
                            // Seed the explicit size from the auto estimate so the text doesn't jump when the
                            // user takes manual control. Canvas height is 2160, styles default to maxRatio 0.62.
                            let rectHeight = 2160 * o.height
                            o.fontSize = max(10, min(300, rectHeight * 0.62))
                        }
                        pipeline.updateOverlay(o)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch).controlSize(.mini)
            }

            if !overlay.autoFitFont {
                SliderRow(label: "Size", value: Binding(
                    get: { overlay.fontSize },
                    set: { var o = overlay; o.fontSize = $0; pipeline.updateOverlay(o) }
                ), range: 10...300, unit: "pt")
            }

            HStack(spacing: 4) {
                Text("Align").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                Picker("", selection: Binding(
                    get: { overlay.textAlignment },
                    set: { var o = overlay; o.textAlignment = $0; pipeline.updateOverlay(o) }
                )) {
                    Image(systemName: "text.alignleft").tag(OverlayTextAlignment.left)
                    Image(systemName: "text.aligncenter").tag(OverlayTextAlignment.center)
                    Image(systemName: "text.alignright").tag(OverlayTextAlignment.right)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
            }

            SliderRow(label: "Padding", value: Binding(
                get: { overlay.horizontalPadding },
                set: { var o = overlay; o.horizontalPadding = $0; pipeline.updateOverlay(o) }
            ), range: 0...60, unit: "px")

            if overlay.textStyle.usesCustomColors {
                HStack(spacing: 4) {
                    Text("Text").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                    ColorPresetRow(
                        selected: overlay.textColor,
                        onChange: { color in
                            var o = overlay
                            o.textColor = color
                            pipeline.updateOverlay(o)
                        }
                    )
                    ColorWellButton(color: overlay.textColor) { color in
                        var o = overlay
                        o.textColor = color
                        pipeline.updateOverlay(o)
                    }
                }

                HStack(spacing: 4) {
                    Text("BG").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                    ColorPresetRow(
                        selected: overlay.backgroundColor,
                        onChange: { color in
                            var o = overlay
                            o.backgroundColor = OverlayColor(red: color.red, green: color.green, blue: color.blue, alpha: overlay.backgroundColor.alpha)
                            pipeline.updateOverlay(o)
                        }
                    )
                    Spacer()
                    Text("\(Int(overlay.backgroundColor.alpha * 100))%")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.25))
                }
                Slider(value: Binding(
                    get: { overlay.backgroundColor.alpha },
                    set: { val in
                        var o = overlay
                        o.backgroundColor.alpha = val
                        pipeline.updateOverlay(o)
                    }
                ), in: 0...1)
            }
        }
        .padding(6)
        .background(.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

struct TextStylePresetPicker: View {
    @Environment(MediaPipeline.self) private var pipeline
    let overlay: StreamOverlay

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(TextOverlayStyle.allCases) { style in
                TextStylePreviewTile(
                    style: style,
                    isSelected: overlay.textStyle == style
                ) {
                    var o = overlay
                    o.textStyle = style
                    pipeline.updateOverlay(o)
                }
            }
        }
    }
}

struct TextStylePreviewTile: View {
    let style: TextOverlayStyle
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.35))

                if let img = style.previewImage() {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                }
            }
            .aspectRatio(2.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? Color.blue : Color.white.opacity(0.10),
                            lineWidth: isSelected ? 1.5 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Media Overlay Controls

struct MediaOverlayControls: View {
    @Environment(MediaPipeline.self) private var pipeline
    let overlay: StreamOverlay

    private var player: MediaPlayer? {
        pipeline.metalCompositor.overlayMediaPlayer(for: overlay.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !overlay.mediaPath.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "film")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                    Text(URL(fileURLWithPath: overlay.mediaPath).lastPathComponent)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            HStack(spacing: 12) {
                Button {
                    if let player {
                        if case .playing = player.state {
                            player.pause()
                        } else {
                            player.play()
                        }
                    }
                } label: {
                    let isPlaying = { if case .playing = player?.state { return true }; return false }()
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)

                Button {
                    player?.stop()
                    if !overlay.mediaPath.isEmpty {
                        player?.load(url: URL(fileURLWithPath: overlay.mediaPath))
                    }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)

                Spacer()

                Toggle(isOn: Binding(
                    get: { overlay.mediaIsLooping },
                    set: {
                        var o = overlay
                        o.mediaIsLooping = $0
                        pipeline.updateOverlay(o)
                        player?.isLooping = $0
                    }
                )) {
                    Label("Loop", systemImage: "repeat")
                        .font(.system(size: 10))
                }
                .toggleStyle(.switch).controlSize(.mini)
            }

            Button {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .avi]
                panel.canChooseFiles = true
                if panel.runModal() == .OK, let url = panel.url {
                    var o = overlay
                    o.mediaPath = url.path
                    pipeline.updateOverlay(o)
                    pipeline.metalCompositor.clearOverlayCache(for: overlay.id)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9))
                    Text("Change Video")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.blue)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Chat Overlay Controls

struct ChatOverlayControls: View {
    @Environment(MediaPipeline.self) private var pipeline

    let overlay: StreamOverlay

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            YouTubeChatControls()
            TwitchChatControls()
        }
    }
}

struct YouTubeChatControls: View {
    @Environment(MediaPipeline.self) private var pipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red.opacity(0.7))
                Text("YouTube")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            if !pipeline.youtubeAuth.isSignedIn {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange.opacity(0.7))
                    Text("Sign in via Chat tab")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }
            } else if pipeline.youtubeChatService.isPolling {
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 5, height: 5)
                    Text("\(pipeline.youtubeChatService.messages.count) messages")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                }
            } else if pipeline.youtubeBroadcast != nil {
                Button {
                    pipeline.startYouTubeChat()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9))
                        Text("Start Chat")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.blue)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    Task { await pipeline.fetchActiveBroadcastChat() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 9))
                        Text("Connect to Active Broadcast")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.blue)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let error = pipeline.youtubeChatService.error {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.red.opacity(0.7))
                    .lineLimit(2)
            }
        }
    }
}

struct TwitchChatControls: View {
    @Environment(MediaPipeline.self) private var pipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.purple.opacity(0.7))
                Text("Twitch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            if !pipeline.twitchAuth.isSignedIn {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange.opacity(0.7))
                    Text("Sign in via Chat tab")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }
            } else if pipeline.twitchChatService.isConnected {
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 5, height: 5)
                    Text("\(pipeline.twitchChatService.messages.count) messages")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                }
            } else {
                Button {
                    let channel = pipeline.twitchAuth.username ?? ""
                    Task { await pipeline.connectTwitchChat(channel: channel) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 9))
                        Text("Connect Chat")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.purple)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let error = pipeline.twitchChatService.error {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.red.opacity(0.7))
                    .lineLimit(2)
            }
        }
    }
}

struct ChatStyleOptions: View {
    @Environment(MediaPipeline.self) private var pipeline
    let overlay: StreamOverlay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SliderRow(label: "Opacity", value: Binding(
                get: { overlay.opacity },
                set: { var o = overlay; o.opacity = $0; pipeline.updateOverlay(o) }
            ), range: 0.1...1.0, unit: "%", displayMultiplier: 100)

            SliderRow(label: "Font Size", value: Binding(
                get: { overlay.chatFontSize },
                set: { var o = overlay; o.chatFontSize = $0; pipeline.updateOverlay(o) }
            ), range: 10...30, unit: "px")

            HStack(spacing: 6) {
                Text("Messages")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                Stepper(
                    value: Binding(
                        get: { overlay.chatMaxMessages },
                        set: { var o = overlay; o.chatMaxMessages = $0; pipeline.updateOverlay(o) }
                    ),
                    in: 5...30
                ) {
                    Text("\(overlay.chatMaxMessages)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .controlSize(.mini)
            }

            HStack(spacing: 4) {
                Text("Text").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                ColorPresetRow(
                    selected: overlay.textColor,
                    onChange: { color in
                        var o = overlay
                        o.textColor = color
                        pipeline.updateOverlay(o)
                    }
                )
            }

            HStack(spacing: 4) {
                Text("BG").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                Spacer()
                Text("\(Int(overlay.backgroundColor.alpha * 100))%")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
            }
            Slider(value: Binding(
                get: { overlay.backgroundColor.alpha },
                set: {
                    var o = overlay
                    o.backgroundColor.alpha = $0
                    pipeline.updateOverlay(o)
                }
            ), in: 0...1)
        }
        .padding(6)
        .background(.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Shared Components

struct ColorWellButton: View {
    let color: OverlayColor
    let onChange: (OverlayColor) -> Void

    var body: some View {
        Button {
            let panel = NSColorPanel.shared
            panel.color = color.nsColor
            panel.setTarget(nil)
            panel.setAction(nil)
            panel.orderFront(nil)

            NotificationCenter.default.addObserver(
                forName: NSColorPanel.colorDidChangeNotification,
                object: panel,
                queue: .main
            ) { _ in
                let c = panel.color
                onChange(OverlayColor(nsColor: c))
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color(nsColor: color.nsColor))
                    .frame(width: 14, height: 14)
                Circle()
                    .stroke(.white.opacity(0.2), lineWidth: 0.5)
                    .frame(width: 14, height: 14)
                Image(systemName: "eyedropper")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
        .help("Pick custom color")
    }
}

struct ColorPresetRow: View {
    let selected: OverlayColor
    let onChange: (OverlayColor) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(OverlayColor.presets.enumerated()), id: \.offset) { _, color in
                Button {
                    onChange(color)
                } label: {
                    Circle()
                        .fill(Color(nsColor: color.nsColor))
                        .frame(width: 14, height: 14)
                        .overlay {
                            if isSelected(color) {
                                Circle().stroke(.white, lineWidth: 1.5)
                            }
                        }
                        .overlay {
                            if color.red < 0.1 && color.green < 0.1 && color.blue < 0.1 {
                                Circle().stroke(.white.opacity(0.2), lineWidth: 0.5)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func isSelected(_ color: OverlayColor) -> Bool {
        abs(selected.red - color.red) < 0.05 &&
        abs(selected.green - color.green) < 0.05 &&
        abs(selected.blue - color.blue) < 0.05
    }
}


// MARK: - Captions Controls

struct CaptionsOverlayControls: View {
    @Environment(MediaPipeline.self) private var pipeline
    let overlay: StreamOverlay

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(pipeline.captionService.isRunning ? .green : .white.opacity(0.2))
                    .frame(width: 6, height: 6)
                Text(pipeline.captionService.isRunning ? "Listening…" : "Idle")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
            }
            if !pipeline.captionService.currentText.isEmpty {
                Text(pipeline.captionService.currentText)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
            }
            if let err = pipeline.captionService.errorMessage {
                Text(err)
                    .font(.system(size: 9))
                    .foregroundStyle(.red.opacity(0.7))
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - Checklist Controls

struct ChecklistOverlayControls: View {
    @Environment(MediaPipeline.self) private var pipeline
    let overlay: StreamOverlay

    var body: some View {
        let notes = pipeline.studioNotes

        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: Binding(
                get: { overlay.text },
                set: { var o = overlay; o.text = $0; pipeline.updateOverlay(o) }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)

            HStack(spacing: 6) {
                Text(notes.items.isEmpty ? "No items" : "\(notes.doneCount) of \(notes.items.count) done")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Button {
                    NotesPopout.shared.open(pipeline: pipeline, tab: .checklist)
                } label: {
                    Text("Edit Items")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct CaptionsStyleOptions: View {
    @Environment(MediaPipeline.self) private var pipeline
    let overlay: StreamOverlay
    var showsAlignment = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SliderRow(label: "Size", value: Binding(
                get: { overlay.fontSize },
                set: { var o = overlay; o.fontSize = $0; pipeline.updateOverlay(o) }
            ), range: 16...80, unit: "px")

            Picker("", selection: Binding(
                get: { overlay.fontWeight },
                set: { var o = overlay; o.fontWeight = $0; pipeline.updateOverlay(o) }
            )) {
                ForEach(OverlayFontWeight.allCases) { w in Text(w.rawValue).tag(w) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.mini)

            if showsAlignment {
                HStack(spacing: 4) {
                    Text("Align").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                    Picker("", selection: Binding(
                        get: { overlay.textAlignment },
                        set: { var o = overlay; o.textAlignment = $0; pipeline.updateOverlay(o) }
                    )) {
                        Image(systemName: "text.alignleft").tag(OverlayTextAlignment.left)
                        Image(systemName: "text.aligncenter").tag(OverlayTextAlignment.center)
                        Image(systemName: "text.alignright").tag(OverlayTextAlignment.right)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                }
            }

            HStack(spacing: 4) {
                Text("Text").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                ColorPresetRow(selected: overlay.textColor, onChange: { color in
                    var o = overlay; o.textColor = color; pipeline.updateOverlay(o)
                })
                ColorWellButton(color: overlay.textColor) { color in
                    var o = overlay; o.textColor = color; pipeline.updateOverlay(o)
                }
            }

            HStack(spacing: 4) {
                Text("BG").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                ColorPresetRow(selected: overlay.backgroundColor, onChange: { color in
                    var o = overlay
                    o.backgroundColor = OverlayColor(red: color.red, green: color.green, blue: color.blue, alpha: overlay.backgroundColor.alpha)
                    pipeline.updateOverlay(o)
                })
            }
            Slider(value: Binding(
                get: { overlay.backgroundColor.alpha },
                set: { var o = overlay; o.backgroundColor.alpha = $0; pipeline.updateOverlay(o) }
            ), in: 0...1)
        }
        .padding(6)
        .background(.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Animation Options (shared by all overlay types)

struct AnimationOptions: View {
    @Environment(MediaPipeline.self) private var pipeline
    let overlay: StreamOverlay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
                Text("ANIMATION")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
            }

            HStack(spacing: 4) {
                Text("Entrance").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                Picker("", selection: Binding(
                    get: { overlay.entranceAnimation },
                    set: { var o = overlay; o.entranceAnimation = $0; pipeline.updateOverlay(o) }
                )) {
                    ForEach(OverlayEntranceAnimation.allCases) { a in
                        Text(a.rawValue).tag(a)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            if overlay.entranceAnimation != .none {
                SliderRow(label: "Duration", value: Binding(
                    get: { CGFloat(overlay.entranceDurationSeconds) },
                    set: { var o = overlay; o.entranceDurationSeconds = Double($0); pipeline.updateOverlay(o) }
                ), range: 0.1...3.0, unit: "s")
            }

            HStack(spacing: 4) {
                Text("Loop").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                Picker("", selection: Binding(
                    get: { overlay.loopAnimation },
                    set: { var o = overlay; o.loopAnimation = $0; pipeline.updateOverlay(o) }
                )) {
                    ForEach(OverlayLoopAnimation.allCases) { a in
                        Text(a.rawValue).tag(a)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            if overlay.loopAnimation != .none {
                SliderRow(label: "Speed", value: Binding(
                    get: { CGFloat(overlay.loopSpeed) },
                    set: { var o = overlay; o.loopSpeed = Double($0); pipeline.updateOverlay(o) }
                ), range: 0.2...4.0, unit: "x")
            }

            Button {
                pipeline.metalCompositor.replayOverlayAnimation(for: overlay.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9))
                    Text("Replay entrance")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.blue)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
