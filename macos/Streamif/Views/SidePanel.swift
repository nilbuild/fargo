import SwiftUI
import UniformTypeIdentifiers

struct SidePanel: View {
    @Environment(MediaPipeline.self) private var pipeline
    @Environment(DestinationStore.self) private var store
    @State private var selectedTab: PanelTab = .destinations

    enum PanelTab: String, CaseIterable {
        case destinations, sources, canvas, overlays, chat, audio, sounds

        var icon: String {
            switch self {
            case .destinations: return "antenna.radiowaves.left.and.right"
            case .overlays: return "star.square.on.square"
            case .chat: return "bubble.left.and.bubble.right"
            case .audio: return "mic.fill"
            case .canvas: return "rectangle.inset.filled"
            case .sounds: return "music.note.list"
            case .sources: return "square.3.layers.3d"
            }
        }

        var label: String {
            switch self {
            case .destinations: return "Destinations"
            case .overlays: return "Overlays"
            case .chat: return "Chat"
            case .audio: return "Audio"
            case .canvas: return "Canvas"
            case .sounds: return "Sound Board"
            case .sources: return "Sources"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                switch selectedTab {
                case .destinations:
                    DestinationsTab()
                case .overlays:
                    OverlaysPanel()
                case .chat:
                    ChatTab()
                case .audio:
                    AudioTab()
                case .canvas:
                    CanvasTab()
                case .sounds:
                    SoundsTab()
                case .sources:
                    CanvasSourcesTab()
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Color(white: 0.05))

            VStack(spacing: 2) {
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    Button { selectedTab = tab } label: {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13))
                            .frame(width: 32, height: 32)
                            .foregroundStyle(selectedTab == tab ? .blue : .white.opacity(0.35))
                            .background(selectedTab == tab ? .blue.opacity(0.12) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(tab.label)
                }
                Spacer()
            }
            .padding(.top, 34).padding(.horizontal, 4)
            .frame(width: 40)
            .background(Color(white: 0.04))
        }
        .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.06)).frame(width: 1) }
        .onChange(of: pipeline.activeCanvasId) { _, _ in
            selectedTab = .sources
        }
        .onChange(of: pipeline.requestedSidebarTab) { _, tab in
            guard let tab, let panelTab = PanelTab(rawValue: tab) else { return }
            selectedTab = panelTab
            pipeline.requestedSidebarTab = nil
        }
    }
}

// MARK: - Destinations Tab

struct DestinationsTab: View {
    @Environment(MediaPipeline.self) private var pipeline
    @Environment(DestinationStore.self) private var store
    @State private var showAddForm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                TabSectionHeader(title: "DESTINATIONS") {
                    if !pipeline.streamStatus.isLive {
                        Button { showAddForm.toggle() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.blue)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }

                ForEach(store.destinations) { dest in
                    DestinationCard(destination: dest)
                }

                if showAddForm {
                    AddDestinationForm(
                        onAdd: { preset, url, key, quality in
                            store.add(from: preset, rtmpUrl: url, streamKey: key, quality: quality)
                            showAddForm = false
                        },
                        onCancel: { showAddForm = false }
                    )
                }

                if store.destinations.isEmpty && !showAddForm {
                    TabEmptyState(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "No destinations",
                        action: ("Add one", { showAddForm = true })
                    )
                }
            }
            .padding(12)
            .padding(.top, 22)
        }
    }
}

// MARK: - Audio Tab

struct AudioTab: View {
    @Environment(MediaPipeline.self) private var pipeline

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TabSectionHeader(title: "AUDIO")

                SidebarCard {
                    CardSectionLabel(title: "MICROPHONE")

                    DevicePicker(icon: "mic",
                        items: pipeline.microphones.map { ($0.id, $0.name) },
                        selection: Binding(
                            get: { pipeline.selectedMicId },
                            set: { id in Task { await pipeline.selectMicrophone(id) } }
                        ))

                    SliderRow(label: "Volume", value: Binding(
                        get: { CGFloat(pipeline.micVolume) },
                        set: { pipeline.micVolume = Float($0) }
                    ), range: 0...2, unit: "%", displayMultiplier: 100, valueWidth: 32)

                    HStack {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform.badge.minus")
                                .font(.system(size: 10))
                            Text("Noise Suppression")
                                .font(.system(size: 10))
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { pipeline.noiseSuppression },
                            set: { pipeline.noiseSuppression = $0 }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch).controlSize(.mini)
                    }
                }

                SidebarCard {
                    HStack {
                        CardSectionLabel(title: "SYSTEM AUDIO")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { pipeline.systemAudioEnabled },
                            set: { pipeline.systemAudioEnabled = $0 }
                        ))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    }

                    if pipeline.systemAudioEnabled {
                        SliderRow(label: "Volume", value: Binding(
                            get: { CGFloat(pipeline.systemVolume) },
                            set: { pipeline.systemVolume = Float($0) }
                        ), range: 0...2, unit: "%", displayMultiplier: 100, valueWidth: 32)
                    }
                }

                SidebarCard {
                    HStack {
                        CardSectionLabel(title: "COMPRESSOR")
                        Spacer()
                        if pipeline.compressorEnabled && (pipeline.compressorThreshold != -20.0 || pipeline.compressorRatio != 4.0 || pipeline.compressorMakeupGain != 0.0) {
                            Button {
                                pipeline.compressorThreshold = -20.0
                                pipeline.compressorRatio = 4.0
                                pipeline.compressorMakeupGain = 0.0
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            .buttonStyle(.plain)
                            .help("Reset compressor values")
                        }
                        Toggle("", isOn: Binding(
                            get: { pipeline.compressorEnabled },
                            set: { pipeline.compressorEnabled = $0 }
                        ))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    }

                    if pipeline.compressorEnabled {
                        Text("Evens out volume peaks so loud sounds don't clip and quiet parts stay audible")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.25))

                        SliderRow(label: "Threshold", value: Binding(
                            get: { CGFloat(pipeline.compressorThreshold) },
                            set: { pipeline.compressorThreshold = Float($0) }
                        ), range: -50...0, unit: "dB", displayMultiplier: 1, valueWidth: 40)

                        SliderRow(label: "Ratio", value: Binding(
                            get: { CGFloat(pipeline.compressorRatio) },
                            set: { pipeline.compressorRatio = Float($0) }
                        ), range: 1...20, unit: ":1", displayMultiplier: 1, valueWidth: 40)

                        SliderRow(label: "Makeup", value: Binding(
                            get: { CGFloat(pipeline.compressorMakeupGain) },
                            set: { pipeline.compressorMakeupGain = Float($0) }
                        ), range: 0...24, unit: "dB", displayMultiplier: 1, valueWidth: 40)
                    }
                }

                SidebarCard {
                    HStack {
                        CardSectionLabel(title: "EQUALIZER")
                        Spacer()
                        if pipeline.eqEnabled && (pipeline.eqLowGain != 0.0 || pipeline.eqMidGain != 0.0 || pipeline.eqHighGain != 0.0) {
                            Button {
                                pipeline.eqLowGain = 0.0
                                pipeline.eqMidGain = 0.0
                                pipeline.eqHighGain = 0.0
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            .buttonStyle(.plain)
                            .help("Reset equalizer values")
                        }
                        Toggle("", isOn: Binding(
                            get: { pipeline.eqEnabled },
                            set: { pipeline.eqEnabled = $0 }
                        ))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    }

                    if pipeline.eqEnabled {
                        Text("Adjust frequency balance - boost bass, tame harshness, or add clarity")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.25))

                        SliderRow(label: "Low (200Hz)", value: Binding(
                            get: { CGFloat(pipeline.eqLowGain) },
                            set: { pipeline.eqLowGain = Float($0) }
                        ), range: -12...12, unit: "dB", displayMultiplier: 1, valueWidth: 40)

                        SliderRow(label: "Mid (1kHz)", value: Binding(
                            get: { CGFloat(pipeline.eqMidGain) },
                            set: { pipeline.eqMidGain = Float($0) }
                        ), range: -12...12, unit: "dB", displayMultiplier: 1, valueWidth: 40)

                        SliderRow(label: "High (5kHz)", value: Binding(
                            get: { CGFloat(pipeline.eqHighGain) },
                            set: { pipeline.eqHighGain = Float($0) }
                        ), range: -12...12, unit: "dB", displayMultiplier: 1, valueWidth: 40)
                    }
                }

            }
            .padding(12)
            .padding(.top, 22)
        }
    }
}

// MARK: - Canvas Tab

struct CanvasTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                CanvasBackgroundCard()
            }
            .padding(12)
            .padding(.top, 22)
        }
    }
}

// MARK: - Canvas Background

struct CanvasBackgroundCard: View {
    @Environment(MediaPipeline.self) private var pipeline

    private var hasChanges: Bool {
        let d = CanvasConfig()
        let c = pipeline.canvasConfig
        return c.backgroundType != d.backgroundType
            || c.padding != d.padding
            || c.cornerRadius != d.cornerRadius
    }

