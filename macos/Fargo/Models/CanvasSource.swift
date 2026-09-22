import Foundation
import simd

enum CanvasSourceType: String, Codable, CaseIterable, Identifiable {
    case camera
    case screenCapture
    case mediaFile
    case image

    var id: String { rawValue }

    var label: String {
        switch self {
        case .camera: return "Camera"
        case .screenCapture: return "Screen"
        case .mediaFile: return "Media"
        case .image: return "Image"
        }
    }

    var icon: String {
        switch self {
        case .camera: return "camera"
        case .screenCapture: return "display"
        case .mediaFile: return "play.rectangle"
        case .image: return "photo"
        }
    }
}

// MARK: - Color Filter Preset

enum ColorFilterPreset: String, Codable, CaseIterable, Identifiable {
    case none
    case polish
    case crisp
    case warm
    case soft
    case faded
    case bw
    case noir

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "NONE"
        case .polish: return "POLISH"
        case .crisp: return "CRISP"
        case .warm: return "WARM"
        case .soft: return "SOFT"
        case .faded: return "FADED"
        case .bw: return "B&W"
        case .noir: return "NOIR"
        }
    }

    var colorParams: (brightness: Float, contrast: Float, saturation: Float, gamma: Float, temperature: Float)? {
        switch self {
        case .none: return nil
        case .polish: return (0.02, 1.15, 1.05, 1.0, 0.08)
        case .crisp: return (0.0, 1.3, 0.95, 1.0, -0.15)
        case .warm: return (0.03, 1.05, 0.85, 1.0, 0.2)
        case .soft: return (0.05, 1.0, 0.8, 0.95, 0.1)
        case .faded: return (0.08, 1.1, 0.5, 1.3, 0.15)
        case .bw: return (0.0, 1.0, 0.0, 1.0, 0.0)
        case .noir: return (0.0, 1.4, 0.0, 1.0, 0.0)
        }
    }
}

// MARK: - Resolved color correction values

struct ResolvedColorCorrection {
    var enabled: Bool
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var gamma: Float
    var temperature: Float
}

// MARK: - Canvas Source

struct CanvasSource: Identifiable, Codable {
    let id: UUID
    var type: CanvasSourceType
    var label: String

    // Normalized 0-1, top-left origin
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    var zOrder: Int
    var cornerRadius: CGFloat
    var opacity: CGFloat
    var isVisible: Bool
    var isLocked: Bool

    var cameraDeviceId: String
    var isMirrored: Bool
    var cropLeft: CGFloat
    var cropRight: CGFloat
    var cropTop: CGFloat
    var cropBottom: CGFloat

    // Screen source spec: "d:<displayId>" or "w:<windowId>". Empty means the global default.
    var screenSourceSpec: String

    var imagePath: String

    var backgroundMode: BackgroundMode
    var backgroundBlurRadius: CGFloat
    var backgroundRemovalColor: CodableSIMD4

    var colorCorrectionEnabled: Bool
    var colorBrightness: Float
    var colorContrast: Float
    var colorSaturation: Float
    var colorGamma: Float
    var colorTemperature: Float

    var skinSmoothingEnabled: Bool
    var skinSmoothingIntensity: Float

    var colorFilterPreset: ColorFilterPreset

