import Foundation
import CoreGraphics
import AppKit

struct OverlayColor: Codable, Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    static let white = OverlayColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let black = OverlayColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let yellow = OverlayColor(red: 1, green: 0.92, blue: 0.23, alpha: 1)
    static let red = OverlayColor(red: 1, green: 0.27, blue: 0.27, alpha: 1)
    static let green = OverlayColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1)
    static let blue = OverlayColor(red: 0.35, green: 0.55, blue: 1, alpha: 1)

    var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.red = c.redComponent
        self.green = c.greenComponent
        self.blue = c.blueComponent
        self.alpha = c.alphaComponent
    }

    static let presets: [OverlayColor] = [.white, .black, .yellow, .red, .green, .blue]
}

enum OverlayFontWeight: String, Codable, CaseIterable, Identifiable {
    case regular = "Regular"
    case medium = "Medium"
    case semibold = "Semibold"
    case bold = "Bold"

    var id: String { rawValue }

    var nsWeight: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

enum OverlayTextAlignment: String, Codable, CaseIterable, Identifiable {
    case left = "Left"
    case center = "Center"
    case right = "Right"

    var id: String { rawValue }

    var nsAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}

enum OverlayEntranceAnimation: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case fade = "Fade"
    case slideLeft = "Slide ←"
    case slideRight = "Slide →"
    case slideTop = "Slide ↑"
    case slideBottom = "Slide ↓"
    case zoom = "Zoom"
    case pop = "Pop"

    var id: String { rawValue }
}

enum OverlayLoopAnimation: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case pulse = "Pulse"
    case float = "Float"
    case shake = "Shake"
    case glow = "Glow"

    var id: String { rawValue }
}

struct StreamOverlay: Identifiable, Codable {
    let id: UUID
    var type: OverlayType
    var isVisible: Bool
    var text: String
    var imagePath: String
    var fontSize: CGFloat
    var opacity: CGFloat

    var textColor: OverlayColor
    var backgroundColor: OverlayColor
    var fontWeight: OverlayFontWeight

    // Normalized 0-1 relative to the canvas
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    var textAlignment: OverlayTextAlignment
    var horizontalPadding: CGFloat
    var fontFamily: String
    var textStyle: TextOverlayStyle
    var autoFitFont: Bool

    var mediaPath: String
    var mediaIsLooping: Bool

    var chatFontSize: CGFloat
    var chatMaxMessages: Int
    var chatAuthorColor: OverlayColor

    var entranceAnimation: OverlayEntranceAnimation
    var entranceDurationSeconds: Double
    var loopAnimation: OverlayLoopAnimation
    var loopSpeed: Double

    init(type: OverlayType, text: String = "", imagePath: String = "", mediaPath: String = "") {
        self.id = UUID()
        self.type = type
        self.isVisible = true
        self.text = text
        self.imagePath = imagePath
        self.fontSize = 24
        self.opacity = 1.0
        self.textColor = .white
        self.backgroundColor = OverlayColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        self.fontWeight = .semibold
        self.textAlignment = .left
        self.horizontalPadding = 12
        self.fontFamily = ""
        self.textStyle = .classic
        self.autoFitFont = true
        self.mediaPath = mediaPath
        self.mediaIsLooping = true
        self.chatFontSize = 14
        self.chatMaxMessages = 15
        self.chatAuthorColor = OverlayColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0)
        self.entranceAnimation = .none
        self.entranceDurationSeconds = 0.6
        self.loopAnimation = .none
        self.loopSpeed = 1.0