    var body: some View {
        SidebarCard {
            HStack {
                CardSectionLabel(title: "CANVAS")
                Spacer()
                if hasChanges {
                    Button {
                        pipeline.canvasConfig = CanvasConfig()
                        pipeline.metalCompositor.clearBackgroundCache()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .help("Reset canvas settings")
                }
            }

            HStack {
                Label("Background", systemImage: "photo")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Picker("", selection: Binding(
                    get: { pipeline.canvasConfig.backgroundType },
                    set: {
                        pipeline.canvasConfig.backgroundType = $0
                        pipeline.metalCompositor.clearBackgroundCache()
                    }
                )) {
                    ForEach(CanvasBackgroundType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            switch pipeline.canvasConfig.backgroundType {
            case .none:
                EmptyView()

            case .solidColor:
                ColorSwatchGrid(presets: ColorPresets.solids) { color in
                    pipeline.canvasConfig.solidColor = color
                    pipeline.metalCompositor.clearBackgroundCache()
                }

                ColorPicker("Custom", selection: Binding(
                    get: { Color(nsColor: pipeline.canvasConfig.solidColor.nsColor) },
                    set: { newColor in
                        let nsColor = NSColor(newColor).usingColorSpace(.deviceRGB) ?? NSColor(newColor)
                        pipeline.canvasConfig.solidColor = CodableColor(nsColor: nsColor)
                        pipeline.metalCompositor.clearBackgroundCache()
                    }
                ))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))

            case .gradient:
                GradientSwatchGrid { gradient in
                    pipeline.canvasConfig.gradient = gradient
                    pipeline.metalCompositor.clearBackgroundCache()
                }

                HStack(spacing: 8) {
                    Text("Custom")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))

                    ColorPicker("", selection: Binding(
                        get: { Color(nsColor: pipeline.canvasConfig.gradient.color1.nsColor) },
                        set: { newColor in
                            let nsColor = NSColor(newColor).usingColorSpace(.deviceRGB) ?? NSColor(newColor)
                            pipeline.canvasConfig.gradient.color1 = CodableColor(nsColor: nsColor)
                            pipeline.metalCompositor.clearBackgroundCache()
                        }
                    ))
                    .labelsHidden()

                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))

                    ColorPicker("", selection: Binding(
                        get: { Color(nsColor: pipeline.canvasConfig.gradient.color2.nsColor) },
                        set: { newColor in
                            let nsColor = NSColor(newColor).usingColorSpace(.deviceRGB) ?? NSColor(newColor)
                            pipeline.canvasConfig.gradient.color2 = CodableColor(nsColor: nsColor)
                            pipeline.metalCompositor.clearBackgroundCache()
                        }
                    ))
                    .labelsHidden()

                    Spacer()
                }

                SliderRow(label: "Angle", value: Binding(
                    get: { pipeline.canvasConfig.gradient.angle },
                    set: {
                        pipeline.canvasConfig.gradient.angle = $0
                        pipeline.metalCompositor.clearBackgroundCache()
                    }
                ), range: 0...360, unit: "\u{00B0}", displayMultiplier: 1, valueWidth: 32)

            case .wallpaper:
                WallpaperGrid()

            case .customImage:
                HStack {
                    if let path = pipeline.canvasConfig.customImagePath {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            pipeline.canvasConfig.customImagePath = nil
                            pipeline.canvasConfig.backgroundType = .none
                            pipeline.metalCompositor.clearBackgroundCache()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Spacer()
                    }
                    Button("Choose...") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            pipeline.canvasConfig.customImagePath = url.path
                            pipeline.metalCompositor.clearBackgroundCache()
                        }
                    }
                    .font(.system(size: 11))
                    .controlSize(.small)
                }
            }

            SliderRow(label: "Padding", value: Binding(
                get: { pipeline.canvasConfig.padding },
                set: { pipeline.canvasConfig.padding = $0 }
            ), range: 0...300, unit: "px")

            SliderRow(label: "Corners", value: Binding(
                get: { pipeline.canvasConfig.cornerRadius },
                set: { pipeline.canvasConfig.cornerRadius = $0 }
            ), range: 0...200, unit: "px")
        }
    }
}

// MARK: - Color/Gradient Presets

enum ColorPresets {
    static let solids: [CodableColor] = [
        CodableColor(r: 0.05, g: 0.05, b: 0.05),   // Near black
        CodableColor(r: 0.15, g: 0.15, b: 0.15),   // Dark gray
        CodableColor(r: 0.25, g: 0.25, b: 0.30),   // Slate
        CodableColor(r: 1.0, g: 1.0, b: 1.0),      // White
        CodableColor(r: 0.10, g: 0.10, b: 0.25),   // Dark navy
        CodableColor(r: 0.15, g: 0.25, b: 0.50),   // Blue
        CodableColor(r: 0.20, g: 0.50, b: 0.85),   // Bright blue
        CodableColor(r: 0.10, g: 0.30, b: 0.30),   // Teal
        CodableColor(r: 0.10, g: 0.25, b: 0.15),   // Dark green
        CodableColor(r: 0.20, g: 0.55, b: 0.30),   // Green
        CodableColor(r: 0.30, g: 0.10, b: 0.25),   // Purple
        CodableColor(r: 0.50, g: 0.15, b: 0.30),   // Magenta
        CodableColor(r: 0.55, g: 0.20, b: 0.15),   // Red
        CodableColor(r: 0.60, g: 0.35, b: 0.10),   // Orange
        CodableColor(r: 0.55, g: 0.50, b: 0.15),   // Gold
        CodableColor(r: 0.25, g: 0.20, b: 0.15),   // Brown
    ]
}

struct GradientPreset: Identifiable {
    let id: String
    let gradient: CanvasGradient

    static let all: [GradientPreset] = [
        GradientPreset(id: "midnight", gradient: CanvasGradient(
            color1: CodableColor(r: 0.05, g: 0.05, b: 0.20),
            color2: CodableColor(r: 0.0, g: 0.0, b: 0.05), angle: 180)),
        GradientPreset(id: "ocean", gradient: CanvasGradient(
            color1: CodableColor(r: 0.10, g: 0.30, b: 0.60),
            color2: CodableColor(r: 0.05, g: 0.10, b: 0.25), angle: 135)),
        GradientPreset(id: "aurora", gradient: CanvasGradient(
            color1: CodableColor(r: 0.10, g: 0.50, b: 0.45),
            color2: CodableColor(r: 0.20, g: 0.10, b: 0.40), angle: 135)),
        GradientPreset(id: "sunset", gradient: CanvasGradient(
            color1: CodableColor(r: 0.70, g: 0.30, b: 0.20),
            color2: CodableColor(r: 0.30, g: 0.10, b: 0.35), angle: 135)),
        GradientPreset(id: "ember", gradient: CanvasGradient(
            color1: CodableColor(r: 0.60, g: 0.20, b: 0.10),
            color2: CodableColor(r: 0.15, g: 0.05, b: 0.05), angle: 180)),
        GradientPreset(id: "forest", gradient: CanvasGradient(
            color1: CodableColor(r: 0.10, g: 0.35, b: 0.15),
            color2: CodableColor(r: 0.05, g: 0.10, b: 0.08), angle: 180)),
        GradientPreset(id: "lavender", gradient: CanvasGradient(
            color1: CodableColor(r: 0.45, g: 0.30, b: 0.65),
            color2: CodableColor(r: 0.15, g: 0.10, b: 0.25), angle: 135)),
        GradientPreset(id: "steel", gradient: CanvasGradient(
            color1: CodableColor(r: 0.30, g: 0.32, b: 0.35),
            color2: CodableColor(r: 0.10, g: 0.10, b: 0.12), angle: 180)),
        GradientPreset(id: "candy", gradient: CanvasGradient(
            color1: CodableColor(r: 0.85, g: 0.35, b: 0.50),
            color2: CodableColor(r: 0.40, g: 0.20, b: 0.60), angle: 135)),
        GradientPreset(id: "solar", gradient: CanvasGradient(
            color1: CodableColor(r: 0.80, g: 0.55, b: 0.10),
            color2: CodableColor(r: 0.50, g: 0.15, b: 0.10), angle: 135)),
        GradientPreset(id: "ice", gradient: CanvasGradient(
            color1: CodableColor(r: 0.60, g: 0.80, b: 0.95),
            color2: CodableColor(r: 0.15, g: 0.20, b: 0.40), angle: 180)),
        GradientPreset(id: "noir", gradient: CanvasGradient(
            color1: CodableColor(r: 0.20, g: 0.20, b: 0.20),
            color2: CodableColor(r: 0.02, g: 0.02, b: 0.02), angle: 180)),
    ]
}

