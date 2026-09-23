import SwiftUI
import AVFoundation

struct ContentView: View {
    @Environment(MediaPipeline.self) private var pipeline
    @Environment(DestinationStore.self) private var destinations
    @State private var showPanel = true
    @State private var showStats = false
    @State private var isCountingDown = false
    @State private var countdownValue = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.03, green: 0.03, blue: 0.04)
                .ignoresSafeArea(.all)

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        MetalPreviewView(
                            renderer: pipeline.renderer,
                            pipeline: pipeline
                        )
                            .aspectRatio(16/9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                if pipeline.isCameraLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                }
                            }

                        if showStats && pipeline.streamStatus.isLive {
                            StreamStatsOverlay(streamManager: pipeline.streamManager, onClose: {
                                withAnimation(.easeInOut(duration: 0.15)) { showStats = false }
                            })
                            .padding(8)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 32)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    LayoutBar()
                }

                if showPanel {
                    SidePanel()
                        .frame(width: 320)
                }
            }

            WindowDragArea().frame(height: 28).ignoresSafeArea()

            HStack(spacing: 0) {
                TrafficLights().padding(.leading, 7)

                Text("Streamif")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.leading, 8)

                Spacer()

                if pipeline.streamStatus.isLive {
                    LiveBadge()
                }

                if case .error(let msg) = pipeline.streamStatus {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(.red.opacity(0.8))
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.red.opacity(0.1))
                        .clipShape(Capsule())
                }

                if pipeline.streamStatus.isLive {
                    ToolbarButton(icon: "chart.bar") {
                        withAnimation(.easeInOut(duration: 0.15)) { showStats.toggle() }
                    }
                }

                ToolbarButton(icon: "sidebar.trailing") {
                    withAnimation(.easeInOut(duration: 0.2)) { showPanel.toggle() }
                }
                .padding(.trailing, 8)
            }
            .frame(height: 28)

            if isCountingDown {
                CountdownOverlay(seconds: countdownValue)
            }

            VStack(spacing: 6) {
                Spacer().frame(height: 32)
                if let msg = pipeline.micError {
                    WarningBanner(
                        icon: "mic.slash.fill",
                        message: msg,
                        onDismiss: { pipeline.micError = nil }
                    )
                }
                if let msg = pipeline.cameraError {
                    WarningBanner(
                        icon: "video.slash.fill",
                        message: msg,
                        onDismiss: { pipeline.cameraError = nil }
                    )
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .allowsHitTesting(pipeline.micError != nil || pipeline.cameraError != nil)
        }
        .ignoresSafeArea()
        .background(WindowAccessor().frame(width: 0, height: 0))
        .onKeyPress(.init("m")) {
            guard NSApp.keyWindow?.firstResponder is NSWindow || !(NSApp.keyWindow?.firstResponder is NSTextView) else {
                return .ignored
            }
            Task { await pipeline.toggleMute() }
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .goLive)) { _ in goLive() }
        .onReceive(NotificationCenter.default.publisher(for: .endStream)) { _ in endStream() }
    }

    func goLive() {
        let enabled = destinations.destinations.filter { $0.enabled }
        guard !enabled.isEmpty else { return }
        let countdown = AppSettings.shared.countdownSeconds
        Task {
            if countdown > 0 {
                isCountingDown = true
                for i in (1...countdown).reversed() {
                    countdownValue = i
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                isCountingDown = false
            }
            pipeline.startStreaming(destinations: enabled)
        }
    }

    func endStream() {
        Task { await pipeline.stopStreaming() }
    }
}

// MARK: - Layout Bar

struct LayoutBar: View {
    @Environment(MediaPipeline.self) private var pipeline
    @Environment(DestinationStore.self) private var destinations

