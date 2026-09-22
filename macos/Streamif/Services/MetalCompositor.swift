import CoreVideo
import CoreGraphics
import AppKit
import Metal

final class MetalCompositor: @unchecked Sendable {
    let outputSize: CGSize

    private var latestCameraBuffer: CVPixelBuffer?
    private var latestCameraMirrored: Bool = true
    private var latestCameraMask: CVPixelBuffer?
    private var latestScreenBuffer: CVPixelBuffer?
    private var latestMediaBuffer: CVPixelBuffer?
    private var extraCameraBuffers: [String: (buffer: CVPixelBuffer, mirrored: Bool)] = [:]
    private var extraScreenBuffers: [String: CVPixelBuffer] = [:]
    private let lock = NSLock()

    let backgroundBlur = BackgroundBlur()

    var canvasConfig = CanvasConfig()
    private var cachedBackgroundTexture: MTLTexture?
    private var cachedBackgroundKey: String?

    var skinSmoothingIntensity: Float = 0.5

    var colorCorrectionEnabled = false
    var colorBrightness: Float = 0.0
    var colorContrast: Float = 1.0
    var colorSaturation: Float = 1.0
    var colorGamma: Float = 1.0
    var colorTemperature: Float = 0.0

    private var cachedOverlayTextures: [UUID: (texture: MTLTexture, contentHash: Int)] = [:]
    private var _overlays: [StreamOverlay] = []
    private let overlayLock = NSLock()

    private var overlayAppearedAt: [UUID: Date] = [:]

    nonisolated(unsafe) var captionTextProvider: (() -> String)?
    private var captionText: String {
        captionTextProvider?() ?? ""
    }

    private var _chatMessages: [YouTubeChatMessage] = []
    private let chatLock = NSLock()

    private var _renderedOverlayRects: [UUID: CGRect] = [:]
    private let rectLock = NSLock()

    private var _canvasSources: [CanvasSource] = []
    private let canvasSourceLock = NSLock()
    private var cachedSourceTextures: [UUID: (texture: MTLTexture, contentHash: Int)] = [:]
    private var _renderedSourceRects: [UUID: CGRect] = [:]
    private let sourceRectLock = NSLock()

    private var gifPlayers: [UUID: GIFPlayer] = [:]
    private var gifTextureCache: [UUID: (texture: MTLTexture, version: UInt64)] = [:]
    private let gifLock = NSLock()

    private var _mediaImageTexture: MTLTexture?
    private let mediaImageLock = NSLock()

    var mediaImageTexture: MTLTexture? {
        get {
            mediaImageLock.lock()
            defer { mediaImageLock.unlock() }
            return _mediaImageTexture
        }
        set {
            mediaImageLock.lock()
            _mediaImageTexture = newValue
            mediaImageLock.unlock()
        }
    }

    func loadMediaImage(path: String) {
        guard let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let device = MTLCreateSystemDefaultDevice() else {
            mediaImageTexture = nil
            return
        }

        let width = cgImage.width
        let height = cgImage.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            mediaImageTexture = nil
            return
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            mediaImageTexture = nil
            return
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        if let data = context.data {
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: data,
                bytesPerRow: bytesPerRow
            )
        }