private struct ColorSwatchGrid: View {
    let presets: [CodableColor]
    let onSelect: (CodableColor) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(presets.enumerated()), id: \.offset) { _, color in
                Button { onSelect(color) } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: color.nsColor))
                        .frame(height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct GradientSwatchGrid: View {
    let onSelect: (CanvasGradient) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(GradientPreset.all) { preset in
                Button { onSelect(preset.gradient) } label: {
                    let g = preset.gradient
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(
                            colors: [Color(nsColor: g.color1.nsColor), Color(nsColor: g.color2.nsColor)],
                            startPoint: gradientStart(angle: g.angle),
                            endPoint: gradientEnd(angle: g.angle)
                        ))
                        .frame(height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func gradientStart(angle: CGFloat) -> UnitPoint {
        let rad = angle * .pi / 180.0
        return UnitPoint(x: 0.5 - cos(rad) * 0.5, y: 0.5 - sin(rad) * 0.5)
    }

    private func gradientEnd(angle: CGFloat) -> UnitPoint {
        let rad = angle * .pi / 180.0
        return UnitPoint(x: 0.5 + cos(rad) * 0.5, y: 0.5 + sin(rad) * 0.5)
    }
}

private struct WallpaperGrid: View {
    @Environment(MediaPipeline.self) private var pipeline

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(WallpaperPreset.all) { preset in
                WallpaperThumbnail(preset: preset, isSelected: pipeline.canvasConfig.wallpaperName == preset.id) {
                    pipeline.canvasConfig.wallpaperName = preset.id
                    pipeline.metalCompositor.clearBackgroundCache()
                }
            }
        }
    }
}

private struct WallpaperThumbnail: View {
    let preset: WallpaperPreset
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                if let path = Bundle.main.path(forResource: preset.filename, ofType: nil, inDirectory: "Wallpapers"),
                   let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(height: 48)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(.white.opacity(0.05))
                        .frame(height: 48)
                }

                Text(preset.name)
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 2)
                    .padding(3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? .blue : .white.opacity(0.1), lineWidth: isSelected ? 2 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Media Preset Editor

struct MediaPresetEditor: View {
    @Environment(MediaPipeline.self) private var pipeline
    @State private var presetName = ""
    @State private var lastPresetId: UUID?
    @State private var presetNameFocusToken = 0

    var body: some View {
        if let preset = pipeline.activeMediaPreset {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))

                InlineTextField(
                    text: $presetName,
                    font: .systemFont(ofSize: 12, weight: .semibold),
                    textColor: .white.withAlphaComponent(0.7),
                    focusTrigger: presetNameFocusToken,
                    onCommit: {
                        if !presetName.isEmpty {
                            pipeline.renameMediaPreset(preset.id, name: presetName)
                        } else {
                            presetName = preset.name
                        }
                    },
                    onCancel: {
                        presetName = preset.name
                    }
                )
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusesInlineField(on: $presetNameFocusToken)

                Spacer()

                Button {
                    pipeline.deleteMediaPreset(preset.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.25))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete preset")
            }
            .padding(.horizontal, 2)
            .onAppear {
                presetName = preset.name
                lastPresetId = preset.id
            }
            .onChange(of: pipeline.activeMediaPresetId) { _, newId in
                if let newId, let p = pipeline.savedMediaPresets.first(where: { $0.id == newId }) {
                    presetName = p.name
                    lastPresetId = newId
                }
            }

            SidebarCard {
                CardSectionLabel(title: "MEDIA")

                if let path = preset.filePath, preset.isImage {
                    if let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                if preset.isVideo {
                    MediaPlayerControls()
                }

                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [
                        .png, .jpeg, .tiff, .gif, .image,
                        .movie, .mpeg4Movie, .quickTimeMovie, .avi,
                    ]
                    panel.canChooseFiles = true
                    if panel.runModal() == .OK, let url = panel.url {
                        pipeline.setMediaPresetFile(preset.id, path: url.path)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: preset.hasFile ? "arrow.triangle.2.circlepath" : "plus.circle")
                            .font(.system(size: 10))
                        Text(preset.hasFile ? "Change Image" : "Choose Image")
                            .font(.system(size: 10))
                        Spacer()
                        if preset.hasFile {
                            Text(URL(fileURLWithPath: preset.filePath!).lastPathComponent)
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.3))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Camera Appearance Controls (per-source - used inside CanvasSourceControls)

private struct AppearanceControls: View {
    @Environment(MediaPipeline.self) private var pipeline
    var mirror: Binding<Bool>? = nil

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(ColorFilterPreset.allCases) { preset in
                Button {
                    if preset != .none {
                        pipeline.colorCorrectionEnabled = false
                    }
                    pipeline.colorFilterPreset = preset
                } label: {
                    Text(preset.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(pipeline.colorFilterPreset == preset
                                    ? Color.blue.opacity(0.3)
                                    : Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(pipeline.colorFilterPreset == preset
                                    ? Color.white.opacity(0.3)
                                    : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.top, 4)

        HStack {
            Label("Background", systemImage: "person.and.background.dotted")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Picker("", selection: Binding(
                get: { pipeline.backgroundMode },
                set: { pipeline.backgroundMode = $0 }
            )) {
                ForEach(BackgroundMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.top, 6)

        if let mirror {
            HStack {
                Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .font(.system(size: 11))
                Spacer()
                Toggle("", isOn: mirror)
                    .labelsHidden()
                    .toggleStyle(.switch).controlSize(.mini)
            }
            .padding(.top, 6)
        }

        HStack {
            Label("Skin Smoothing", systemImage: "face.dashed")
                .font(.system(size: 11))
            Spacer()
            Toggle("", isOn: Binding(
                get: { pipeline.skinSmoothingEnabled },
                set: { pipeline.skinSmoothingEnabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch).controlSize(.mini)
        }
        .padding(.top, 6)

        if pipeline.skinSmoothingEnabled {
            SliderRow(label: "Smoothness", value: Binding(
                get: { CGFloat(pipeline.skinSmoothingIntensity) },
                set: { pipeline.skinSmoothingIntensity = Float($0) }
            ), range: 0...1, unit: "%", displayMultiplier: 100)
        }

        HStack(spacing: 6) {
            Label("Advanced", systemImage: "slider.horizontal.3")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            if pipeline.colorCorrectionEnabled && hasAdvancedChanges {
                Button {
                    pipeline.colorBrightness = 0.0
                    pipeline.colorContrast = 1.0
                    pipeline.colorSaturation = 1.0
                    pipeline.colorGamma = 1.0
                    pipeline.colorTemperature = 0.0
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Reset advanced filters")
            }
            Toggle("", isOn: Binding(
                get: { pipeline.colorCorrectionEnabled },
                set: {
                    pipeline.colorCorrectionEnabled = $0
                    if $0 { pipeline.colorFilterPreset = .none }
                }
            ))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.top, 6)

        if pipeline.colorCorrectionEnabled {
            ColorCorrectionSliders()
        }
    }

    private var hasAdvancedChanges: Bool {
        return pipeline.colorBrightness != 0.0
            || pipeline.colorContrast != 1.0
            || pipeline.colorSaturation != 1.0
            || pipeline.colorGamma != 1.0
            || pipeline.colorTemperature != 0.0
    }
}

private struct ColorCorrectionSliders: View {
    @Environment(MediaPipeline.self) private var pipeline

    var body: some View {
        SliderRow(label: "Brightness", value: Binding(
            get: { CGFloat(pipeline.colorBrightness) },
            set: { pipeline.colorBrightness = Float($0) }
        ), range: -0.5...0.5, unit: "", displayMultiplier: 100, valueWidth: 32)

        SliderRow(label: "Contrast", value: Binding(
            get: { CGFloat(pipeline.colorContrast) },
            set: { pipeline.colorContrast = Float($0) }
        ), range: 0.5...2.0, unit: "", displayMultiplier: 100, valueWidth: 32)

        SliderRow(label: "Saturation", value: Binding(
            get: { CGFloat(pipeline.colorSaturation) },
            set: { pipeline.colorSaturation = Float($0) }
        ), range: 0...2.0, unit: "", displayMultiplier: 100, valueWidth: 32)

        SliderRow(label: "Gamma", value: Binding(
            get: { CGFloat(pipeline.colorGamma) },
            set: { pipeline.colorGamma = Float($0) }
        ), range: 0.3...3.0, unit: "", displayMultiplier: 100, valueWidth: 32)

        SliderRow(label: "Temp", value: Binding(
            get: { CGFloat(pipeline.colorTemperature) },
            set: { pipeline.colorTemperature = Float($0) }
        ), range: -1.0...1.0, unit: "", displayMultiplier: 100, valueWidth: 32)
    }
}

// MARK: - Shared Media Player Controls

struct MediaPlayerControls: View {
    @Environment(MediaPipeline.self) private var pipeline
    var onFileChosen: ((URL) -> Void)? = nil

    var body: some View {
        Button {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .avi]
            panel.canChooseFiles = true
            if panel.runModal() == .OK, let url = panel.url {
                pipeline.loadMedia(url: url)
                onFileChosen?(url)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "film")
                    .font(.system(size: 10))
                Text(pipeline.mediaUrl?.lastPathComponent ?? "Choose Video File")
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)

        if pipeline.mediaUrl != nil {
            HStack(spacing: 16) {
                Spacer()
                Button {
                    if case .playing = pipeline.mediaPlayerState {
                        pipeline.pauseMedia()
                    } else {
                        pipeline.playMedia()
                    }
                } label: {
                    let isPlaying = { if case .playing = pipeline.mediaPlayerState { return true }; return false }()
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.7))
                }.buttonStyle(.plain)

                Button { pipeline.stopMedia() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }.buttonStyle(.plain)
                Spacer()
            }

            HStack {
                Label("Loop", systemImage: "repeat")
                    .font(.system(size: 10))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { pipeline.mediaPlayer.isLooping },
                    set: { pipeline.mediaPlayer.isLooping = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch).controlSize(.mini)
            }
        }
    }
}

// MARK: - Shared Screen Source Picker (sidebar-width)

struct ScreenSourcePickerInline: View {
    let pipeline: MediaPipeline

    private var selectionBinding: Binding<String> {
        Binding(
            get: {
                switch pipeline.selectedScreenSource {
                case .display(let id): return "d:\(id)"
                case .window(let id): return "w:\(id)"
                case nil: return ""
                }
            },
            set: { newValue in
                if newValue.hasPrefix("d:"), let id = UInt32(newValue.dropFirst(2)) {
                    Task { await pipeline.selectScreenSource(.display(id)) }
                } else if newValue.hasPrefix("w:"), let id = UInt32(newValue.dropFirst(2)) {
                    Task { await pipeline.selectScreenSource(.window(id)) }
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
            Picker("", selection: selectionBinding) {
                // Hidden placeholder for the pre-discovery state. Once displays and windows load,
                // the user always has a real selection and this row disappears.
                if pipeline.displays.isEmpty && pipeline.windows.isEmpty {
                    Text("Loading…").tag("")
                }
                if !pipeline.displays.isEmpty {
                    Section("Displays") {
                        ForEach(pipeline.displays, id: \.displayID) { display in
                            Text("Display \(display.displayID)")
                                .tag("d:\(display.displayID)")
                        }
                    }
                }
                if !pipeline.windows.isEmpty {
                    Section("Windows") {
                        ForEach(pipeline.windows, id: \.windowID) { window in
                            let appName = window.owningApplication?.applicationName ?? ""
                            let title = window.title ?? ""
                            let label = appName.isEmpty ? title : "\(appName) - \(title)"
                            Text(label).tag("w:\(window.windowID)").lineLimit(1)
                        }
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .task {
            await pipeline.discoverScreenSources()
        }
    }
}

struct PerSourceScreenPicker: View {
    let pipeline: MediaPipeline
    let source: CanvasSource

    private var selectionBinding: Binding<String> {
        Binding(
            get: { source.screenSourceSpec },
            set: { newValue in
                var updated = source
                updated.screenSourceSpec = newValue
                pipeline.updateCanvasSource(updated)
            }
        )
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
            Picker("", selection: selectionBinding) {
                Text("Default").tag("")
                if !pipeline.displays.isEmpty {
                    Section("Displays") {
                        ForEach(pipeline.displays, id: \.displayID) { display in
                            Text("Display \(display.displayID)")
                                .tag("d:\(display.displayID)")
                        }
                    }
                }
                if !pipeline.windows.isEmpty {
                    Section("Windows") {
                        ForEach(pipeline.windows, id: \.windowID) { window in
                            let appName = window.owningApplication?.applicationName ?? ""
                            let title = window.title ?? ""
                            let label = appName.isEmpty ? title : "\(appName) - \(title)"
                            Text(label).tag("w:\(window.windowID)").lineLimit(1)
                        }
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .task {
            await pipeline.discoverScreenSources()
        }
    }
}

// MARK: - Chat Tab

struct ChatTab: View {
    @Environment(MediaPipeline.self) private var pipeline

    private var hasAnyChat: Bool {
        pipeline.youtubeChatService.isPolling || pipeline.twitchChatService.isConnected
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    TabSectionHeader(title: "LIVE CHAT") {
                        Button { ChatPopout.shared.toggle(pipeline: pipeline) } label: {
                            Image(systemName: ChatPopout.shared.isOpen
                                  ? "rectangle.on.rectangle.slash" : "rectangle.portrait.on.rectangle.portrait")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(ChatPopout.shared.isOpen ? .blue : .white.opacity(0.5))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(ChatPopout.shared.isOpen ? "Close chat pop-out" : "Pop out chat")
                    }

                    ChatSourceCard(
                        icon: "play.rectangle.fill",
                        iconColor: .red,
                        title: "YouTube",
                        isSignedIn: pipeline.youtubeAuth.isSignedIn,
                        isActive: pipeline.youtubeChatService.isPolling,
                        signedInLabel: pipeline.youtubeAuth.channelInfo?.channelTitle,
                        isAuthenticating: pipeline.youtubeAuth.isAuthenticating,
                        accountWarning: pipeline.youtubeAuth.channelError,
                        onSignIn: { pipeline.youtubeAuth.signIn() },
                        onCancelSignIn: { pipeline.youtubeAuth.cancelSignIn() },
                        onSignOut: {
                            pipeline.youtubeAuth.signOut()
                            pipeline.stopYouTubeChat()
                        },
                        onConnect: { return await pipeline.fetchActiveBroadcastChat() },
                        onDisconnect: { pipeline.stopYouTubeChat() },
                        connectLabel: "Connect Chat"
                    )

                    TwitchChatSourceCard(
                        pipeline: pipeline
                    )

                    if pipeline.featuredChatMessage != nil {
                        HStack {
                            Spacer()
                            Button {
                                pipeline.dismissFeaturedMessage()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10))
                                    Text("Dismiss featured")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.orange.opacity(0.1))
                                .clipShape(Capsule())
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                    }

                    if hasAnyChat {
                        if pipeline.allChatMessages.isEmpty {
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
                    } else if !pipeline.youtubeAuth.isSignedIn && !pipeline.twitchAuth.isSignedIn {
                        TabEmptyState(
                            icon: "bubble.left.and.bubble.right",
                            title: "No chat sources",
                            subtitle: "Connect YouTube or Twitch above to see live chat"
                        )
                    }
                }
                .padding(12)
                .padding(.top, 22)
            }
        }
    }
}

struct ChatSourceCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let isSignedIn: Bool
    let isActive: Bool
    let signedInLabel: String?
    let isAuthenticating: Bool
    var accountWarning: String?
    let onSignIn: () -> Void
    let onCancelSignIn: () -> Void
    let onSignOut: () -> Void
    let onConnect: () async -> String?
    let onDisconnect: () -> Void
    let connectLabel: String

    @State private var isConnecting = false
    @State private var connectError: String?

    var body: some View {
        SidebarCard {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(iconColor.opacity(0.8))

                    if isSignedIn {
                        Text(signedInLabel ?? title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if isActive {
                            Circle().fill(.green).frame(width: 5, height: 5)
                        }

                        Spacer()

                        if isActive {
                            Button {
                                onDisconnect()
                            } label: {
                                Text("Disconnect")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            onSignOut()
                        } label: {
                            Text("Sign Out")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                    }
                }

                if let accountWarning, isSignedIn {
                    Text(accountWarning)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !isSignedIn {
                    // The browser can close without ever calling back, which would
                    // otherwise leave this stuck on "Signing in..." until a restart.
                    if isAuthenticating {
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text("Signing in...")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 5))

                            Button(action: onCancelSignIn) {
                                Text("Cancel")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.35))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Button(action: onSignIn) {
                            Text("Sign In")
                                .font(.system(size: 10, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(.blue.opacity(0.15))
                                .foregroundStyle(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else if !isActive {
                    Button {
                        isConnecting = true
                        connectError = nil
                        Task {
                            let error = await onConnect()
                            isConnecting = false
                            if let error {
                                connectError = error
                                try? await Task.sleep(nanoseconds: 5_000_000_000)
                                connectError = nil
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isConnecting {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 9))
                            }
                            Text(isConnecting ? "Connecting..." : connectLabel)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isConnecting)

                    if let error = connectError {
                        Text(error)
                            .font(.system(size: 9))
                            .foregroundStyle(.orange.opacity(0.8))
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

struct TwitchChatSourceCard: View {
    let pipeline: MediaPipeline

    var body: some View {
        SidebarCard {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.purple.opacity(0.8))

                    if pipeline.twitchAuth.isSignedIn {
                        Text(pipeline.twitchAuth.username ?? "Twitch")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)

                        if pipeline.twitchChatService.isConnected {
                            Circle().fill(.green).frame(width: 5, height: 5)
                        }

                        Spacer()

                        if pipeline.twitchChatService.isConnected {
                            Button {
                                pipeline.disconnectTwitchChat()
                            } label: {
                                Text("Disconnect")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            pipeline.twitchAuth.signOut()
                            pipeline.disconnectTwitchChat()
                        } label: {
                            Text("Sign Out")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("Twitch")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                    }
                }

                if !pipeline.twitchAuth.isSignedIn {
                    if pipeline.twitchAuth.isAuthenticating {
                        if let code = pipeline.twitchAuth.userCode {
                            VStack(spacing: 6) {
                                Text("Enter this code on Twitch:")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.4))

                                Text(code)
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.purple)
                                    .textSelection(.enabled)

                                HStack(spacing: 8) {
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(code, forType: .string)
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "doc.on.doc")
                                                .font(.system(size: 8))
                                            Text("Copy")
                                                .font(.system(size: 9))
                                        }
                                        .foregroundStyle(.white.opacity(0.4))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        pipeline.twitchAuth.cancelSignIn()
                                    } label: {
                                        Text("Cancel")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.white.opacity(0.3))
                                    }
                                    .buttonStyle(.plain)
                                }

                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.top, 2)
                            }
                        } else {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Requesting code...")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                    } else {
                        Button {
                            pipeline.twitchAuth.signIn()
                        } label: {
                            Text("Sign In")
                                .font(.system(size: 10, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(.purple.opacity(0.15))
                                .foregroundStyle(.purple)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else if !pipeline.twitchChatService.isConnected {
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
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(.purple.opacity(0.15))
                        .foregroundStyle(.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
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
}

struct ChatMessageRow: View {
    enum Source { case youtube, twitch }

    let message: YouTubeChatMessage
    var source: Source = .youtube
    let isFeatured: Bool
    let onFeature: () -> Void

    var body: some View {
        Button(action: onFeature) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle()
                        .fill(authorColor.opacity(0.2))
                    Text(String(message.authorName.prefix(1)).uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(authorColor)
                }
                .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: source == .twitch ? "gamecontroller.fill" : "play.rectangle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(source == .twitch ? .purple.opacity(0.6) : .red.opacity(0.6))

                        Text(message.authorName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(authorColor)
                            .lineLimit(1)

                        if message.isOwner {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(.yellow)
                        } else if message.isModerator {
                            Image(systemName: "wrench.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(.green)
                        }

                        if message.type == .superChat, let amount = message.superChatAmount {
                            Text(amount)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.yellow)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.yellow.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }

                    Text(message.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if isFeatured {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                }
            }
            .padding(8)
            .background(isFeatured ? .blue.opacity(0.12) : .white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFeatured ? .blue.opacity(0.3) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var authorColor: Color {
        if message.isOwner { return .yellow }
        if message.isModerator { return .green }
        if source == .twitch { return Color(red: 0.6, green: 0.4, blue: 1.0) }
        return Color(red: 0.4, green: 0.75, blue: 1.0)
    }
}

// MARK: - Sounds Tab

struct SoundsTab: View {
    @Environment(MediaPipeline.self) private var pipeline

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TabSectionHeader(title: "SOUND BOARD") {
                    Button {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.mp3, .wav, .aiff, .audio]
                        panel.canChooseFiles = true
                        if panel.runModal() == .OK, let url = panel.url {
                            let name = url.deletingPathExtension().lastPathComponent
                            pipeline.soundBoard.addCustomSound(name: name, url: url)
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.blue)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }

                if pipeline.soundBoard.sounds.isEmpty {
                    TabEmptyState(
                        icon: "music.note.list",
                        title: "No sounds",
                        subtitle: "Add sound effects to play during your stream"
                    )
                } else {
                    let columns = [
                        GridItem(.flexible(), spacing: 6),
                        GridItem(.flexible(), spacing: 6)
                    ]
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(pipeline.soundBoard.sounds) { sound in
                            SoundButton(sound: sound, soundBoard: pipeline.soundBoard)
                        }
                    }
                }
            }
            .padding(12)
            .padding(.top, 22)
        }
    }
}

// MARK: - Canvas Sources Tab

struct CanvasSourcesTab: View {
    @Environment(MediaPipeline.self) private var pipeline
    @State private var canvasName = ""
    @State private var canvasNameFocusToken = 0
    @State private var lastCanvasId: UUID?
    @State private var expandedSourceId: UUID?
    @State private var draggingSourceId: UUID?
    @State private var dropInsertIndex: Int?
    @State private var dragLocation: CGPoint?
    @State private var rowFrames: [UUID: CGRect] = [:]

    private var isBuiltIn: Bool {
        pipeline.activeCanvas?.isBuiltIn ?? false
    }

    private var lockedSources: [CanvasSource] {
        pipeline.canvasSources
            .filter { $0.isLocked }
            .sorted { $0.zOrder < $1.zOrder }
    }

    private var editableSources: [CanvasSource] {
        pipeline.canvasSources
            .filter { !$0.isLocked }
            .sorted { $0.zOrder > $1.zOrder }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let canvas = pipeline.activeCanvas, !canvas.isBuiltIn {
                    HStack(spacing: 8) {
                        Image(systemName: "square.3.layers.3d")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))

                        InlineTextField(
                            text: $canvasName,
                            font: .systemFont(ofSize: 12, weight: .semibold),
                            textColor: .white.withAlphaComponent(0.7),
                            focusTrigger: canvasNameFocusToken,
                            onCommit: {
                                if !canvasName.isEmpty {
                                    pipeline.renameCanvas(canvas.id, name: canvasName)
                                } else {
                                    canvasName = canvas.name
                                }
                            },
                            onCancel: {
                                canvasName = canvas.name
                            }
                        )
                        .padding(.horizontal, 6).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusesInlineField(on: $canvasNameFocusToken)

                        Spacer()

                        Button {
                            pipeline.deleteCanvas(canvas.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.25))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Delete canvas")
                    }
                    .padding(.horizontal, 2)
                    .onAppear {
                        canvasName = canvas.name
                        lastCanvasId = canvas.id
                    }
                    .onChange(of: pipeline.activeCanvasId) { _, newId in
                        if let newId, let c = pipeline.canvases.first(where: { $0.id == newId }) {
                            canvasName = c.name
                            lastCanvasId = newId
                        }
                    }
                }

                if pipeline.activeCanvasId == Canvas.mediaBuiltInId {
                    MediaPresetEditor()
                }

                // Locked structural sources (Camera in Camera, Screen in Screen/PiP, Media in Media).
                // The device and styling are editable, the position is not.
                if !lockedSources.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(lockedSources, id: \.id) { source in
                            BuiltInSourceCard(source: source)
                        }
                    }
                }

                if !isBuiltIn {
                    TabSectionHeader(title: "SOURCES") {
                        Menu {
                            ForEach(CanvasSourceType.allCases) { type in
                                Button {
                                    addSource(type)
                                } label: {
                                    Label(type.label, systemImage: type.icon)
                                }
                            }
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
                }

                if !isBuiltIn && editableSources.isEmpty {
                    TabEmptyState(
                        icon: "square.3.layers.3d",
                        title: "No sources",
                        subtitle: "Add sources to build your custom scene"
                    )
                } else if !editableSources.isEmpty {
                    let sources = editableSources
                    VStack(spacing: 4) {
                        ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                            CanvasSourceRow(
                                source: source,
                                isSelected: pipeline.selectedCanvasSourceId == source.id,
                                isExpanded: expandedSourceId == source.id,
                                onTap: {
                                    if pipeline.selectedCanvasSourceId == source.id {
                                        pipeline.selectedCanvasSourceId = nil
                                    } else {
                                        pipeline.selectedCanvasSourceId = source.id
                                    }
                                },
                                onExpandToggle: {
                                    if expandedSourceId == source.id {
                                        expandedSourceId = nil
                                    } else {
                                        expandedSourceId = source.id
                                    }
                                }
                            )
                            .opacity(draggingSourceId == source.id ? 0.3 : 1.0)
                            .background(GeometryReader { geo in
                                Color.clear.onAppear {
                                    rowFrames[source.id] = geo.frame(in: .named("sourceList"))
                                }.onChange(of: geo.frame(in: .named("sourceList"))) { _, frame in
                                    rowFrames[source.id] = frame
                                }
                            })
                            .overlay(alignment: .top) {
                                if dropInsertIndex == index {
                                    CanvasDropIndicator()
                                        .offset(y: -2)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if index == sources.count - 1 && dropInsertIndex == sources.count {
                                    CanvasDropIndicator()
                                        .offset(y: 2)
                                }
                            }
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 5, coordinateSpace: .named("sourceList"))
                                    .onChanged { value in
                                        if draggingSourceId == nil {
                                            draggingSourceId = source.id
                                        }
                                        dragLocation = value.location
                                        updateDropTarget(at: value.location, sources: sources)
                                    }
                                    .onEnded { _ in
                                        endDrag(sources: sources)
                                    }
                            )
                        }
                    }
                    .coordinateSpace(name: "sourceList")
                    .overlay {
                        if let dragId = draggingSourceId,
                           let location = dragLocation,
                           let source = sources.first(where: { $0.id == dragId }) {
                            CanvasDragShadow(source: source)
                                .position(x: location.x, y: location.y)
                        }
                    }
                }
            }
            .padding(12)
            .padding(.top, 22)
        }
        .onChange(of: pipeline.isCanvasDragging) { _, dragging in
            if dragging {
                expandedSourceId = nil
            }
        }
    }

    private var sortedSources: [CanvasSource] {
        pipeline.canvasSources.sorted { $0.zOrder > $1.zOrder }
    }

    private func addSource(_ type: CanvasSourceType) {
        let maxZ = pipeline.canvasSources.map(\.zOrder).max() ?? -1
        var source = CanvasSource(type: type, zOrder: maxZ + 1)

        if type == .image {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .image]
            panel.canChooseFiles = true
            if panel.runModal() == .OK, let url = panel.url {
                source.imagePath = Persistence.copyImageToAppSupport(url.path)
                source.label = url.deletingPathExtension().lastPathComponent
            } else {
                return
            }
        }

        pipeline.addCanvasSource(source)
        pipeline.selectedCanvasSourceId = source.id
    }

    private func updateDropTarget(at location: CGPoint, sources: [CanvasSource]) {
        guard draggingSourceId != nil else { return }

        for (index, source) in sources.enumerated() {
            guard let frame = rowFrames[source.id] else { continue }
            if location.y >= frame.minY && location.y <= frame.maxY {
                let midY = frame.midY
                let newIndex = location.y < midY ? index : index + 1
                if dropInsertIndex != newIndex {
                    dropInsertIndex = newIndex
                }
                return
            }
        }

        if let firstFrame = sources.first.flatMap({ rowFrames[$0.id] }), location.y < firstFrame.minY {
            dropInsertIndex = 0
            return
        }

        if let lastFrame = sources.last.flatMap({ rowFrames[$0.id] }), location.y > lastFrame.maxY {
            dropInsertIndex = sources.count
            return
        }
    }

    private func endDrag(sources: [CanvasSource]) {
        guard let draggingId = draggingSourceId, let insertIndex = dropInsertIndex else {
            draggingSourceId = nil
            dropInsertIndex = nil
            dragLocation = nil
            return
        }

        let clampedIndex = min(insertIndex, sources.count - 1)
        let targetSource = sources[clampedIndex]
        if draggingId != targetSource.id {
            pipeline.reorderCanvasSource(draggingId, toZOrderOf: targetSource.id)
        }

        pipeline.selectedCanvasSourceId = draggingId
        draggingSourceId = nil
        dropInsertIndex = nil
        dragLocation = nil
    }
}

struct CanvasDropIndicator: View {
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

struct CanvasDragShadow: View {
    let source: CanvasSource

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: source.type.icon)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
            Text(source.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
        )
        .allowsHitTesting(false)
    }
}

struct BuiltInSourceCard: View {
    @Environment(MediaPipeline.self) private var pipeline
    let source: CanvasSource

    var body: some View {
        SidebarCard {
            HStack(spacing: 6) {
                Image(systemName: source.type.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                Text(source.label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(1)
                Spacer()
            }

            switch source.type {
            case .camera:
                DevicePicker(
                    items: pipeline.cameras.map { ($0.id, $0.name) },
                    selection: Binding(
                        get: { pipeline.selectedCameraId },
                        set: { id in Task { await pipeline.selectCamera(id) } }
                    )
                )

                Divider().opacity(0.1)
                CardSectionLabel(title: "APPEARANCE")
                AppearanceControls(mirror: Binding(
                    get: { source.isMirrored },
                    set: { newValue in
                        var updated = source
                        updated.isMirrored = newValue
                        pipeline.updateCanvasSource(updated)
                    }
                ))

            case .screenCapture:
                ScreenSourcePickerInline(pipeline: pipeline)

            case .image, .mediaFile:
                EmptyView()
            }
        }
    }
}

struct CanvasSourceRow: View {
    @Environment(MediaPipeline.self) private var pipeline
    let source: CanvasSource
    let isSelected: Bool
    let isExpanded: Bool
    let onTap: () -> Void
    let onExpandToggle: () -> Void
    @State private var isEditing = false
    @State private var editLabel = ""
    @State private var editFocusToken = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    var updated = source
                    updated.isVisible.toggle()
                    pipeline.updateCanvasSource(updated)
                } label: {
                    Image(systemName: source.isVisible ? "eye" : "eye.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(source.isVisible ? .white.opacity(0.5) : .white.opacity(0.2))
                        .frame(width: 16)
                }
                .buttonStyle(.plain)

                Button {
                    var updated = source
                    updated.isLocked.toggle()
                    pipeline.updateCanvasSource(updated)
                } label: {
                    Image(systemName: source.isLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 9))
                        .foregroundStyle(source.isLocked ? .orange.opacity(0.7) : .white.opacity(0.2))
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .help(source.isLocked ? "Unlock" : "Lock")

                Image(systemName: source.type.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 14)

                if isEditing {
                    InlineTextField(
                        text: $editLabel,
                        font: .systemFont(ofSize: 11),
                        textColor: .white.withAlphaComponent(0.9),
                        autoFocus: true,
                        selectAllOnFocus: true,
                        focusTrigger: editFocusToken,
                        onCommit: {
                            if !editLabel.isEmpty {
                                var updated = source
                                updated.label = editLabel
                                pipeline.updateCanvasSource(updated)
                            }
                            isEditing = false
                        },
                        onCancel: {
                            isEditing = false
                        }
                    )
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .focusesInlineField(on: $editFocusToken)
                } else {
                    Text(source.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }

                Spacer()

                Button { onExpandToggle() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 20, height: 20)
                        .background(.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(isExpanded ? "Collapse" : "Expand")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            if isExpanded {
                CanvasSourceControls(source: source)
                    .padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .background(isSelected ? .blue.opacity(0.12) : .white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.blue.opacity(isSelected ? 0.3 : 0), lineWidth: 1)
        )
        .contextMenu {
            Button { pipeline.duplicateCanvasSource(source.id) } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button {
                editLabel = source.label
                isEditing = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) { pipeline.removeCanvasSource(source.id) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

struct CanvasSourceControls: View {
    @Environment(MediaPipeline.self) private var pipeline
    let source: CanvasSource

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.1)

            CardSectionLabel(title: "STYLE")
            SliderRow(label: "Opacity", value: binding(\.opacity), range: 0...1, unit: "%", displayMultiplier: 100, valueWidth: 32)
            SliderRow(label: "Corners", value: binding(\.cornerRadius), range: 0...50, valueWidth: 32)

            if source.type == .camera {
                DevicePicker(
                    icon: "camera",
                    items: pipeline.cameras.map { ($0.id, $0.name) },
                    selection: Binding(
                        get: {
                            let deviceId = source.cameraDeviceId
                            if deviceId.isEmpty { return pipeline.selectedCameraId }
                            return deviceId
                        },
                        set: { id in
                            var updated = source
                            updated.cameraDeviceId = id
                            pipeline.updateCanvasSource(updated)
                        }
                    )
                )

                Text("\u{2325}+drag edges to crop")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.2))

                Divider().opacity(0.1)
                CardSectionLabel(title: "APPEARANCE")
                AppearanceControls(mirror: bindingBool(\.isMirrored))
            }

            if source.type == .screenCapture {
                PerSourceScreenPicker(pipeline: pipeline, source: source)

                Text("\u{2325}+drag edges to crop")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.2))
            }

            if source.type == .mediaFile {
                MediaPlayerControls { url in
                    var updated = source
                    updated.label = url.deletingPathExtension().lastPathComponent
                    pipeline.updateCanvasSource(updated)
                }

                Text("\u{2325}+drag edges to crop")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.2))
            }

            if source.type == .image {
                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .image]
                    panel.canChooseFiles = true
                    if panel.runModal() == .OK, let url = panel.url {
                        var updated = source
                        updated.imagePath = Persistence.copyImageToAppSupport(url.path)
                        updated.label = url.deletingPathExtension().lastPathComponent
                        pipeline.updateCanvasSource(updated)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "photo")
                            .font(.system(size: 10))
                        Text("Change Image")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

            Text("Drag to move \u{2022} Drag edges to resize \u{2022} \u{2190}\u{2191}\u{2193}\u{2192} to nudge")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.2))
        }
    }

    private func binding(_ keyPath: WritableKeyPath<CanvasSource, CGFloat>) -> Binding<CGFloat> {
        Binding(
            get: { source[keyPath: keyPath] },
            set: { newValue in
                var updated = source
                updated[keyPath: keyPath] = newValue
                pipeline.updateCanvasSource(updated)
            }
        )
    }

    private func bindingBool(_ keyPath: WritableKeyPath<CanvasSource, Bool>) -> Binding<Bool> {
        Binding(
            get: { source[keyPath: keyPath] },
            set: { newValue in
                var updated = source
                updated[keyPath: keyPath] = newValue
                pipeline.updateCanvasSource(updated)
            }
        )
    }
}



struct SoundButton: View {
    let sound: SoundEffect
    let soundBoard: SoundBoard
    @State private var isHovered = false

    private var isPlaying: Bool {
        soundBoard.playingId == sound.id
    }

    var body: some View {
        Button {
            if isPlaying {
                soundBoard.stop()
            } else {
                soundBoard.play(sound)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: isPlaying ? "stop.fill" : sound.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isPlaying ? .blue : .white.opacity(0.5))
                Text(sound.name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isPlaying ? .blue : .white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(isPlaying ? .blue.opacity(0.15) : (isHovered ? .white.opacity(0.06) : .white.opacity(0.04)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            if !sound.isBuiltIn {
                Button("Remove") {
                    soundBoard.removeSound(sound.id)
                }
            }
        }
    }
}

// MARK: - Destination Card

struct DestinationCard: View {
    @Environment(MediaPipeline.self) private var pipeline
    @Environment(DestinationStore.self) private var store
    let destination: StreamDestination
    @State private var testResult: (success: Bool, message: String)?
    @State private var isTesting = false
    @State private var health: RTMPClient.StreamHealth?
    @State private var healthTimer: Timer?
    @State private var showSettings = false

    /// Warns once the measured rate sits well under target for long enough that
    /// it is not just the encoder ramping up.
    private func bitrateShortfall(_ health: RTMPClient.StreamHealth) -> String? {
        guard health.uptimeSeconds > 20, health.currentBitrate > 0 else { return nil }
        let target = destination.videoBitrate
        guard target > 0, Double(health.currentBitrate) < Double(target) * 0.6 else { return nil }

        let actual = health.currentBitrate / 1_000_000
        let wanted = target / 1_000_000
        return "Sending about \(actual) Mbps of the \(wanted) Mbps this destination asks for. Motion will smear. Try a lower quality."
    }

    private var destinationState: RTMPClient.ClientState? {
        let outputs = pipeline.streamManager.destinations
        let output = outputs.first { $0.id == destination.id }
        return output?.connectionState
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { destination.enabled },
                    set: { _ in store.toggle(destination.id) }
                ))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .disabled(pipeline.streamStatus.isLive)

                let preset = PlatformPreset.presets.first { $0.id == destination.platformId }
                Image(systemName: preset?.icon ?? "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(destination.name)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)

                        if let state = destinationState {
                            DestinationStateBadge(state: state)
                        }
                    }
                    Text(verbatim: "\(destination.videoWidth)x\(destination.videoHeight) @ \(destination.videoBitrate / 1000)kbps")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.25))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                if !pipeline.streamStatus.isLive {
                    Button {
                        Task {
                            isTesting = true
                            testResult = await pipeline.testConnection(destination)
                            isTesting = false
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            testResult = nil
                        }
                    } label: {
                        if isTesting {
                            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                        } else if let result = testResult {
                            Image(systemName: result.success ? "checkmark.circle" : "xmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(result.success ? .green : .red)
                        } else {
                            Image(systemName: "bolt.horizontal")
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.25))
                        }
                    }
                    .buttonStyle(.plain).help("Test connection")
                }

                Button { showSettings.toggle() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10))
                        .foregroundStyle(showSettings ? .blue : .white.opacity(0.25))
                }
                .buttonStyle(.plain).help("Settings")

                if !pipeline.streamStatus.isLive {
                    Button { store.remove(destination.id) } label: {
                        Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(.white.opacity(0.2))
                    }.buttonStyle(.plain)
                }
            }.padding(10)

            if showSettings {
                DestinationSettingsForm(
                    destination: destination,
                    isLocked: pipeline.streamStatus.isLive,
                    onSave: { updated in
                        store.update(updated)
                        showSettings = false
                    },
                    onCancel: { showSettings = false }
                )
                .padding(.horizontal, 10).padding(.bottom, 10)
            }

            if let result = testResult {
                Text(result.message)
                    .font(.system(size: 9))
                    .foregroundStyle(result.success ? .green.opacity(0.7) : .red.opacity(0.7))
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }

            if pipeline.streamStatus.isLive, let health = health {
                DestinationHealthBar(health: health)
                    .padding(.horizontal, 10).padding(.bottom, 8)

                // Sending far less than the destination asks for is what makes
                // motion smear, and nothing else in the UI says so.
                if let shortfall = bitrateShortfall(health) {
                    Text(shortfall)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.bottom, 8)
                }
            }
        }
        .background(.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button { showSettings.toggle() } label: {
                Label(showSettings ? "Hide Settings" : "Settings", systemImage: "gearshape")
            }
            if !pipeline.streamStatus.isLive {
                Divider()
                Button(role: .destructive) { store.remove(destination.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .onAppear { startHealthPolling() }
        .onDisappear { healthTimer?.invalidate() }
        .onChange(of: pipeline.streamStatus.isLive) { _, isLive in
            if isLive {
                startHealthPolling()
            } else {
                healthTimer?.invalidate()
                health = nil
            }
        }
    }

    private func startHealthPolling() {
        healthTimer?.invalidate()
        guard pipeline.streamStatus.isLive else { return }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                let allHealth = pipeline.streamManager.aggregateHealth
                health = allHealth[destination.id]
            }
        }
    }
}

struct DestinationStateBadge: View {
    let state: RTMPClient.ClientState

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(stateColor)
                .frame(width: 5, height: 5)
            Text(stateLabel)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(stateColor)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(stateColor.opacity(0.1))
        .clipShape(Capsule())
        .fixedSize()
    }

    private var stateColor: Color {
        switch state {
        case .live: return .green
        case .connecting: return .blue
        case .reconnecting: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private var stateLabel: String {
        switch state {
        case .live: return "LIVE"
        case .connecting: return "CONNECTING"
        case .reconnecting(let n): return "RETRY \(n)"
        case .error: return "ERROR"
        case .disconnected: return "OFF"
        }
    }
}

struct DestinationHealthBar: View {
    let health: RTMPClient.StreamHealth

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                HealthStat(label: "Bitrate", value: formatBitrate(health.currentBitrate))
                HealthStat(label: "Dropped", value: "\(health.droppedFrames)/\(health.totalFrames)", isWarning: health.dropRate > 0.02)
                HealthStat(label: "Queue", value: formatBytes(health.queuedBytes), isWarning: health.queuedBytes > 2_000_000)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(.white.opacity(0.04))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(qualityColor)
                        .frame(width: geo.size.width * qualityFraction)
                }
            }.frame(height: 3)
        }
    }

    private var qualityFraction: CGFloat {
        let dropPenalty = min(0.5, CGFloat(health.dropRate) * 10)
        let queuePenalty = min(0.3, CGFloat(health.queuedBytes) / 5_000_000 * 0.3)
        return max(0.05, 1.0 - dropPenalty - queuePenalty)
    }

    private var qualityColor: Color {
        if qualityFraction > 0.8 { return .green }
        if qualityFraction > 0.5 { return .yellow }
        return .red
    }

    private func formatBitrate(_ bps: Int) -> String {
        if bps >= 1_000_000 {
            return String(format: "%.1fM", Double(bps) / 1_000_000)
        }
        return "\(bps / 1000)k"
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1fMB", Double(bytes) / 1_000_000)
        }
        return "\(bytes / 1000)KB"
    }
}

struct HealthStat: View {
    let label: String
    let value: String
    var isWarning: Bool = false

    var body: some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(isWarning ? .orange : .white.opacity(0.5))
            Text(label)
                .font(.system(size: 7))
                .foregroundStyle(.white.opacity(0.2))
        }
    }
}

// MARK: - Destination Settings

struct DestinationSettingsForm: View {
    let destination: StreamDestination
    let isLocked: Bool
    var onSave: (StreamDestination) -> Void
    var onCancel: () -> Void

    @State private var name = ""
    @State private var rtmpUrl = ""
    @State private var streamKey = ""
    @State private var showKey = false
    @State private var selectedQualityId: String?

    private var preset: PlatformPreset? {
        PlatformPreset.presets.first { $0.id == destination.platformId }
    }

    private var qualityOptions: [StreamQuality] {
        guard let preset else {
            return StreamQuality.all
        }
        return StreamQuality.options(for: preset)
    }

    private var chosenQuality: StreamQuality? {
        qualityOptions.first { $0.id == selectedQualityId }
    }

    private var trimmedKey: String {
        streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        if name != destination.name || rtmpUrl != destination.rtmpUrl || trimmedKey != destination.streamKey {
            return true
        }
        guard let chosen = chosenQuality else {
            return false
        }
        return chosen.width != destination.videoWidth
            || chosen.height != destination.videoHeight
            || chosen.fps != destination.fps
            || chosen.videoBitrate != destination.videoBitrate
    }

    private var canSave: Bool {
        !isLocked && hasChanges && !trimmedKey.isEmpty && !rtmpUrl.isEmpty
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.1)

            field("NAME") {
                SidebarTextField(text: $name, placeholder: "Name")
            }

            field("RTMP URL") {
                SidebarTextField(text: $rtmpUrl, placeholder: "rtmp://...")
            }

            field("STREAM KEY") {
                HStack(spacing: 6) {
                    Group {
                        if showKey {
                            TextField("Stream key", text: $streamKey)
                        } else {
                            SecureField("Stream key", text: $streamKey)
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focusEffectDisabled()

                    Button { showKey.toggle() } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .help(showKey ? "Hide key" : "Show key")
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.06), lineWidth: 1))
            }

            field("QUALITY") {
                HStack(spacing: 4) {
                    ForEach(qualityOptions) { option in
                        let isChosen = option.id == selectedQualityId
                        Button { selectedQualityId = option.id } label: {
                            Text(option.label)
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(isChosen ? Color.blue.opacity(0.25) : .white.opacity(0.05))
                                .foregroundStyle(isChosen ? .blue : .white.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                let width = chosenQuality?.width ?? destination.videoWidth
                let height = chosenQuality?.height ?? destination.videoHeight
                let bitrate = chosenQuality?.videoBitrate ?? destination.videoBitrate
                let fps = chosenQuality?.fps ?? destination.fps
                Text(verbatim: "\(width)x\(height) · \(bitrate / 1000) kbps · \(fps) fps · audio \(destination.audioBitrate / 1000) kbps")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if isLocked {
                Text("Stop the stream to change these settings.")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }

            HStack(spacing: 8) {
                Button { onCancel() } label: {
                    Text(isLocked ? "Close" : "Cancel")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)

                if !isLocked {
                    Button { save() } label: {
                        Text("Save")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(canSave ? .white : .white.opacity(0.35))
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(canSave ? Color.blue : .white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                }
            }
        }
        .onAppear { load() }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CardSectionLabel(title: title)
            content()
                .disabled(isLocked)
        }
    }

    private func load() {
        name = destination.name
        rtmpUrl = destination.rtmpUrl
        streamKey = destination.streamKey
        selectedQualityId = qualityOptions.first {
            $0.width == destination.videoWidth && $0.height == destination.videoHeight && $0.fps == destination.fps
        }?.id
    }

    private func save() {
        guard canSave else {
            return
        }
        var updated = destination
        updated.name = name.trimmingCharacters(in: .whitespaces)
        updated.rtmpUrl = rtmpUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.streamKey = trimmedKey
        if let chosen = chosenQuality {
            updated.videoWidth = chosen.width
            updated.videoHeight = chosen.height
            updated.fps = chosen.fps
            updated.videoBitrate = chosen.videoBitrate
        }
        onSave(updated)
    }
}

// MARK: - Add Destination

struct AddDestinationForm: View {
    var onAdd: (PlatformPreset, String?, String, StreamQuality) -> Void
    var onCancel: () -> Void

    @State private var selectedPresetId = ""
    @State private var customUrl = ""
    @State private var streamKey = ""
    @State private var streamKeyFocusToken = 0

    @State private var selectedQualityId: String?

    private var trimmedKey: String {
        streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func quality(for preset: PlatformPreset) -> StreamQuality {
        let options = StreamQuality.options(for: preset)
        if let id = selectedQualityId, let match = options.first(where: { $0.id == id }) {
            return match
        }
        return StreamQuality.defaultOption(for: preset)
    }

    @FocusState private var streamKeyFocused: Bool

    private var selectedPreset: PlatformPreset? {
        PlatformPreset.presets.first { $0.id == selectedPresetId }
    }

    private func platformAccent(_ id: String) -> Color {
        switch id {
        case "youtube": return Color(red: 1.0, green: 0.0, blue: 0.0)
        case "twitch": return Color(red: 0.57, green: 0.31, blue: 1.0)
        case "kick": return Color(red: 0.32, green: 1.0, blue: 0.31)
        case "facebook": return Color(red: 0.10, green: 0.45, blue: 0.95)
        case "x": return .white
        default: return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("PLATFORM")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                        .tracking(1)
                    Spacer()
                    Button { onCancel() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }

                if let preset = selectedPreset {
                    let accent = platformAccent(preset.id)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            HStack(spacing: 7) {
                                Image(systemName: preset.icon)
                                    .font(.system(size: 12))
                                    .foregroundStyle(accent)
                                    .frame(width: 16)
                                Text(preset.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .frame(maxWidth: .infinity)
                            .background(accent.opacity(0.16))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(accent.opacity(0.55), lineWidth: 1)
                            )

                            Button {
                                selectedPresetId = ""
                                customUrl = ""
                                streamKey = ""
                            } label: {
                                Text("Change")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .padding(.horizontal, 10)
                                    .frame(height: 32)
                                    .background(.white.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7)
                                            .stroke(.white.opacity(0.08), lineWidth: 1)
                                    )
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }

                        if !preset.tutorialUrl.isEmpty, let tutorialURL = URL(string: preset.tutorialUrl) {
                            Link(destination: tutorialURL) {
                                HStack(spacing: 5) {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color(red: 1.0, green: 0.25, blue: 0.25))
                                    Text("Watch how to set up \(preset.name)")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.65))
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.45))
                                }
                                .padding(.leading, 2)
                                .padding(.top, 2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(PlatformPreset.presets) { preset in
                            Button {
                                selectedPresetId = preset.id
                                customUrl = preset.rtmpUrl
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: preset.icon)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .frame(width: 16)
                                    Text(preset.name)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.7))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 32)
                                .frame(maxWidth: .infinity)
                                .background(.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(.white.opacity(0.05), lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }

            if let preset = selectedPreset {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RTMP URL")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                        .tracking(1)
                    SidebarTextField(text: $customUrl, placeholder: "rtmp://...")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("STREAM KEY")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                        .tracking(1)
                    SecureField("Paste stream key", text: $streamKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .focused($streamKeyFocused)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .frame(maxWidth: .infinity)
                        .background(.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(streamKeyFocused ? Color.blue.opacity(0.4) : .white.opacity(0.06), lineWidth: 1)
                        )
                        .focusEffectDisabled()
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            TapGesture().onEnded { streamKeyFocused = true }
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("QUALITY")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))

                    let options = StreamQuality.options(for: preset)
                    let chosen = quality(for: preset)

                    HStack(spacing: 4) {
                        ForEach(options) { option in
                            Button { selectedQualityId = option.id } label: {
                                Text(option.label)
                                    .font(.system(size: 9, weight: .medium))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 7).padding(.vertical, 4)
                                    .background(option.id == chosen.id ? Color.blue.opacity(0.25) : .white.opacity(0.05))
                                    .foregroundStyle(option.id == chosen.id ? .blue : .white.opacity(0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text(verbatim: "\(chosen.width)x\(chosen.height) · \(chosen.videoBitrate / 1_000_000) Mbps · \(chosen.fps) fps")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)

                    Text("Match this to how the broadcast is set up on the platform.")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.25))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)

                HStack(spacing: 8) {
                    Button { onCancel() } label: {
                        Text("Cancel")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)

                    // Studio shows the ingest URL and the key side by side, and
                    // pasting the URL here fails much later as a dropped RTMP
                    // connection with no explanation.
                    let keyLooksLikeURL = trimmedKey.lowercased().hasPrefix("rtmp://")
                        || trimmedKey.lowercased().hasPrefix("rtmps://")
                        || trimmedKey.lowercased().hasPrefix("http")
                    let canAdd = !trimmedKey.isEmpty && !customUrl.isEmpty && !keyLooksLikeURL

                    if keyLooksLikeURL {
                        Text("That looks like the ingest URL. Paste the stream key instead.")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        guard canAdd else {
                            return
                        }
                        onAdd(preset, customUrl != preset.rtmpUrl ? customUrl : nil, trimmedKey, quality(for: preset))
                    } label: {
                        Text("Add Destination")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(canAdd ? .white : .white.opacity(0.35))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(canAdd ? Color.blue : .white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAdd)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - Shared Sidebar Components

struct TabSectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .tracking(1.5)
            Spacer()
            trailing
        }
    }
}

extension TabSectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

struct SliderRow: View {
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var unit: String = ""
    var displayMultiplier: CGFloat = 1
    var valueWidth: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            Slider(value: $value, in: range).frame(maxWidth: .infinity)
            Text("\(Int(value * displayMultiplier))\(unit)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: valueWidth)
        }
    }
}

struct SidebarCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SidebarTextField: View {
    @Binding var text: String
    var placeholder: String = ""
    var onCommit: () -> Void = {}
    @State private var focusToken = 0

    var body: some View {
        InlineTextField(
            text: $text,
            placeholder: placeholder,
            font: .systemFont(ofSize: 11),
            textColor: .white.withAlphaComponent(0.9),
            focusTrigger: focusToken,
            onCommit: onCommit
        )
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        )
        .focusesInlineField(on: $focusToken)
    }
}

struct CardSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.3))
            .tracking(1)
    }
}

struct TabEmptyState: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var action: (label: String, handler: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .thin))
                .foregroundStyle(.white.opacity(0.12))
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.25))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.15))
            }
            if let action {
                Button(action.label) { action.handler() }
                    .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.blue)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

extension Notification.Name {
    static let goLive = Notification.Name("streamif.goLive")
    static let endStream = Notification.Name("streamif.endStream")
}