    var body: some View {
        HStack(spacing: 6) {
            sceneButtons
            Spacer()
            screenBlurButton
            micButton
            streamButton
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(white: 0.035))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.03)).frame(height: 1) }
    }

    private var sceneButtons: some View {
        HStack(spacing: 4) {
            ForEach(pipeline.canvases.filter { $0.isBuiltIn && $0.id != Canvas.mediaBuiltInId }) { canvas in
                Button {
                    Task { await pipeline.setCanvas(canvas.id) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: canvas.icon)
                            .font(.system(size: 11))
                        Text(canvas.name)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(pipeline.activeCanvasId == canvas.id ? .blue.opacity(0.2) : .white.opacity(0.04))
                    .foregroundStyle(pipeline.activeCanvasId == canvas.id ? .blue : .white.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }

            MediaSceneButton()
            CanvasSceneButton()
        }
    }

    private var screenBlurButton: some View {
        Button {
            pipeline.toggleScreenBlur()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: pipeline.isScreenBlurred ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 11))
                Text("Privacy")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .foregroundStyle(pipeline.isScreenBlurred ? .orange : .white.opacity(0.5))
            .background(pipeline.isScreenBlurred ? .orange.opacity(0.15) : .white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var micButton: some View {
        Button {
            Task { await pipeline.toggleMute() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: pipeline.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 11))
                Text(pipeline.isMuted ? "Muted" : "Mic")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .foregroundStyle(pipeline.isMuted ? .red : .white.opacity(0.7))
            .background(alignment: .bottom) {
                if !pipeline.isMuted {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.green.opacity(0.3))
                            .frame(height: geo.size.height * CGFloat(min(1, max(0, pipeline.audioLevel))))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .animation(.linear(duration: 0.08), value: pipeline.audioLevel)
                    }
                }
            }
            .background(pipeline.isMuted ? .red.opacity(0.15) : .white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var streamButton: some View {
        if pipeline.streamStatus.isLive {
            GoLiveDockButton()
        } else if case .connecting = pipeline.streamStatus {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting...")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(.blue.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            let hasEnabled = destinations.destinations.contains { $0.enabled }
            Button {
                NotificationCenter.default.post(name: .goLive, object: nil)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill").font(.system(size: 10))
                    Text("Go Live").font(.system(size: 12, weight: .bold))
                }
                .padding(.horizontal, 20).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(hasEnabled ? .blue : .blue.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .disabled(!hasEnabled)
        }
    }
}


struct CanvasSceneButton: View {
    @Environment(MediaPipeline.self) private var pipeline

    private var freeformCanvases: [Canvas] {
        pipeline.canvases.filter { !$0.isBuiltIn }
    }

    private var activeFreeformCanvas: Canvas? {
        guard let id = pipeline.activeCanvasId else { return nil }
        return freeformCanvases.first { $0.id == id }
    }

    private var isActive: Bool {
        activeFreeformCanvas != nil
    }

    var body: some View {
        if freeformCanvases.isEmpty {
            Button {
                pipeline.createCanvas()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Canvas")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .foregroundStyle(.white.opacity(0.4))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .foregroundStyle(.white.opacity(0.18))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Create a new canvas")
        } else {
            DropdownButton(
                icon: "square.3.layers.3d",
                label: activeFreeformCanvas?.name ?? "Canvas",
                isActive: isActive
            ) {
                let menu = NSMenu()

                for canvas in freeformCanvases {
                    let item = NSMenuItem(title: canvas.name, action: nil, keyEquivalent: "")
                    if canvas.id == pipeline.activeCanvasId {
                        item.state = .on
                    }
                    let canvasId = canvas.id
                    item.representedObject = {
                        Task { await pipeline.setCanvas(canvasId) }
                    } as () -> Void
                    item.target = DropdownMenuDelegate.shared
                    item.action = #selector(DropdownMenuDelegate.menuItemClicked(_:))
                    menu.addItem(item)
                }

                menu.addItem(.separator())

                let newItem = NSMenuItem(title: "New Canvas", action: nil, keyEquivalent: "")
                newItem.representedObject = {
                    pipeline.createCanvas()
                } as () -> Void
                newItem.target = DropdownMenuDelegate.shared
                newItem.action = #selector(DropdownMenuDelegate.menuItemClicked(_:))
                menu.addItem(newItem)

                return menu
            }
        }
    }
}

struct MediaSceneButton: View {
    @Environment(MediaPipeline.self) private var pipeline

    private var isActive: Bool {
        pipeline.activeCanvasId == Canvas.mediaBuiltInId
    }

    private var activePresetName: String {
        pipeline.activeMediaPreset?.name ?? "Media"
    }

    var body: some View {
        DropdownButton(
            icon: "play.rectangle",
            label: isActive ? activePresetName : "Media",
            isActive: isActive
        ) {
            let menu = NSMenu()

            for preset in pipeline.savedMediaPresets {
                let item = NSMenuItem(title: preset.name, action: nil, keyEquivalent: "")
                if isActive && preset.id == pipeline.activeMediaPresetId {
                    item.state = .on
                }
                let presetId = preset.id
                item.representedObject = {
                    pipeline.switchToMediaPreset(presetId)
                } as () -> Void
                item.target = DropdownMenuDelegate.shared
                item.action = #selector(DropdownMenuDelegate.menuItemClicked(_:))
                menu.addItem(item)
            }

            menu.addItem(.separator())

            let newItem = NSMenuItem(title: "New Preset", action: nil, keyEquivalent: "")
            newItem.representedObject = {
                pipeline.createMediaPreset()
            } as () -> Void
            newItem.target = DropdownMenuDelegate.shared
            newItem.action = #selector(DropdownMenuDelegate.menuItemClicked(_:))
            menu.addItem(newItem)

            return menu
        }
    }
}

struct DockButton: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    var isAlert: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(label)
                    .font(.system(size: 8, weight: .medium))
            }
            .frame(width: 40, height: 36)
            .foregroundStyle(isAlert ? .red : (isActive ? .blue : .white.opacity(0.5)))
            .background(isAlert ? .red.opacity(0.15) : (isActive ? .blue.opacity(0.15) : .white.opacity(0.04)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

struct GoLiveDockButton: View {
    @State private var confirmEnd = false
    @State private var confirmTimer: Timer?

    var body: some View {
        Button {
            if confirmEnd {
                confirmTimer?.invalidate()
                NotificationCenter.default.post(name: .endStream, object: nil)
                confirmEnd = false
            } else {
                confirmEnd = true
                confirmTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
                    Task { @MainActor in confirmEnd = false }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: confirmEnd ? "stop.fill" : "stop.circle").font(.system(size: 10))
                Text(confirmEnd ? "Confirm End" : "End Stream").font(.system(size: 12, weight: .bold))
            }
            .padding(.horizontal, 20).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(confirmEnd ? .red : .red.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Reusable Components

struct CountdownOverlay: View {
    let seconds: Int
    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            Text("\(seconds)")
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .blue.opacity(0.5), radius: 20)
        }
    }
}

struct WarningBanner: View {
    let icon: String
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                }
        )
    }
}

struct ToolbarButton: View {
    let icon: String; let action: () -> Void
    @State private var isHovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(isHovered ? 0.8 : 0.4))
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(isHovered ? 0.08 : 0)))
        }
        .buttonStyle(.plain).focusable(false).onHover { isHovered = $0 }
    }
}