        mediaImageTexture = texture
    }

    private var overlayMediaPlayers: [UUID: MediaPlayer] = [:]
    private let mediaPlayerLock = NSLock()

    private var _featuredChatMessage: YouTubeChatMessage?
    private var cachedFeaturedTexture: (texture: MTLTexture, messageId: String)?
    private let featuredLock = NSLock()

    var featuredChatMessage: YouTubeChatMessage? {
        get {
            featuredLock.lock()
            defer { featuredLock.unlock() }
            return _featuredChatMessage
        }
        set {
            featuredLock.lock()
            _featuredChatMessage = newValue
            cachedFeaturedTexture = nil
            featuredLock.unlock()
        }
    }

    var renderedOverlayRects: [UUID: CGRect] {
        rectLock.lock()
        defer { rectLock.unlock() }
        return _renderedOverlayRects
    }

    var overlays: [StreamOverlay] {
        get {
            overlayLock.lock()
            defer { overlayLock.unlock() }
            return _overlays
        }
        set {
            overlayLock.lock()
            _overlays = newValue
            overlayLock.unlock()
        }
    }

    var chatMessages: [YouTubeChatMessage] {
        get {
            chatLock.lock()
            defer { chatLock.unlock() }
            return _chatMessages
        }
        set {
            chatLock.lock()
            _chatMessages = newValue
            chatLock.unlock()
        }
    }

    var canvasSources: [CanvasSource] {
        get {
            canvasSourceLock.lock()
            defer { canvasSourceLock.unlock() }
            return _canvasSources
        }
        set {
            canvasSourceLock.lock()
            _canvasSources = newValue
            canvasSourceLock.unlock()
        }
    }

    var renderedSourceRects: [UUID: CGRect] {
        sourceRectLock.lock()
        defer { sourceRectLock.unlock() }
        return _renderedSourceRects
    }

    init(width: Int = 1920, height: Int = 1080) {
        self.outputSize = CGSize(width: width, height: height)
    }

    // MARK: - Feed Frames (called from capture queues)

    func feedCameraFrame(_ pixelBuffer: CVPixelBuffer, mirrored: Bool) {
        let mask = backgroundBlur.segmentationMask(for: pixelBuffer)

        lock.lock()
        latestCameraBuffer = pixelBuffer
        latestCameraMirrored = mirrored
        latestCameraMask = mask
        lock.unlock()
    }

    func feedExtraCameraFrame(_ pixelBuffer: CVPixelBuffer, deviceId: String, mirrored: Bool) {
        lock.lock()
        extraCameraBuffers[deviceId] = (pixelBuffer, mirrored)
        lock.unlock()
    }

    func clearExtraCameraBuffer(deviceId: String) {
        lock.lock()
        extraCameraBuffers.removeValue(forKey: deviceId)
        lock.unlock()
    }

    // MARK: - First-Frame Placeholder Textures

    private var placeholderTextures: [CanvasSourceType: MTLTexture] = [:]
    private let placeholderLock = NSLock()

    func placeholderTexture(forType type: CanvasSourceType, renderer: MetalRenderer) -> MTLTexture? {
        placeholderLock.lock()
        if let cached = placeholderTextures[type] {
            placeholderLock.unlock()
            return cached
        }
        placeholderLock.unlock()

        let symbolName: String
        switch type {
        case .camera: symbolName = "video.slash.fill"
        case .screenCapture: symbolName = "display"
        case .mediaFile: symbolName = "play.rectangle"
        case .image: symbolName = "photo"
        }

        let width = 320
        let height = 180
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.setFillColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 56, weight: .regular)
            let configured = symbol.withSymbolConfiguration(config) ?? symbol
            let iconSize = configured.size
            let iconRect = CGRect(
                x: (CGFloat(width) - iconSize.width) / 2,
                y: (CGFloat(height) - iconSize.height) / 2,
                width: iconSize.width,
                height: iconSize.height
            )
            NSGraphicsContext.saveGraphicsState()
            let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.current = nsContext
            configured.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 0.35)
            NSGraphicsContext.restoreGraphicsState()
        }

        guard let cgImage = context.makeImage(),
              let texture = renderer.makeTexture(from: cgImage) else { return nil }

        placeholderLock.lock()
        placeholderTextures[type] = texture
        placeholderLock.unlock()
        return texture
    }

    private func placeholderQuad(for source: CanvasSource, renderer: MetalRenderer) -> RenderQuad? {
        guard let placeholder = placeholderTexture(forType: source.type, renderer: renderer) else {
            return nil
        }
        let canvas = outputSize
        let destX = source.x * canvas.width
        let destY = source.y * canvas.height
        let destW = source.width * canvas.width
        let destH = source.height * canvas.height
        guard destW > 1, destH > 1 else { return nil }

        let texW = CGFloat(placeholder.width)
        let texH = CGFloat(placeholder.height)
        let fitted = aspectFitInRect(texW: texW, texH: texH, rectW: destW, rectH: destH)
        let fittedRect = CGRect(
            x: destX + fitted.minX,
            y: destY + fitted.minY,
            width: fitted.width,
            height: fitted.height
        )

        sourceRectLock.lock()
        _renderedSourceRects[source.id] = fittedRect
        sourceRectLock.unlock()

        let frame = pixelRectToNDC(
            x: fittedRect.minX, y: fittedRect.minY,
            w: fittedRect.width, h: fittedRect.height,
            canvasSize: canvas
        )
        return RenderQuad(
            texture: placeholder,
            frame: frame,
            texCrop: SIMD4<Float>(0, 0, 1, 1),
            cornerRadius: Float(source.cornerRadius),
            opacity: Float(source.opacity),
            mirror: false,
            quadPixelSize: SIMD2<Float>(Float(fittedRect.width), Float(fittedRect.height))
        )
    }

    func feedScreenFrame(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        latestScreenBuffer = pixelBuffer
        lock.unlock()
    }

    func feedExtraScreenFrame(_ pixelBuffer: CVPixelBuffer, spec: String) {
        lock.lock()
        extraScreenBuffers[spec] = pixelBuffer
        lock.unlock()
    }

    func clearExtraScreenBuffer(spec: String) {
        lock.lock()
        extraScreenBuffers.removeValue(forKey: spec)
        lock.unlock()
    }

    func feedMediaFrame(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        latestMediaBuffer = pixelBuffer
        lock.unlock()
    }

    func clearMedia() {
        lock.lock()
        latestMediaBuffer = nil
        lock.unlock()
        mediaImageTexture = nil
    }

    // MARK: - Build Render Quads (called from MTKView draw)

    func buildQuads(
        renderer: MetalRenderer,
        commandBuffer: MTLCommandBuffer,
        screenBlurred: Bool = false
    ) -> [RenderQuad] {
        lock.lock()
        let cameraPB = latestCameraBuffer
        let screenPB = latestScreenBuffer
        let mediaPB = latestMediaBuffer
        let mirrored = latestCameraMirrored
        let maskPB = latestCameraMask
        let extraCameras = extraCameraBuffers
        let extraScreens = extraScreenBuffers
        lock.unlock()

        var quads: [RenderQuad] = []
        let canvas = outputSize
        let config = canvasConfig

        if config.hasBackground {
            if let bgTex = loadBackgroundTexture(renderer: renderer) {
                let bgCrop = aspectFillCrop(texW: CGFloat(bgTex.width), texH: CGFloat(bgTex.height), slotW: canvas.width, slotH: canvas.height)
                quads.append(RenderQuad(
                    texture: bgTex,
                    frame: SIMD4<Float>(-1, -1, 2, 2),
                    texCrop: bgCrop,
                    cornerRadius: 0, opacity: 1.0, mirror: false,
                    quadPixelSize: SIMD2<Float>(Float(canvas.width), Float(canvas.height))
                ))
            }
        }

        let cameraTexture: MTLTexture? = {
            guard let pb = cameraPB, let tex = renderer.makeTexture(from: pb) else { return nil }

            var result = tex

            if let maskPB = maskPB,
               let maskTex = renderer.makeTexture(from: maskPB, pixelFormat: .r8Unorm) {
                switch backgroundBlur.currentMode {
                case .blur:
                    result = renderer.blurComposite(
                        camera: result,
                        mask: maskTex,
                        radius: Float(backgroundBlur.blurRadius),
                        commandBuffer: commandBuffer
                    ) ?? result
                case .remove:
                    result = renderer.removeBackground(
                        camera: result,
                        mask: maskTex,
                        color: backgroundBlur.removalColor,
                        commandBuffer: commandBuffer
                    ) ?? result
                case .none:
                    break
                }

                if backgroundBlur.skinSmoothingEnabled {
                    result = renderer.applySkinSmoothing(
                        texture: result,
                        mask: maskTex,
                        intensity: skinSmoothingIntensity,
                        commandBuffer: commandBuffer
                    ) ?? result
                }
            }

            if colorCorrectionEnabled {
                result = renderer.applyColorCorrection(
                    texture: result,
                    brightness: colorBrightness,
                    contrast: colorContrast,
                    saturation: colorSaturation,
                    gamma: colorGamma,
                    temperature: colorTemperature,
                    commandBuffer: commandBuffer
                ) ?? result
            }

            return result
        }()

        let sourceQuadStart = quads.count
        let sources = canvasSources
            .filter { $0.isVisible }
            .sorted { $0.zOrder < $1.zOrder }

        for source in sources {
            if let quad = makeCanvasSourceQuad(
                source: source,
                renderer: renderer,
                commandBuffer: commandBuffer,
                cameraTexture: cameraTexture,
                cameraPB: cameraPB,
                screenPB: screenPB,
                mediaPB: mediaPB,
                capturedMirrored: mirrored,
                screenBlurred: screenBlurred,
                extraCameras: extraCameras,
                extraScreens: extraScreens
            ) {
                quads.append(quad)
            }
        }

        if config.padding > 0 || config.cornerRadius > 0 {
            applyPaddingTransform(quads: &quads, from: sourceQuadStart, config: config, canvas: canvas)
        }

        let visibleOverlays = overlays.filter { $0.isVisible }
        for overlay in visibleOverlays {
            if let quad = makeOverlayQuad(overlay: overlay, renderer: renderer) {
                quads.append(quad)
            }
        }

        if let featured = featuredChatMessage {
            if let quad = makeFeaturedChatQuad(message: featured, renderer: renderer) {
                quads.append(quad)
            }
        }

        return quads
    }

    // MARK: - Overlay Quads

    private func makeOverlayQuad(overlay: StreamOverlay, renderer: MetalRenderer) -> RenderQuad? {
        let texture: MTLTexture

        if overlay.type == .media {
            mediaPlayerLock.lock()
            let player: MediaPlayer
            if let existing = overlayMediaPlayers[overlay.id] {
                player = existing
            } else {
                let newPlayer = MediaPlayer()
                newPlayer.isLooping = overlay.mediaIsLooping
                if !overlay.mediaPath.isEmpty {
                    newPlayer.load(url: URL(fileURLWithPath: overlay.mediaPath))
                    newPlayer.play()
                }
                overlayMediaPlayers[overlay.id] = newPlayer
                player = newPlayer
            }
            mediaPlayerLock.unlock()

            guard let pb = player.latestFrame(),
                  let tex = renderer.makeTexture(from: pb) else {
                return nil
            }
            texture = tex

            let canvas = outputSize
            let destX = overlay.x * canvas.width
            let destY = overlay.y * canvas.height
            let destW = overlay.width * canvas.width
            let destH = overlay.height * canvas.height

            let texW = CGFloat(tex.width)
            let texH = CGFloat(tex.height)
            let fitted = aspectFitInRect(texW: texW, texH: texH, rectW: destW, rectH: destH)
            let x = destX + fitted.minX
            let y = destY + fitted.minY
            let w = fitted.width
            let h = fitted.height

            rectLock.lock()
            _renderedOverlayRects[overlay.id] = CGRect(x: x, y: y, width: w, height: h)
            rectLock.unlock()

            let frame = pixelRectToNDC(x: x, y: y, w: w, h: h, canvasSize: canvas)

            return RenderQuad(
                texture: texture,
                frame: frame,
                texCrop: SIMD4<Float>(0, 0, 1, 1),
                cornerRadius: 0,
                opacity: Float(overlay.opacity),
                mirror: false,
                quadPixelSize: SIMD2<Float>(Float(w), Float(h))
            )
        }

        if overlay.type == .image && GIFPlayer.isGIF(path: overlay.imagePath) {
            gifLock.lock()
            let player: GIFPlayer
            if let existing = gifPlayers[overlay.id], existing.isPlaying {
                player = existing
            } else {
                let newPlayer = GIFPlayer()
                if newPlayer.load(path: overlay.imagePath) {
                    gifPlayers[overlay.id] = newPlayer
                    player = newPlayer
                } else {
                    gifLock.unlock()
                    return nil
                }
            }

            let version = player.frameVersion
            if let cached = gifTextureCache[overlay.id], cached.version == version {
                gifLock.unlock()
                texture = cached.texture
            } else {
                gifLock.unlock()
                guard let cgImage = player.currentFrame,
                      let tex = renderer.makeTexture(from: cgImage) else { return nil }
                gifLock.lock()
                gifTextureCache[overlay.id] = (tex, version)
                gifLock.unlock()
                texture = tex
            }
        } else {
            var hasher = Hasher()
            hasher.combine(overlay.text)
            hasher.combine(overlay.imagePath)
            hasher.combine(overlay.type.rawValue)
            hasher.combine(overlay.textColor.red)
            hasher.combine(overlay.textColor.green)
            hasher.combine(overlay.textColor.blue)
            hasher.combine(overlay.backgroundColor.red)
            hasher.combine(overlay.backgroundColor.green)
            hasher.combine(overlay.backgroundColor.blue)
            hasher.combine(overlay.backgroundColor.alpha)
            hasher.combine(overlay.fontWeight.rawValue)
            hasher.combine(overlay.textAlignment.rawValue)
            hasher.combine(overlay.horizontalPadding)
            hasher.combine(overlay.fontFamily)
            hasher.combine(overlay.textStyle.rawValue)
            hasher.combine(overlay.width)
            hasher.combine(overlay.height)
            if overlay.type == .chat {
                let msgs = chatMessages
                for msg in msgs.suffix(overlay.chatMaxMessages) {
                    hasher.combine(msg.id)
                }
                hasher.combine(overlay.chatFontSize)
                hasher.combine(overlay.chatAuthorColor.red)
                hasher.combine(overlay.chatMaxMessages)
            }
            if overlay.type == .captions {
                hasher.combine(captionText)
            }
            let contentHash = hasher.finalize()
            let cached = cachedOverlayTextures[overlay.id]

            if let cached, cached.contentHash == contentHash {
                texture = cached.texture
            } else {
                guard let newTex = renderOverlayTexture(overlay: overlay, renderer: renderer) else { return nil }
                cachedOverlayTextures[overlay.id] = (newTex, contentHash)
                texture = newTex
            }
        }

        let canvas = outputSize
        let x = overlay.x * canvas.width
        let y = overlay.y * canvas.height

        let w: CGFloat
        let h: CGFloat

        if overlay.type.usesExplicitSize {
            w = overlay.width * canvas.width
            h = overlay.height * canvas.height
        } else {
            let texW = CGFloat(texture.width)
            let texH = CGFloat(texture.height)
            let texAspect = texW / max(texH, 1)
            w = overlay.width * canvas.width
            h = w / texAspect
        }

        rectLock.lock()
        _renderedOverlayRects[overlay.id] = CGRect(x: x, y: y, width: w, height: h)
        rectLock.unlock()

        let animated = applyOverlayAnimation(
            overlay: overlay,
            x: x, y: y, w: w, h: h,
            canvas: canvas,
            baseOpacity: Float(overlay.opacity)
        )

        let frame = pixelRectToNDC(x: animated.x, y: animated.y, w: animated.w, h: animated.h, canvasSize: canvas)

        return RenderQuad(
            texture: texture,
            frame: frame,
            texCrop: SIMD4<Float>(0, 0, 1, 1),
            cornerRadius: 6,
            opacity: animated.opacity,
            mirror: false,
            quadPixelSize: SIMD2<Float>(Float(animated.w), Float(animated.h))
        )
    }

    private func applyOverlayAnimation(
        overlay: StreamOverlay,
        x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
        canvas: CGSize,
        baseOpacity: Float
    ) -> (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, opacity: Float) {
        let now = Date()
        let appearedAt: Date
        if let existing = overlayAppearedAt[overlay.id] {
            appearedAt = existing
        } else {
            appearedAt = now
            overlayAppearedAt[overlay.id] = now
        }

        var rx = x
        var ry = y
        var rw = w
        var rh = h
        var opacity = baseOpacity

        if overlay.entranceAnimation != .none {
            let duration = max(0.05, overlay.entranceDurationSeconds)
            let rawT = min(1.0, now.timeIntervalSince(appearedAt) / duration)
            let t = 1 - pow(1 - rawT, 3)
            let invT = 1 - t

            switch overlay.entranceAnimation {
            case .none:
                break
            case .fade:
                opacity *= Float(t)
            case .slideLeft:
                rx = x - invT * (w + x)
                opacity *= Float(min(1, rawT * 2))
            case .slideRight:
                rx = x + invT * (canvas.width - x)
                opacity *= Float(min(1, rawT * 2))
            case .slideTop:
                ry = y - invT * (h + y)
                opacity *= Float(min(1, rawT * 2))
            case .slideBottom:
                ry = y + invT * (canvas.height - y)
                opacity *= Float(min(1, rawT * 2))
            case .zoom:
                let scale = 0.6 + 0.4 * t
                let newW = w * scale
                let newH = h * scale
                rx = x + (w - newW) / 2
                ry = y + (h - newH) / 2
                rw = newW
                rh = newH
                opacity *= Float(t)
            case .pop:
                let scale: CGFloat
                if rawT < 0.7 {
                    let k = rawT / 0.7
                    scale = 0.2 + 1.0 * (1 - pow(1 - k, 3))
                } else {
                    let k = (rawT - 0.7) / 0.3
                    scale = 1.2 - 0.2 * (1 - pow(1 - k, 2))
                }
                let newW = rw * scale
                let newH = rh * scale
                rx = rx + (rw - newW) / 2
                ry = ry + (rh - newH) / 2
                rw = newW
                rh = newH
                opacity *= Float(min(1, rawT * 2))
            }
        }

        if overlay.loopAnimation != .none {
            let speed = max(0.1, overlay.loopSpeed)
            let elapsed = now.timeIntervalSince(appearedAt)
            let phase = elapsed * speed

            switch overlay.loopAnimation {
            case .none:
                break
            case .pulse:
                let scale = 1.0 + 0.04 * sin(phase * .pi * 2)
                let newW = rw * scale
                let newH = rh * scale
                rx = rx + (rw - newW) / 2
                ry = ry + (rh - newH) / 2
                rw = newW
                rh = newH
            case .float:
                let dy = sin(phase * .pi * 2) * h * 0.08
                ry = ry + dy
            case .shake:
                let dx = sin(phase * .pi * 10) * w * 0.015
                rx = rx + dx
            case .glow:
                let k = 0.85 + 0.15 * (0.5 + 0.5 * sin(phase * .pi * 2))
                opacity *= Float(k)
            }
        }

        return (rx, ry, rw, rh, opacity)
    }

    private func renderOverlayTexture(overlay: StreamOverlay, renderer: MetalRenderer) -> MTLTexture? {
        switch overlay.type {
        case .text:
            return renderTextOverlayTexture(overlay: overlay, renderer: renderer)
        case .image:
            return renderImageTexture(overlay: overlay, renderer: renderer)
        case .media:
            return nil
        case .chat:
            return renderChatOverlayTexture(overlay: overlay, renderer: renderer)
        case .captions:
            return renderCaptionsTexture(overlay: overlay, renderer: renderer)
        }
    }

    private func renderCaptionsTexture(overlay: StreamOverlay, renderer: MetalRenderer) -> MTLTexture? {
        guard let (ctx, w, h) = makeOverlayContext(overlay: overlay) else { return nil }

        let rawText = captionText
        guard !rawText.isEmpty else {
            guard let cgImage = ctx.makeImage() else { return nil }
            return renderer.makeTexture(from: cgImage)
        }

        // Show only the most recent words so the caption slides like a subtitle instead
        // of growing into a paragraph.
        let maxWords = 14
        let words = rawText.split(separator: " ")
        let text: String
        if words.count > maxWords {
            text = words.suffix(maxWords).joined(separator: " ")
        } else {
            text = rawText
        }

        let cornerRadius: CGFloat = 10
        ctx.setFillColor(overlay.backgroundColor.cgColor)
        let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                            cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.addPath(bgPath)
        ctx.fillPath()

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx

        let font: NSFont
        if overlay.fontFamily.isEmpty {
            font = NSFont.systemFont(ofSize: overlay.fontSize, weight: overlay.fontWeight.nsWeight)
        } else {
            font = overlay.nsFont
        }

        let para = NSMutableParagraphStyle()
        para.alignment = overlay.textAlignment.nsAlignment
        para.lineBreakMode = .byWordWrapping

        let padding = overlay.horizontalPadding
        let maxWidth = CGFloat(w) - padding * 2
        let maxHeight = CGFloat(h) - 16

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: overlay.textColor.nsColor,
            .paragraphStyle: para,
        ]

        // Walk back from the end with CoreText's framesetter until the tail fits maxHeight.
        let fullAttr = NSAttributedString(string: text, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(fullAttr as CFAttributedString)
        let constraint = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)

        var displayText = text
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, constraint, nil
        )
        if suggested.height > maxHeight {
            let words = text.split(separator: " ")
            var keep = max(1, words.count / 2)
            while keep > 1 {
                let candidate = words.suffix(keep).joined(separator: " ")
                let candidateAttr = NSAttributedString(string: candidate, attributes: attrs)
                let fs = CTFramesetterCreateWithAttributedString(candidateAttr as CFAttributedString)
                let size = CTFramesetterSuggestFrameSizeWithConstraints(
                    fs, CFRange(location: 0, length: 0), nil, constraint, nil
                )
                if size.height <= maxHeight {
                    displayText = candidate
                    break
                }
                keep /= 2
            }
        }

        let finalAttr = NSAttributedString(string: displayText, attributes: attrs)
        let finalBounds = CTFramesetterSuggestFrameSizeWithConstraints(
            CTFramesetterCreateWithAttributedString(finalAttr as CFAttributedString),
            CFRange(location: 0, length: 0), nil, constraint, nil
        )
        let textH = ceil(finalBounds.height)
        let yOff = (CGFloat(h) - textH) / 2
        finalAttr.draw(in: CGRect(x: padding, y: yOff, width: maxWidth, height: textH))

        NSGraphicsContext.current = nil

        guard let cgImage = ctx.makeImage() else { return nil }
        return renderer.makeTexture(from: cgImage)
    }

    private func renderTextOverlayTexture(overlay: StreamOverlay, renderer: MetalRenderer) -> MTLTexture? {
        guard !overlay.text.isEmpty else { return nil }

        let targetW = overlay.width * outputSize.width
        let targetH = overlay.height * outputSize.height

        let w = Int(ceil(targetW))
        let h = Int(ceil(targetH))
        guard w > 0, h > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        overlay.textStyle.draw(overlay: overlay, into: ctx, width: w, height: h)

        guard let cgImage = ctx.makeImage() else { return nil }
        return renderer.makeTexture(from: cgImage)
    }

    private func renderImageTexture(overlay: StreamOverlay, renderer: MetalRenderer) -> MTLTexture? {
        guard !overlay.imagePath.isEmpty else { return nil }
        guard let nsImage = NSImage(contentsOfFile: overlay.imagePath),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return renderer.makeTexture(from: cgImage)
    }

    private func makeOverlayContext(overlay: StreamOverlay) -> (ctx: CGContext, w: Int, h: Int)? {
        let targetW = overlay.width * outputSize.width
        let targetH = overlay.height * outputSize.height
        let w = Int(ceil(targetW))
        let h = Int(ceil(targetH))
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        return (ctx, w, h)
    }

    // MARK: - Canvas Source Quads

    private func makeCanvasSourceQuad(
        source: CanvasSource,
        renderer: MetalRenderer,
        commandBuffer: MTLCommandBuffer,
        cameraTexture: MTLTexture?,
        cameraPB: CVPixelBuffer?,
        screenPB: CVPixelBuffer?,
        mediaPB: CVPixelBuffer?,
        capturedMirrored: Bool,
        screenBlurred: Bool = false,
        extraCameras: [String: (buffer: CVPixelBuffer, mirrored: Bool)] = [:],
        extraScreens: [String: CVPixelBuffer] = [:]
    ) -> RenderQuad? {
        let canvas = outputSize
        let destX = source.x * canvas.width
        let destY = source.y * canvas.height
        let destW = source.width * canvas.width
        let destH = source.height * canvas.height

        guard destW > 1, destH > 1 else { return nil }

        let texture: MTLTexture
        var texCrop = SIMD4<Float>(0, 0, 1, 1)
        var mirror = false

        let cc = source.effectiveColorCorrection

        switch source.type {
        case .camera:
            if !source.cameraDeviceId.isEmpty, let extra = extraCameras[source.cameraDeviceId] {
                guard var tex = renderer.makeTexture(from: extra.buffer) else {
                    return placeholderQuad(for: source, renderer: renderer)
                }
                if colorCorrectionEnabled {
                    tex = renderer.applyColorCorrection(
                        texture: tex,
                        brightness: colorBrightness,
                        contrast: colorContrast,
                        saturation: colorSaturation,
                        gamma: colorGamma,
                        temperature: colorTemperature,
                        commandBuffer: commandBuffer
                    ) ?? tex
                }
                if cc.enabled {
                    tex = renderer.applyColorCorrection(
                        texture: tex,
                        brightness: cc.brightness,
                        contrast: cc.contrast,
                        saturation: cc.saturation,
                        gamma: cc.gamma,
                        temperature: cc.temperature,
                        commandBuffer: commandBuffer
                    ) ?? tex
                }
                texture = tex
            } else {
                guard var tex = cameraTexture else {
                    return placeholderQuad(for: source, renderer: renderer)
                }
                if cc.enabled {
                    tex = renderer.applyColorCorrection(
                        texture: tex,
                        brightness: cc.brightness,
                        contrast: cc.contrast,
                        saturation: cc.saturation,
                        gamma: cc.gamma,
                        temperature: cc.temperature,
                        commandBuffer: commandBuffer
                    ) ?? tex
                }
                texture = tex
            }
            mirror = capturedMirrored && source.isMirrored
            texCrop = sourceCropRect(source)

        case .screenCapture:
            // Use the extra stream's buffer when this source overrides the screen source,
            // otherwise fall back to the main stream.
            let resolvedPB: CVPixelBuffer? = {
                if !source.screenSourceSpec.isEmpty, let extra = extraScreens[source.screenSourceSpec] {
                    return extra
                }
                return screenPB
            }()
            guard let pb = resolvedPB, let tex = renderer.makeTexture(from: pb) else {
                return placeholderQuad(for: source, renderer: renderer)
            }
            if screenBlurred {
                texture = renderer.blurTexture(tex, radius: 200, commandBuffer: commandBuffer) ?? tex
            } else {
                texture = tex
            }
            texCrop = sourceCropRect(source)

        case .mediaFile:
            guard let pb = mediaPB, let tex = renderer.makeTexture(from: pb) else { return nil }
            texture = tex
            texCrop = sourceCropRect(source)

        case .image:
            guard let tex = cachedOrRenderSourceTexture(source: source, renderer: renderer) else { return nil }
            texture = tex
        }

        let texW = CGFloat(texture.width)
        let texH = CGFloat(texture.height)
        var fittedRect: CGRect

        let fitted = aspectFitInRect(texW: texW, texH: texH, rectW: destW, rectH: destH)
        fittedRect = CGRect(x: destX + fitted.minX, y: destY + fitted.minY, width: fitted.width, height: fitted.height)

        let hasCrop = source.cropLeft > 0 || source.cropRight > 0 || source.cropTop > 0 || source.cropBottom > 0
        if hasCrop {
            let cL = source.type == .camera && mirror ? source.cropRight : source.cropLeft
            let cR = source.type == .camera && mirror ? source.cropLeft : source.cropRight
            let cT = source.cropTop
            let cB = source.cropBottom
            let fullW = fittedRect.width
            let fullH = fittedRect.height
            let croppedW = fullW * (1.0 - cL - cR)
            let croppedH = fullH * (1.0 - cT - cB)
            let croppedX = fittedRect.minX + fullW * cL
            let croppedY = fittedRect.minY + fullH * cT
            fittedRect = CGRect(x: croppedX, y: croppedY, width: croppedW, height: croppedH)
        }

        sourceRectLock.lock()
        _renderedSourceRects[source.id] = fittedRect
        sourceRectLock.unlock()

        let frame = pixelRectToNDC(x: fittedRect.minX, y: fittedRect.minY, w: fittedRect.width, h: fittedRect.height, canvasSize: canvas)

        return RenderQuad(
            texture: texture,
            frame: frame,
            texCrop: texCrop,
            cornerRadius: Float(source.cornerRadius),
            opacity: Float(source.opacity),
            mirror: mirror,
            quadPixelSize: SIMD2<Float>(Float(fittedRect.width), Float(fittedRect.height))
        )
    }

    private func sourceCropRect(_ source: CanvasSource) -> SIMD4<Float> {
        let left = Float(source.cropLeft)
        let right = Float(source.cropRight)
        let top = Float(source.cropTop)
        let bottom = Float(source.cropBottom)

        let u = left
        let v = top
        let w = max(0.05, 1.0 - left - right)
        let h = max(0.05, 1.0 - top - bottom)

        return SIMD4<Float>(u, v, w, h)
    }

    private func cachedOrRenderSourceTexture(source: CanvasSource, renderer: MetalRenderer) -> MTLTexture? {
        if source.type == .image && GIFPlayer.isGIF(path: source.imagePath) {
            gifLock.lock()
            let player: GIFPlayer
            if let existing = gifPlayers[source.id], existing.isPlaying {
                player = existing
            } else {
                let newPlayer = GIFPlayer()
                if newPlayer.load(path: source.imagePath) {
                    gifPlayers[source.id] = newPlayer
                    player = newPlayer
                } else {
                    gifLock.unlock()
                    return nil
                }
            }

            let version = player.frameVersion
            if let cached = gifTextureCache[source.id], cached.version == version {
                gifLock.unlock()
                return cached.texture
            }
            gifLock.unlock()

            guard let cgImage = player.currentFrame,
                  let tex = renderer.makeTexture(from: cgImage) else { return nil }
            gifLock.lock()
            gifTextureCache[source.id] = (tex, version)
            gifLock.unlock()
            return tex
        }

        var hasher = Hasher()
        hasher.combine(source.type.rawValue)
        hasher.combine(source.imagePath)

        let contentHash = hasher.finalize()

        if let cached = cachedSourceTextures[source.id], cached.contentHash == contentHash {
            return cached.texture
        }

        guard source.type == .image,
              !source.imagePath.isEmpty,
              let nsImage = NSImage(contentsOfFile: source.imagePath),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let newTexture = renderer.makeTexture(from: cgImage)
        if let tex = newTexture {
            cachedSourceTextures[source.id] = (tex, contentHash)
        }
        return newTexture
    }

    func clearSourceCache(for id: UUID) {
        cachedSourceTextures.removeValue(forKey: id)
        sourceRectLock.lock()
        _renderedSourceRects.removeValue(forKey: id)
        sourceRectLock.unlock()

        gifLock.lock()
        gifPlayers[id]?.stop()
        gifPlayers.removeValue(forKey: id)
        gifTextureCache.removeValue(forKey: id)
        gifLock.unlock()
    }

    func clearOverlayCache(for id: UUID) {
        cachedOverlayTextures.removeValue(forKey: id)
        overlayAppearedAt.removeValue(forKey: id)
        rectLock.lock()
        _renderedOverlayRects.removeValue(forKey: id)
        rectLock.unlock()

        gifLock.lock()
        gifPlayers[id]?.stop()
        gifPlayers.removeValue(forKey: id)
        gifTextureCache.removeValue(forKey: id)
        gifLock.unlock()

        mediaPlayerLock.lock()
        overlayMediaPlayers[id]?.stop()
        overlayMediaPlayers.removeValue(forKey: id)
        mediaPlayerLock.unlock()
    }

    func overlayMediaPlayer(for id: UUID) -> MediaPlayer? {
        mediaPlayerLock.lock()
        defer { mediaPlayerLock.unlock() }
        return overlayMediaPlayers[id]
    }

    func replayOverlayAnimation(for id: UUID) {
        overlayAppearedAt.removeValue(forKey: id)
    }

    // MARK: - Coordinate Helpers

    private func aspectFillCrop(texW: CGFloat, texH: CGFloat, slotW: CGFloat, slotH: CGFloat) -> SIMD4<Float> {
        let texAspect = texW / texH
        let slotAspect = slotW / slotH

        if texAspect > slotAspect {
            let visibleFraction = slotAspect / texAspect
            let cropX = (1.0 - visibleFraction) / 2.0
            return SIMD4<Float>(Float(cropX), 0, Float(visibleFraction), 1)
        } else {
            let visibleFraction = texAspect / slotAspect
            let cropY = (1.0 - visibleFraction) / 2.0
            return SIMD4<Float>(0, Float(cropY), 1, Float(visibleFraction))
        }
    }

    private func aspectFitInRect(texW: CGFloat, texH: CGFloat, rectW: CGFloat, rectH: CGFloat) -> CGRect {
        let texAspect = texW / texH
        let rectAspect = rectW / rectH

        let fitW: CGFloat
        let fitH: CGFloat
        if texAspect > rectAspect {
            fitW = rectW
            fitH = rectW / texAspect
        } else {
            fitH = rectH
            fitW = rectH * texAspect
        }

        let x = (rectW - fitW) / 2
        let y = (rectH - fitH) / 2
        return CGRect(x: x, y: y, width: fitW, height: fitH)
    }

    private func aspectFitNDC(textureWidth: CGFloat, textureHeight: CGFloat, canvasSize: CGSize) -> SIMD4<Float> {
        let texAspect = textureWidth / textureHeight
        let canvasAspect = canvasSize.width / canvasSize.height

        var scaleX: CGFloat = 1.0
        var scaleY: CGFloat = 1.0
        if texAspect > canvasAspect {
            scaleY = canvasAspect / texAspect
        } else {
            scaleX = texAspect / canvasAspect
        }

        return SIMD4<Float>(Float(-scaleX), Float(-scaleY), Float(scaleX * 2), Float(scaleY * 2))
    }

    private func pixelRectToNDC(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, canvasSize: CGSize) -> SIMD4<Float> {
        let ndcX = Float(x / canvasSize.width * 2.0 - 1.0)
        let ndcY = Float(1.0 - (y + h) / canvasSize.height * 2.0)
        let ndcW = Float(w / canvasSize.width * 2.0)
        let ndcH = Float(h / canvasSize.height * 2.0)
        return SIMD4<Float>(ndcX, ndcY, ndcW, ndcH)
    }

    // MARK: - Chat Overlay Rendering

    private func renderChatOverlayTexture(overlay: StreamOverlay, renderer: MetalRenderer) -> MTLTexture? {
        let messages = chatMessages
        let canvas = outputSize
        let w = Int(overlay.width * canvas.width)
        let h = Int(overlay.height * canvas.height)
        guard w > 0, h > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        let bgColor = overlay.backgroundColor.cgColor
        let cornerRadius: CGFloat = 10
        let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                          cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(bgColor)
        ctx.fillPath()

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx

        if messages.isEmpty {
            let placeholderAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: overlay.chatFontSize, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.3),
            ]
            let text = NSAttributedString(string: "Chat", attributes: placeholderAttrs)
            let size = text.size()
            text.draw(at: NSPoint(x: (CGFloat(w) - size.width) / 2, y: (CGFloat(h) - size.height) / 2))
            NSGraphicsContext.current = nil
            guard let cgImage = ctx.makeImage() else { return nil }
            return renderer.makeTexture(from: cgImage)
        }

        let recentMessages = Array(messages.suffix(overlay.chatMaxMessages))
        let padding: CGFloat = 10
        let lineSpacing: CGFloat = 4
        let authorFont = NSFont.systemFont(ofSize: overlay.chatFontSize, weight: .bold)
        let messageFont = NSFont.systemFont(ofSize: overlay.chatFontSize, weight: .regular)

        var yPos = padding

        for msg in recentMessages.reversed() {
            if yPos > CGFloat(h) - padding {
                break
            }

            let authorAttrs: [NSAttributedString.Key: Any] = [
                .font: authorFont,
                .foregroundColor: msg.isOwner
                    ? NSColor(red: 1, green: 0.85, blue: 0.3, alpha: 1)
                    : (msg.isModerator
                        ? NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1)
                        : overlay.chatAuthorColor.nsColor),
            ]

            let messageAttrs: [NSAttributedString.Key: Any] = [
                .font: messageFont,
                .foregroundColor: overlay.textColor.nsColor,
            ]

            let fullString = NSMutableAttributedString()

            if msg.type == .superChat, let amount = msg.superChatAmount {
                let amountAttrs: [NSAttributedString.Key: Any] = [
                    .font: authorFont,
                    .foregroundColor: NSColor(red: 1, green: 0.85, blue: 0.3, alpha: 1),
                ]
                fullString.append(NSAttributedString(string: "\(amount) ", attributes: amountAttrs))
            }

            fullString.append(NSAttributedString(string: msg.authorName, attributes: authorAttrs))
            fullString.append(NSAttributedString(string: "  \(msg.message)", attributes: messageAttrs))

            let maxWidth = CGFloat(w) - padding * 2
            let boundingRect = fullString.boundingRect(
                with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )

            let lineHeight = ceil(boundingRect.height)

            if yPos + lineHeight > CGFloat(h) - padding {
                break
            }

            fullString.draw(in: CGRect(x: padding, y: yPos, width: maxWidth, height: lineHeight))

            yPos += lineHeight + lineSpacing
        }

        NSGraphicsContext.current = nil

        guard let cgImage = ctx.makeImage() else { return nil }
        return renderer.makeTexture(from: cgImage)
    }

    // MARK: - Featured Chat Message

    private func makeFeaturedChatQuad(message: YouTubeChatMessage, renderer: MetalRenderer) -> RenderQuad? {
        let texture: MTLTexture

        featuredLock.lock()
        if let cached = cachedFeaturedTexture, cached.messageId == message.id {
            texture = cached.texture
            featuredLock.unlock()
        } else {
            featuredLock.unlock()
            guard let tex = renderFeaturedChatTexture(message: message, renderer: renderer) else { return nil }
            featuredLock.lock()
            cachedFeaturedTexture = (tex, message.id)
            featuredLock.unlock()
            texture = tex
        }

        let canvas = outputSize
        let texW = CGFloat(texture.width)
        let texH = CGFloat(texture.height)
        let w = min(texW, canvas.width * 0.6)
        let scale = w / texW
        let h = texH * scale
        let x = (canvas.width - w) / 2
        let y = canvas.height - h - canvas.height * 0.08

        let frame = pixelRectToNDC(x: x, y: y, w: w, h: h, canvasSize: canvas)

        return RenderQuad(
            texture: texture,
            frame: frame,
            texCrop: SIMD4<Float>(0, 0, 1, 1),
            cornerRadius: 12,
            opacity: 1.0,
            mirror: false,
            quadPixelSize: SIMD2<Float>(Float(w), Float(h))
        )
    }

    private func renderFeaturedChatTexture(message: YouTubeChatMessage, renderer: MetalRenderer) -> MTLTexture? {
        let maxWidth: CGFloat = outputSize.width * 0.55
        let padding: CGFloat = 20
        let nameFont = NSFont.systemFont(ofSize: 18, weight: .bold)
        let messageFont = NSFont.systemFont(ofSize: 22, weight: .regular)

        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: nameFont,
            .foregroundColor: NSColor(red: 0.4, green: 0.75, blue: 1.0, alpha: 1.0),
        ]
        let msgAttrs: [NSAttributedString.Key: Any] = [
            .font: messageFont,
            .foregroundColor: NSColor.white,
        ]

        let nameStr = NSAttributedString(string: message.authorName, attributes: nameAttrs)
        let msgStr = NSAttributedString(string: message.message, attributes: msgAttrs)

        let textWidth = maxWidth - padding * 2
        let nameRect = nameStr.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let msgRect = msgStr.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading])

        let nameH = ceil(nameRect.height)
        let msgH = ceil(msgRect.height)
        let gap: CGFloat = 6
        let totalH = padding + nameH + gap + msgH + padding
        let w = Int(ceil(maxWidth))
        let h = Int(ceil(totalH))

        guard w > 0, h > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        let bgColor = CGColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 0.9)
        ctx.setFillColor(bgColor)
        let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                            cornerWidth: 14, cornerHeight: 14, transform: nil)
        ctx.addPath(bgPath)
        ctx.fillPath()

        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 1.0))
        let barPath = CGPath(roundedRect: CGRect(x: 6, y: 8, width: 4, height: h - 16),
                             cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.addPath(barPath)
        ctx.fillPath()

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx

        let msgY = padding
        msgStr.draw(in: CGRect(x: padding, y: msgY, width: textWidth, height: msgH))

        let nameY = msgY + msgH + gap
        nameStr.draw(in: CGRect(x: padding, y: nameY, width: textWidth, height: nameH))

        NSGraphicsContext.current = nil

        guard let cgImage = ctx.makeImage() else { return nil }
        return renderer.makeTexture(from: cgImage)
    }

    func clearFeaturedChatCache() {
        featuredLock.lock()
        cachedFeaturedTexture = nil
        featuredLock.unlock()
    }

    // MARK: - Canvas Padding

    var currentPaddingScale: Float {
        paddingScale(config: canvasConfig, canvas: outputSize)
    }

    private func paddingScale(config: CanvasConfig, canvas: CGSize) -> Float {
        let padPixels = Float(config.padding)
        let cw = Float(canvas.width)
        let ch = Float(canvas.height)
        let scaleX = (cw - padPixels * 2.0) / cw
        let scaleY = (ch - padPixels * 2.0) / ch
        return max(0.05, min(scaleX, scaleY))
    }

    private func applyPaddingTransform(quads: inout [RenderQuad], from startIndex: Int, config: CanvasConfig, canvas: CGSize) {
        let scale = paddingScale(config: config, canvas: canvas)

        for i in startIndex..<quads.count {
            let q = quads[i]
            quads[i].frame = SIMD4<Float>(
                q.frame.x * scale,
                q.frame.y * scale,
                q.frame.z * scale,
                q.frame.w * scale
            )
            quads[i].quadPixelSize = SIMD2<Float>(
                q.quadPixelSize.x * scale,
                q.quadPixelSize.y * scale
            )
            if config.cornerRadius > 0 {
                quads[i].cornerRadius = max(quads[i].cornerRadius, Float(config.cornerRadius))
            }
        }
    }

    // MARK: - Canvas Background

    func clearBackgroundCache() {
        cachedBackgroundTexture = nil
        cachedBackgroundKey = nil
    }

    private func loadBackgroundTexture(renderer: MetalRenderer) -> MTLTexture? {
        let config = canvasConfig
        let key: String
        var imagePath: String?

        switch config.backgroundType {
        case .none:
            cachedBackgroundTexture = nil
            cachedBackgroundKey = nil
            return nil

        case .wallpaper:
            guard let name = config.wallpaperName else { return nil }
            key = "wallpaper:\(name)"
            if let preset = WallpaperPreset.all.first(where: { $0.id == name }) {
                imagePath = Bundle.main.path(forResource: preset.filename, ofType: nil, inDirectory: "Wallpapers")
            }

        case .customImage:
            guard let path = config.customImagePath, !path.isEmpty else { return nil }
            key = "custom:\(path)"
            imagePath = path

        case .solidColor:
            key = "solid:\(config.solidColor.r),\(config.solidColor.g),\(config.solidColor.b)"
            if key == cachedBackgroundKey, let tex = cachedBackgroundTexture { return tex }
            let tex = renderSolidColorTexture(color: config.solidColor, renderer: renderer)
            cachedBackgroundTexture = tex
            cachedBackgroundKey = key
            return tex

        case .gradient:
            let g = config.gradient
            key = "gradient:\(g.color1.r),\(g.color1.g),\(g.color1.b),\(g.color2.r),\(g.color2.g),\(g.color2.b),\(g.angle)"
            if key == cachedBackgroundKey, let tex = cachedBackgroundTexture { return tex }
            let tex = renderGradientTexture(gradient: g, renderer: renderer)
            cachedBackgroundTexture = tex
            cachedBackgroundKey = key
            return tex
        }

        if key == cachedBackgroundKey, let tex = cachedBackgroundTexture { return tex }

        guard let path = imagePath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        guard let tex = renderer.makeTexture(from: cgImage) else { return nil }
        cachedBackgroundTexture = tex
        cachedBackgroundKey = key
        return tex
    }

    private func renderSolidColorTexture(color: CodableColor, renderer: MetalRenderer) -> MTLTexture? {
        let w = 4, h = 4
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        texDesc.usage = [.shaderRead]
        guard let tex = renderer.device.makeTexture(descriptor: texDesc) else { return nil }

        let b = UInt8(min(max(color.b, 0), 1) * 255)
        let g = UInt8(min(max(color.g, 0), 1) * 255)
        let r = UInt8(min(max(color.r, 0), 1) * 255)
        let a: UInt8 = 255
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            pixels[i * 4 + 0] = b
            pixels[i * 4 + 1] = g
            pixels[i * 4 + 2] = r
            pixels[i * 4 + 3] = a
        }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * 4)
        return tex
    }

    private func renderGradientTexture(gradient: CanvasGradient, renderer: MetalRenderer) -> MTLTexture? {
        let w = 256, h = 256
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        texDesc.usage = [.shaderRead]
        guard let tex = renderer.device.makeTexture(descriptor: texDesc) else { return nil }

        let angleRad = CGFloat(gradient.angle) * .pi / 180.0
        let dx = cos(angleRad)
        let dy = sin(angleRad)

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let nx = CGFloat(x) / CGFloat(w - 1) - 0.5
                let ny = CGFloat(y) / CGFloat(h - 1) - 0.5
                var t = (nx * dx + ny * dy) + 0.5
                t = min(max(t, 0), 1)

                let r = gradient.color1.r + (gradient.color2.r - gradient.color1.r) * t
                let g = gradient.color1.g + (gradient.color2.g - gradient.color1.g) * t
                let b = gradient.color1.b + (gradient.color2.b - gradient.color1.b) * t

                let idx = (y * w + x) * 4
                pixels[idx + 0] = UInt8(min(max(b, 0), 1) * 255)
                pixels[idx + 1] = UInt8(min(max(g, 0), 1) * 255)
                pixels[idx + 2] = UInt8(min(max(r, 0), 1) * 255)
                pixels[idx + 3] = 255
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * 4)
        return tex
    }
}