    var effectiveColorCorrection: ResolvedColorCorrection {
        if let preset = colorFilterPreset.colorParams {
            return ResolvedColorCorrection(
                enabled: true,
                brightness: preset.brightness,
                contrast: preset.contrast,
                saturation: preset.saturation,
                gamma: preset.gamma,
                temperature: preset.temperature
            )
        }
        return ResolvedColorCorrection(
            enabled: colorCorrectionEnabled,
            brightness: colorBrightness,
            contrast: colorContrast,
            saturation: colorSaturation,
            gamma: colorGamma,
            temperature: colorTemperature
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(CanvasSourceType.self, forKey: .type)
        label = try container.decode(String.self, forKey: .label)
        x = try container.decode(CGFloat.self, forKey: .x)
        y = try container.decode(CGFloat.self, forKey: .y)
        width = try container.decode(CGFloat.self, forKey: .width)
        height = try container.decode(CGFloat.self, forKey: .height)
        zOrder = try container.decode(Int.self, forKey: .zOrder)
        cornerRadius = try container.decode(CGFloat.self, forKey: .cornerRadius)
        opacity = try container.decode(CGFloat.self, forKey: .opacity)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        cameraDeviceId = try container.decodeIfPresent(String.self, forKey: .cameraDeviceId) ?? ""
        isMirrored = try container.decode(Bool.self, forKey: .isMirrored)
        cropLeft = try container.decode(CGFloat.self, forKey: .cropLeft)
        cropRight = try container.decode(CGFloat.self, forKey: .cropRight)
        cropTop = try container.decode(CGFloat.self, forKey: .cropTop)
        cropBottom = try container.decode(CGFloat.self, forKey: .cropBottom)
        screenSourceSpec = try container.decodeIfPresent(String.self, forKey: .screenSourceSpec) ?? ""
        imagePath = try container.decode(String.self, forKey: .imagePath)

        backgroundMode = try container.decodeIfPresent(BackgroundMode.self, forKey: .backgroundMode) ?? .none
        backgroundBlurRadius = try container.decodeIfPresent(CGFloat.self, forKey: .backgroundBlurRadius) ?? 20
        backgroundRemovalColor = try container.decodeIfPresent(CodableSIMD4.self, forKey: .backgroundRemovalColor) ?? CodableSIMD4()

        colorCorrectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .colorCorrectionEnabled) ?? false
        colorBrightness = try container.decodeIfPresent(Float.self, forKey: .colorBrightness) ?? 0.0
        colorContrast = try container.decodeIfPresent(Float.self, forKey: .colorContrast) ?? 1.0
        colorSaturation = try container.decodeIfPresent(Float.self, forKey: .colorSaturation) ?? 1.0
        colorGamma = try container.decodeIfPresent(Float.self, forKey: .colorGamma) ?? 1.0
        colorTemperature = try container.decodeIfPresent(Float.self, forKey: .colorTemperature) ?? 0.0

        skinSmoothingEnabled = try container.decodeIfPresent(Bool.self, forKey: .skinSmoothingEnabled) ?? false
        skinSmoothingIntensity = try container.decodeIfPresent(Float.self, forKey: .skinSmoothingIntensity) ?? 0.5

        colorFilterPreset = try container.decodeIfPresent(ColorFilterPreset.self, forKey: .colorFilterPreset) ?? .none
    }

    init(type: CanvasSourceType, label: String? = nil, zOrder: Int = 0) {
        self.id = UUID()
        self.type = type
        self.label = label ?? type.label
        self.zOrder = zOrder
        self.cornerRadius = 0
        self.opacity = 1.0
        self.isVisible = true
        self.isLocked = false
        self.cameraDeviceId = ""
        self.isMirrored = true
        self.cropLeft = 0
        self.cropRight = 0
        self.cropTop = 0
        self.cropBottom = 0
        self.screenSourceSpec = ""
        self.imagePath = ""

        self.backgroundMode = .none
        self.backgroundBlurRadius = 20
        self.backgroundRemovalColor = CodableSIMD4()

        self.colorCorrectionEnabled = false
        self.colorBrightness = 0.0
        self.colorContrast = 1.0
        self.colorSaturation = 1.0
        self.colorGamma = 1.0
        self.colorTemperature = 0.0

        self.skinSmoothingEnabled = false
        self.skinSmoothingIntensity = 0.5

        self.colorFilterPreset = .none

        switch type {
        case .camera:
            self.x = 0.05
            self.y = 0.05
            self.width = 0.4
            self.height = 0.4 * (9.0 / 16.0)
            self.cornerRadius = 8
        case .screenCapture:
            self.x = 0.0
            self.y = 0.0
            self.width = 1.0
            self.height = 1.0 * (9.0 / 16.0)
        case .mediaFile:
            self.x = 0.1
            self.y = 0.1
            self.width = 0.8
            self.height = 0.8 * (9.0 / 16.0)
        case .image:
            self.x = 0.3
            self.y = 0.3
            self.width = 0.3
            self.height = 0.3
        }
    }
}

// MARK: - Codable SIMD4<Float> wrapper

struct CodableSIMD4: Codable, Equatable {
    var x: Float
    var y: Float
    var z: Float
    var w: Float

    init(_ simd: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)) {
        self.x = simd.x
        self.y = simd.y
        self.z = simd.z
        self.w = simd.w
    }

    var simd: SIMD4<Float> {
        SIMD4<Float>(x, y, z, w)
    }
}