struct LiveBadge: View {
    @Environment(MediaPipeline.self) private var pipeline
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 7, height: 7).shadow(color: .red.opacity(0.6), radius: 4)
            Text("LIVE").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.red)
            Text(fmt(elapsed)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.red.opacity(0.8))
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.red.opacity(0.1)).clipShape(Capsule())
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in
                    if case .live(let s) = pipeline.streamStatus { elapsed = Date().timeIntervalSince(s) }
                }
            }
        }
        .onDisappear { timer?.invalidate() }
    }
    private func fmt(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d:%02d", Int(t)/3600, (Int(t)%3600)/60, Int(t)%60)
    }
}

struct AudioMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.04))
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [.green, level > 0.7 ? .yellow : .green], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, level))))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }.frame(height: 3)
    }
}

struct DevicePicker: View {
    let icon: String; let items: [(String, String)]; @Binding var selection: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
            Picker("", selection: $selection) {
                ForEach(items, id: \.0) { Text($0.1).tag($0.0) }
            }.labelsHidden().frame(maxWidth: .infinity)
        }
    }
}

class DropdownMenuDelegate: NSObject {
    static let shared = DropdownMenuDelegate()
    @objc func menuItemClicked(_ sender: NSMenuItem) {
        if let action = sender.representedObject as? () -> Void {
            action()
        }
    }
}

struct DropdownButton: View {
    let icon: String
    var label: String? = nil
    var isActive: Bool = false
    let menuBuilder: () -> NSMenu

    var body: some View {
        MenuAnchorView(menuBuilder: menuBuilder) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6, weight: .bold))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .foregroundStyle(isActive ? .blue : .white.opacity(0.5))
            .background(isActive ? .blue.opacity(0.2) : .white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
    }
}

struct MenuAnchorView<Content: View>: NSViewRepresentable {
    let menuBuilder: () -> NSMenu
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> MenuAnchorNSView<Content> {
        let view = MenuAnchorNSView<Content>()
        view.menuBuilder = menuBuilder
        view.rootView = content()
        return view
    }

    func updateNSView(_ nsView: MenuAnchorNSView<Content>, context: Context) {
        nsView.menuBuilder = menuBuilder
        nsView.rootView = content()
    }
}

class MenuAnchorNSView<Content: View>: NSView {
    var menuBuilder: (() -> NSMenu)?
    var rootView: Content? {
        didSet { updateHostingView() }
    }
    private var hostingView: NSHostingView<Content>?

    private func updateHostingView() {
        guard let rootView else { return }

        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let hv = NSHostingView(rootView: rootView)
            hv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hv)
            NSLayoutConstraint.activate([
                hv.leadingAnchor.constraint(equalTo: leadingAnchor),
                hv.trailingAnchor.constraint(equalTo: trailingAnchor),
                hv.topAnchor.constraint(equalTo: topAnchor),
                hv.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            hostingView = hv
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let menu = menuBuilder?() else { return }
        let point = NSPoint(x: 0, y: bounds.height)
        menu.popUp(positioning: nil, at: point, in: self)
    }
}