        switch type {
        case .chat:
            self.x = 0.7
            self.y = 0.1
            self.width = 0.28
            self.height = 0.6
            self.backgroundColor = OverlayColor(red: 0, green: 0, blue: 0, alpha: 0.6)
            self.opacity = 0.85
        case .media:
            self.x = 0.05
            self.y = 0.05
            self.width = 0.3
            self.height = 0.3
            self.backgroundColor = OverlayColor(red: 0, green: 0, blue: 0, alpha: 0)
        case .captions:
            self.x = 0.1
            self.y = 0.82
            self.width = 0.8
            self.height = 0.12
            self.fontSize = 36
            self.textAlignment = .center
            self.horizontalPadding = 24
            self.backgroundColor = OverlayColor(red: 0, green: 0, blue: 0, alpha: 0.7)
        default:
            self.x = 0.05
            self.y = 0.85
            self.width = 0.3
            self.height = 0.08
        }
    }

    var nsFont: NSFont {
        let weight = fontWeight.nsWeight
        if fontFamily.isEmpty {
            return NSFont.systemFont(ofSize: fontSize, weight: weight)
        }
        if let font = NSFont(name: fontFamily, size: fontSize) {
            return font
        }
        return NSFont.systemFont(ofSize: fontSize, weight: weight)
    }

    // MARK: - Codable (backward compatible)

    private enum CodingKeys: String, CodingKey {
        case id, type, isVisible, text, imagePath, fontSize, opacity
        case textColor, backgroundColor, fontWeight
        case x, y, width, height
        case textAlignment, horizontalPadding, fontFamily, textStyle, autoFitFont
        case mediaPath, mediaIsLooping
        case chatFontSize, chatMaxMessages, chatAuthorColor
        case entranceAnimation, entranceDurationSeconds, loopAnimation, loopSpeed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.type = try c.decode(OverlayType.self, forKey: .type)
        self.isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath) ?? ""
        self.fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 24
        self.opacity = try c.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 1
        self.textColor = try c.decodeIfPresent(OverlayColor.self, forKey: .textColor) ?? .white
        self.backgroundColor = try c.decodeIfPresent(OverlayColor.self, forKey: .backgroundColor)
            ?? OverlayColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        self.fontWeight = try c.decodeIfPresent(OverlayFontWeight.self, forKey: .fontWeight) ?? .semibold
        self.x = try c.decodeIfPresent(CGFloat.self, forKey: .x) ?? 0.05
        self.y = try c.decodeIfPresent(CGFloat.self, forKey: .y) ?? 0.85
        self.width = try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? 0.3
        self.height = try c.decodeIfPresent(CGFloat.self, forKey: .height) ?? 0.08
        self.textAlignment = try c.decodeIfPresent(OverlayTextAlignment.self, forKey: .textAlignment) ?? .left
        self.horizontalPadding = try c.decodeIfPresent(CGFloat.self, forKey: .horizontalPadding) ?? 12
        self.fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? ""
        self.textStyle = try c.decodeIfPresent(TextOverlayStyle.self, forKey: .textStyle) ?? .classic
        self.autoFitFont = try c.decodeIfPresent(Bool.self, forKey: .autoFitFont) ?? true
        self.mediaPath = try c.decodeIfPresent(String.self, forKey: .mediaPath) ?? ""
        self.mediaIsLooping = try c.decodeIfPresent(Bool.self, forKey: .mediaIsLooping) ?? true
        self.chatFontSize = try c.decodeIfPresent(CGFloat.self, forKey: .chatFontSize) ?? 14
        self.chatMaxMessages = try c.decodeIfPresent(Int.self, forKey: .chatMaxMessages) ?? 15
        self.chatAuthorColor = try c.decodeIfPresent(OverlayColor.self, forKey: .chatAuthorColor)
            ?? OverlayColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0)
        self.entranceAnimation = try c.decodeIfPresent(OverlayEntranceAnimation.self, forKey: .entranceAnimation) ?? .none
        self.entranceDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .entranceDurationSeconds) ?? 0.6
        self.loopAnimation = try c.decodeIfPresent(OverlayLoopAnimation.self, forKey: .loopAnimation) ?? .none
        self.loopSpeed = try c.decodeIfPresent(Double.self, forKey: .loopSpeed) ?? 1.0
    }
}

