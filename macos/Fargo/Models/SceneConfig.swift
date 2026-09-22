import Foundation
import AppKit

// MARK: - Canvas Config (background)

enum CanvasBackgroundType: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case solidColor = "Color"
    case gradient = "Gradient"
    case wallpaper = "Wallpaper"
    case customImage = "Image"

    var id: String { rawValue }
}

struct CanvasGradient: Codable, Equatable {
    var color1: CodableColor = CodableColor(r: 0.1, g: 0.1, b: 0.3)
    var color2: CodableColor = CodableColor(r: 0.05, g: 0.05, b: 0.15)
    var angle: CGFloat = 45
}

struct CodableColor: Codable, Equatable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat = 1.0

    var nsColor: NSColor {
        NSColor(red: r, green: g, blue: b, alpha: a)
    }

    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1.0) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        self.r = c.redComponent
        self.g = c.greenComponent
        self.b = c.blueComponent
        self.a = c.alphaComponent
    }
}

struct CanvasConfig: Codable, Equatable {
    var backgroundType: CanvasBackgroundType = .none
    var solidColor: CodableColor = CodableColor(r: 0.1, g: 0.1, b: 0.1)
    var gradient: CanvasGradient = CanvasGradient()
    var wallpaperName: String?
    var customImagePath: String?
    var padding: CGFloat = 0
    var cornerRadius: CGFloat = 0

    var hasBackground: Bool {
        return backgroundType != .none
    }
}

struct WallpaperPreset: Identifiable {
    let id: String
    let name: String
    let filename: String

    var displayName: String { name }

    static let all: [WallpaperPreset] = [
        WallpaperPreset(id: "sequoia-light", name: "Sequoia Light", filename: "Sequoia-Light.jpg"),
        WallpaperPreset(id: "sequoia-dark", name: "Sequoia Dark", filename: "Sequoia-Dark.jpg"),
        WallpaperPreset(id: "sonoma-light", name: "Sonoma Light", filename: "Sonoma-Light.jpg"),
        WallpaperPreset(id: "sonoma-dark", name: "Sonoma Dark", filename: "Sonoma-Dark.jpg"),
        WallpaperPreset(id: "ventura-light", name: "Ventura Light", filename: "Ventura-Light.jpg"),
        WallpaperPreset(id: "ventura-dark", name: "Ventura Dark", filename: "Ventura-Dark.jpg"),
        WallpaperPreset(id: "monterey-light", name: "Monterey Light", filename: "Monterey-Light.jpg"),
        WallpaperPreset(id: "monterey-dark", name: "Monterey Dark", filename: "Monterey-Dark.jpg"),
        WallpaperPreset(id: "bigsur-day", name: "Big Sur Day", filename: "Big-Sur-Day.jpg"),
        WallpaperPreset(id: "bigsur-night", name: "Big Sur Night", filename: "Big-Sur-Night.jpg"),
        WallpaperPreset(id: "catalina-day", name: "Catalina Day", filename: "Catalina-Day.jpg"),
        WallpaperPreset(id: "catalina-night", name: "Catalina Night", filename: "Catalina-Night.jpg"),
        WallpaperPreset(id: "mojave-day", name: "Mojave Day", filename: "Mojave-Day.jpg"),
        WallpaperPreset(id: "mojave-night", name: "Mojave Night", filename: "Mojave-Night.jpg"),
    ]
}

// MARK: - Canvas

struct Canvas: Identifiable, Codable {
    let id: UUID
    var name: String
    var icon: String
    var sources: [CanvasSource]
    var isBuiltIn: Bool

    init(
        id: UUID = UUID(),
        name: String,
        icon: String = "square.3.layers.3d",
        sources: [CanvasSource] = [],
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.sources = sources
        self.isBuiltIn = isBuiltIn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "square.3.layers.3d"
        sources = try container.decode([CanvasSource].self, forKey: .sources)
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(icon, forKey: .icon)
        try container.encode(sources, forKey: .sources)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, sources, isBuiltIn
    }
}

extension Canvas {
    static let cameraBuiltInId = UUID(uuidString: "00000000-0000-0000-0000-00000000CA77")!
    static let screenBuiltInId = UUID(uuidString: "00000000-0000-0000-0000-00000000C5EE")!
    static let pipBuiltInId    = UUID(uuidString: "00000000-0000-0000-0000-000000000919")!
    static let mediaBuiltInId  = UUID(uuidString: "00000000-0000-0000-0000-00000000F1FE")!