// MARK: - Text Overlay Styles

enum TextOverlayStyle: String, Codable, CaseIterable, Identifiable {
    case classic
    case minimal
    case neon
    case sunset
    case ocean
    case highlight
    case outline
    case pill
    case terminal
    case glass
    case retro
    case stripe

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .minimal: return "Minimal"
        case .neon: return "Neon"
        case .sunset: return "Sunset"
        case .ocean: return "Ocean"
        case .highlight: return "Highlight"
        case .outline: return "Outline"
        case .pill: return "Pill"
        case .terminal: return "Terminal"
        case .glass: return "Glass"
        case .retro: return "Retro"
        case .stripe: return "Stripe"
        }
    }

    var usesCustomColors: Bool {
        return self == .classic
    }

    // MARK: Rendering

    func draw(overlay: StreamOverlay, into ctx: CGContext, width w: Int, height h: Int) {
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx
        defer { NSGraphicsContext.current = nil }

        let text = overlay.text
        if text.isEmpty { return }

        switch self {
        case .classic:
            drawClassic(overlay: overlay, ctx: ctx, rect: rect)
        case .minimal:
            drawMinimal(overlay: overlay, ctx: ctx, rect: rect)
        case .neon:
            drawNeon(overlay: overlay, ctx: ctx, rect: rect)
        case .sunset:
            drawGradient(overlay: overlay, ctx: ctx, rect: rect,
                         colors: [
                            CGColor(red: 1.00, green: 0.42, blue: 0.21, alpha: 1),
                            CGColor(red: 0.98, green: 0.25, blue: 0.45, alpha: 1),
                            CGColor(red: 0.56, green: 0.16, blue: 0.60, alpha: 1),
                         ])
        case .ocean:
            drawGradient(overlay: overlay, ctx: ctx, rect: rect,
                         colors: [
                            CGColor(red: 0.10, green: 0.35, blue: 0.85, alpha: 1),
                            CGColor(red: 0.15, green: 0.68, blue: 0.85, alpha: 1),
                            CGColor(red: 0.20, green: 0.85, blue: 0.75, alpha: 1),
                         ])
        case .highlight:
            drawHighlight(overlay: overlay, ctx: ctx, rect: rect)
        case .outline:
            drawOutline(overlay: overlay, ctx: ctx, rect: rect)
        case .pill:
            drawPill(overlay: overlay, ctx: ctx, rect: rect)
        case .terminal:
            drawTerminal(overlay: overlay, ctx: ctx, rect: rect)
        case .glass:
            drawGlass(overlay: overlay, ctx: ctx, rect: rect)
        case .retro:
            drawRetro(overlay: overlay, ctx: ctx, rect: rect)
        case .stripe:
            drawStripe(overlay: overlay, ctx: ctx, rect: rect)
        }
    }

    // MARK: Style implementations

    private func resolveFont(overlay: StreamOverlay,
                             measuring text: String? = nil,
                             in rect: CGRect,
                             maxRatio: CGFloat = 0.62,
                             defaultMonospaced: Bool = false) -> NSFont {
        let make = makeUserFont(overlay: overlay, defaultMonospaced: defaultMonospaced)
        if overlay.autoFitFont {
            return fitFontSize(text: text ?? overlay.text, in: rect, maxRatio: maxRatio, make: make)
        }
        return make(overlay.fontSize)
    }

    private func makeUserFont(overlay: StreamOverlay, defaultMonospaced: Bool = false) -> (CGFloat) -> NSFont {
        return { size in
            if !overlay.fontFamily.isEmpty, let f = NSFont(name: overlay.fontFamily, size: size) {
                let desc = f.fontDescriptor
                let weighted = desc.addingAttributes([
                    .traits: [NSFontDescriptor.TraitKey.weight: overlay.fontWeight.nsWeight.rawValue]
                ])
                return NSFont(descriptor: weighted, size: size) ?? f
            }
            if defaultMonospaced {
                return NSFont.monospacedSystemFont(ofSize: size, weight: overlay.fontWeight.nsWeight)
            }
            return NSFont.systemFont(ofSize: size, weight: overlay.fontWeight.nsWeight)
        }
    }

    private func drawClassic(overlay: StreamOverlay, ctx: CGContext, rect: CGRect) {
        fillRounded(ctx: ctx, rect: rect, color: overlay.backgroundColor.cgColor, radius: 6)
        let textRect = rect.insetBy(dx: overlay.horizontalPadding, dy: 0)
        let font = resolveFont(overlay: overlay, in: textRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: overlay.textColor.nsColor,
        ]
        drawText(overlay.text, in: textRect, attrs: attrs,
                 alignment: overlay.textAlignment.nsAlignment)
    }

    private func drawMinimal(overlay: StreamOverlay, ctx: CGContext, rect: CGRect) {
        let radius: CGFloat = min(rect.height * 0.22, 14)
        fillRounded(ctx: ctx, rect: rect, color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.96), radius: radius)
        strokeRounded(ctx: ctx, rect: rect.insetBy(dx: 0.75, dy: 0.75),
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.08),
                      radius: radius, lineWidth: 1.5)
        let textRect = rect.insetBy(dx: max(14, overlay.horizontalPadding), dy: 0)
        let font = resolveFont(overlay: overlay, in: textRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1),
            .kern: 0.2,
        ]
        drawText(overlay.text, in: textRect, attrs: attrs,
                 alignment: overlay.textAlignment.nsAlignment)
    }

    private func drawNeon(overlay: StreamOverlay, ctx: CGContext, rect: CGRect) {
        let radius: CGFloat = 8
        fillRounded(ctx: ctx, rect: rect, color: CGColor(red: 0.04, green: 0.02, blue: 0.08, alpha: 0.92), radius: radius)
        let neon = NSColor(red: 0.30, green: 1.00, blue: 0.95, alpha: 1)
        strokeRounded(ctx: ctx, rect: rect.insetBy(dx: 1.25, dy: 1.25),
                      color: neon.withAlphaComponent(0.9).cgColor,
                      radius: radius, lineWidth: 1.8)

        let textRect = rect.insetBy(dx: max(16, overlay.horizontalPadding), dy: 0)
        let font = resolveFont(overlay: overlay, in: textRect)

        let glow = NSShadow()
        glow.shadowColor = neon.withAlphaComponent(0.9)
        glow.shadowBlurRadius = max(6, font.pointSize * 0.3)
        glow.shadowOffset = .zero

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: neon,
            .shadow: glow,
            .kern: 1.0,
        ]
        drawText(overlay.text, in: textRect, attrs: attrs,
                 alignment: overlay.textAlignment.nsAlignment)
    }

    private func drawGradient(overlay: StreamOverlay, ctx: CGContext, rect: CGRect, colors: [CGColor]) {
        let radius: CGFloat = min(rect.height * 0.25, 14)
        ctx.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.clip()
        let space = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.maxY),
                end: CGPoint(x: rect.maxX, y: rect.minY),
                options: []
            )
        }
        ctx.restoreGState()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        let textRect = rect.insetBy(dx: max(16, overlay.horizontalPadding), dy: 0)
        let font = resolveFont(overlay: overlay, in: textRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .shadow: shadow,
            .kern: 0.3,
        ]
        drawText(overlay.text, in: textRect, attrs: attrs,
                 alignment: overlay.textAlignment.nsAlignment)
    }

    private func drawHighlight(overlay: StreamOverlay, ctx: CGContext, rect: CGRect) {
        let padding = max(12, overlay.horizontalPadding)
        let textRect = rect.insetBy(dx: padding, dy: 0)
        let font = resolveFont(overlay: overlay, in: textRect)
        let para = NSMutableParagraphStyle()
        para.alignment = overlay.textAlignment.nsAlignment
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(red: 0.09, green: 0.09, blue: 0.12, alpha: 1),
            .paragraphStyle: para,
        ]
        let attr = NSAttributedString(string: overlay.text, attributes: attrs)
        let bounds = attr.boundingRect(
            with: CGSize(width: textRect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textH = ceil(bounds.height)
        let textW = ceil(bounds.width)
        let yOff = textRect.minY + (textRect.height - textH) / 2

        let hlPadX: CGFloat = 10
        let hlPadY: CGFloat = 4
        let hlX: CGFloat
        switch overlay.textAlignment {
        case .left:
            hlX = textRect.minX - hlPadX
        case .right:
            hlX = textRect.maxX - textW - hlPadX
        case .center:
            hlX = textRect.minX + (textRect.width - textW) / 2 - hlPadX
        }
        let hlRect = CGRect(x: hlX, y: yOff - hlPadY, width: textW + hlPadX * 2, height: textH + hlPadY * 2)
        ctx.setFillColor(CGColor(red: 1.0, green: 0.93, blue: 0.25, alpha: 1))
        ctx.fill(hlRect)

        attr.draw(in: CGRect(x: textRect.minX, y: yOff, width: textRect.width, height: textH))
    }

    private func drawOutline(overlay: StreamOverlay, ctx: CGContext, rect: CGRect) {
        let textRect = rect.insetBy(dx: max(10, overlay.horizontalPadding), dy: 0)
        let font = resolveFont(overlay: overlay, in: textRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -6.0,
            .kern: 0.5,
        ]
        drawText(overlay.text, in: textRect, attrs: attrs,
                 alignment: overlay.textAlignment.nsAlignment)
    }

    private func drawPill(overlay: StreamOverlay, ctx: CGContext, rect: CGRect) {
        let radius = rect.height / 2
        fillRounded(ctx: ctx, rect: rect, color: CGColor(red: 0.95, green: 0.20, blue: 0.35, alpha: 1), radius: radius)
        let textRect = rect.insetBy(dx: radius, dy: 0)
        let font = resolveFont(overlay: overlay, in: textRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: 0.6,
        ]
        drawText(overlay.text, in: textRect, attrs: attrs,
                 alignment: overlay.textAlignment.nsAlignment)
    }

    private func drawTerminal(overlay: StreamOverlay, ctx: CGContext, rect: CGRect) {
        let radius: CGFloat = 6
        fillRounded(ctx: ctx, rect: rect, color: CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 0.96), radius: radius)

        let barH: CGFloat = min(rect.height * 0.18, 12)
        ctx.saveGState()
        let clipPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()
        let barRect = CGRect(x: rect.minX, y: rect.maxY - barH, width: rect.width, height: barH)
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        ctx.fill(barRect)
        let dotY = barRect.midY
        let dotR: CGFloat = min(barH * 0.28, 3.5)
        let dotColors: [CGColor] = [
            CGColor(red: 1.0, green: 0.36, blue: 0.36, alpha: 1),
            CGColor(red: 1.0, green: 0.76, blue: 0.20, alpha: 1),
            CGColor(red: 0.30, green: 0.84, blue: 0.38, alpha: 1),
        ]
        for (i, color) in dotColors.enumerated() {
            let cx = barRect.minX + 8 + CGFloat(i) * (dotR * 2 + 4)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: cx - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2))
        }
        ctx.restoreGState()

        let textRect = CGRect(
            x: rect.minX + max(14, overlay.horizontalPadding),
            y: rect.minY,
            width: rect.width - max(14, overlay.horizontalPadding) * 2,
            height: rect.height - barH
        )
        let fullText = "$ " + overlay.text
        let font = resolveFont(overlay: overlay, measuring: fullText, in: textRect,
                               maxRatio: 0.55, defaultMonospaced: true)

        let prompt = NSMutableAttributedString(
            string: "$ ",
            attributes: [
                .font: font,
                .foregroundColor: NSColor(red: 0.30, green: 0.84, blue: 0.38, alpha: 1),
            ]
        )
        prompt.append(NSAttributedString(
            string: overlay.text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor(red: 0.85, green: 0.95, blue: 0.85, alpha: 1),
            ]
        ))
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineBreakMode = .byWordWrapping
        prompt.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: prompt.length))

        let bounds = prompt.boundingRect(
            with: CGSize(width: textRect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textH = ceil(bounds.height)
        let yOff = textRect.minY + (textRect.height - textH) / 2
        prompt.draw(in: CGRect(x: textRect.minX, y: yOff, width: textRect.width, height: textH))
    }

    private func drawGlass(overlay: StreamOverlay, ctx: CGContext, rect: CGRect) {
        let radius: CGFloat = min(rect.height * 0.25, 14)
        fillRounded(ctx: ctx, rect: rect, color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.14), radius: radius)

        ctx.saveGState()
        let clipPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()
        let space = CGColorSpaceCreateDeviceRGB()
        let highlightColors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
        ]
        if let g = CGGradient(colorsSpace: space, colors: highlightColors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g,
                                    start: CGPoint(x: rect.midX, y: rect.maxY),
                                    end: CGPoint(x: rect.midX, y: rect.midY),
                                    options: [])
        }
        ctx.restoreGState()

        strokeRounded(ctx: ctx, rect: rect.insetBy(dx: 0.75, dy: 0.75),
                      color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.35),
                      radius: radius, lineWidth: 1.2)

        let textRect = rect.insetBy(dx: max(14, overlay.horizontalPadding), dy: 0)
        let font = resolveFont(overlay: overlay, in: textRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: 0.4,
        ]
        drawText(overlay.text, in: textRect, attrs: attrs,
                 alignment: overlay.textAlignment.nsAlignment)
    }

    private func drawRetro(overlay: StreamOverlay, ctx: CGContext, rect: CGRect) {
        let radius: CGFloat = 4
        fillRounded(ctx: ctx, rect: rect, color: CGColor(red: 0.09, green: 0.05, blue: 0.20, alpha: 1), radius: radius)

        let padding = max(14, overlay.horizontalPadding)
        let textRect = rect.insetBy(dx: padding, dy: 0)
        let font = resolveFont(overlay: overlay, in: textRect)

        let offset: CGFloat = max(2, font.pointSize * 0.06)

        let cyan = NSColor(red: 0.20, green: 0.95, blue: 1.0, alpha: 1)
        let shadowAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: cyan,
            .kern: 1.5,
        ]
        drawText(overlay.text, in: textRect.offsetBy(dx: offset, dy: -offset), attrs: shadowAttrs,
                 alignment: overlay.textAlignment.nsAlignment)

        let magenta = NSColor(red: 1.0, green: 0.25, blue: 0.72, alpha: 1)
        let shadowAttrs2: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: magenta,
            .kern: 1.5,
        ]
        drawText(overlay.text, in: textRect.offsetBy(dx: -offset, dy: offset), attrs: shadowAttrs2,
                 alignment: overlay.textAlignment.nsAlignment)

        let mainAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(red: 1.0, green: 0.95, blue: 0.55, alpha: 1),
            .kern: 1.5,
        ]
        drawText(overlay.text, in: textRect, attrs: mainAttrs,
                 alignment: overlay.textAlignment.nsAlignment)
    }

    private func drawStripe(overlay: StreamOverlay, ctx: CGContext, rect: CGRect) {
        let radius: CGFloat = 4
        fillRounded(ctx: ctx, rect: rect, color: CGColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 0.94), radius: radius)

        let stripeW: CGFloat = max(4, min(rect.height * 0.12, 8))
        ctx.saveGState()
        let clipPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()
        let stripeRect = CGRect(x: rect.minX, y: rect.minY, width: stripeW, height: rect.height)
        ctx.setFillColor(CGColor(red: 0.26, green: 0.78, blue: 1.0, alpha: 1))
        ctx.fill(stripeRect)
        ctx.restoreGState()

        let leftInset = stripeW + 12
        let textRect = CGRect(
            x: rect.minX + leftInset,
            y: rect.minY,
            width: rect.width - leftInset - max(10, overlay.horizontalPadding),
            height: rect.height
        )
        let font = resolveFont(overlay: overlay, in: textRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: 0.2,
        ]
        drawText(overlay.text, in: textRect, attrs: attrs,
                 alignment: overlay.textAlignment.nsAlignment)
    }

    // MARK: Drawing helpers

    private func fitFontSize(text: String, in rect: CGRect, maxRatio: CGFloat = 0.62, make: (CGFloat) -> NSFont) -> NSFont {
        let baseSize = max(10, rect.height * maxRatio)
        let probe = make(baseSize)
        guard !text.isEmpty, rect.width > 0 else { return probe }
        let measured = (text as NSString).size(withAttributes: [.font: probe]).width
        if measured <= rect.width || measured == 0 {
            return probe
        }
        let scaled = max(8, baseSize * (rect.width / measured))
        return make(scaled)
    }

    private func fillRounded(ctx: CGContext, rect: CGRect, color: CGColor, radius: CGFloat) {
        ctx.setFillColor(color)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
    }

    private func strokeRounded(ctx: CGContext, rect: CGRect, color: CGColor, radius: CGFloat, lineWidth: CGFloat) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineWidth)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private func drawText(_ text: String, in rect: CGRect, attrs: [NSAttributedString.Key: Any], alignment: NSTextAlignment) {
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.lineBreakMode = .byWordWrapping
        var a = attrs
        a[.paragraphStyle] = para
        let attr = NSAttributedString(string: text, attributes: a)
        let bounds = attr.boundingRect(
            with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textH = ceil(bounds.height)
        let yOff = rect.minY + (rect.height - textH) / 2
        attr.draw(in: CGRect(x: rect.minX, y: yOff, width: rect.width, height: textH))
    }

    // MARK: Preview image (cached)

    private static var previewCache: [String: NSImage] = [:]
    private static let previewLock = NSLock()

    func previewImage(size: CGSize = CGSize(width: 160, height: 80), text: String = "Ab") -> NSImage? {
        let key = "\(rawValue)-\(text)-\(Int(size.width))x\(Int(size.height))"
        Self.previewLock.lock()
        if let cached = Self.previewCache[key] {
            Self.previewLock.unlock()
            return cached
        }
        Self.previewLock.unlock()

        let w = Int(size.width)
        let h = Int(size.height)
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        var overlay = StreamOverlay(type: .text, text: text)
        overlay.textStyle = self
        overlay.fontWeight = .semibold
        overlay.textAlignment = .center
        overlay.horizontalPadding = 10
        overlay.textColor = .white
        overlay.backgroundColor = OverlayColor(red: 0, green: 0, blue: 0, alpha: 0.55)

        draw(overlay: overlay, into: ctx, width: w, height: h)

        guard let cgImage = ctx.makeImage() else { return nil }
        let image = NSImage(cgImage: cgImage, size: size)

        Self.previewLock.lock()
        Self.previewCache[key] = image
        Self.previewLock.unlock()
        return image
    }
}

enum OverlayType: String, Codable, CaseIterable, Identifiable {
    case text = "Text"
    case image = "Image"
    case media = "Media"
    case chat = "Chat"
    case captions = "Live Captions"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .text: return "textformat"
        case .image: return "photo"
        case .media: return "film"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .captions: return "captions.bubble"
        }
    }

    var usesExplicitSize: Bool {
        switch self {
        case .chat, .captions:
            return true
        case .text, .image, .media:
            return false
        }
    }
}