    static func builtInCanvases() -> [Canvas] {
        var camera = CanvasSource(type: .camera, label: "Camera")
        camera.x = 0
        camera.y = 0
        camera.width = 1
        camera.height = 1
        camera.cornerRadius = 0
        camera.zOrder = 0
        camera.isLocked = true

        var screen = CanvasSource(type: .screenCapture, label: "Screen")
        screen.x = 0
        screen.y = 0
        screen.width = 1
        screen.height = 1
        screen.cornerRadius = 0
        screen.zOrder = 0
        screen.isLocked = true

        var pipScreen = CanvasSource(type: .screenCapture, label: "Screen")
        pipScreen.x = 0
        pipScreen.y = 0
        pipScreen.width = 1
        pipScreen.height = 1
        pipScreen.cornerRadius = 0
        pipScreen.zOrder = 0
        pipScreen.isLocked = true

        var pipCamera = CanvasSource(type: .camera, label: "Camera")
        pipCamera.width = 0.25
        pipCamera.height = 0.25 * (9.0 / 16.0)
        pipCamera.x = 1.0 - pipCamera.width - 0.02
        pipCamera.y = 1.0 - pipCamera.height - 0.02
        pipCamera.cornerRadius = 12
        pipCamera.zOrder = 1

        var media = CanvasSource(type: .image, label: "Media")
        media.x = 0
        media.y = 0
        media.width = 1
        media.height = 1
        media.cornerRadius = 0
        media.zOrder = 0
        media.isLocked = true

        return [
            Canvas(id: cameraBuiltInId, name: "Camera", icon: "camera", sources: [camera], isBuiltIn: true),
            Canvas(id: screenBuiltInId, name: "Screen", icon: "display", sources: [screen], isBuiltIn: true),
            Canvas(id: pipBuiltInId,    name: "PiP",    icon: "pip",     sources: [pipScreen, pipCamera], isBuiltIn: true),
            Canvas(id: mediaBuiltInId,  name: "Media",  icon: "play.rectangle", sources: [media], isBuiltIn: true),
        ]
    }
}

// MARK: - Media Preset

struct MediaPreset: Identifiable, Codable {
    let id: UUID
    var name: String
    var filePath: String?

    var isVideo: Bool {
        guard let path = filePath else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi"].contains(ext)
    }

    var isImage: Bool {
        guard let path = filePath else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "tiff", "gif", "heic", "webp"].contains(ext)
    }

    var hasFile: Bool { filePath != nil }

    var bundledAsset: String?

    init(name: String, filePath: String? = nil, bundledAsset: String? = nil) {
        self.id = UUID()
        self.name = name
        self.filePath = filePath
        self.bundledAsset = bundledAsset
    }

    static var defaults: [MediaPreset] {
        [
            MediaPreset(name: "Starting Soon", bundledAsset: "PresetStartingSoon"),
            MediaPreset(name: "BRB", bundledAsset: "PresetBRB"),
            MediaPreset(name: "Ending", bundledAsset: "PresetEnding"),
        ]
    }

    private static let nameToAsset: [String: String] = [
        "Starting Soon": "PresetStartingSoon",
        "BRB": "PresetBRB",
        "Ending": "PresetEnding",
    ]

    static func exportBundledAssets(_ presets: inout [MediaPreset]) {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let presetsDir = support.appendingPathComponent("Fargo/MediaPresets", isDirectory: true)
        try? fm.createDirectory(at: presetsDir, withIntermediateDirectories: true)

        for i in presets.indices {
            if presets[i].filePath != nil { continue }
            let assetName = presets[i].bundledAsset ?? nameToAsset[presets[i].name]
            guard let asset = assetName else { continue }

            presets[i].bundledAsset = asset
            let dest = presetsDir.appendingPathComponent("\(asset).png")

            if !fm.fileExists(atPath: dest.path) {
                let image = NSImage(named: asset)
                guard let image,
                      let cgRef = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let rep = NSBitmapImageRep(cgImage: cgRef)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                try? png.write(to: dest)
            }
            presets[i].filePath = dest.path
        }
    }
}
