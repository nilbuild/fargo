import Metal
import MetalKit
import CoreMedia
import CoreVideo
import simd

struct RenderQuad {
    var texture: MTLTexture
    var frame: SIMD4<Float>
    var texCrop: SIMD4<Float>
    var cornerRadius: Float
    var opacity: Float
    var mirror: Bool
    var quadPixelSize: SIMD2<Float>
}

struct GPUQuadUniforms {
    var frame: SIMD4<Float>
    var texCrop: SIMD4<Float>
    var cornerRadius: Float
    var opacity: Float
    var mirror: Float
    var _pad: Float
    var quadPixelSize: SIMD2<Float>
}

struct GPUBlitUniforms {
    var scale: SIMD2<Float>
}

private struct GPUBlurParams {
    var radius: Int32
    var sigma: Float
}

struct GPUBorderUniforms {
    var frame: SIMD4<Float>
    var quadPixelSize: SIMD2<Float>
    var borderWidth: Float
    var cornerRadius: Float
}

struct GPUColorCorrectionParams {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var gamma: Float
    var temperature: Float
}

private final class PooledPixelBuffer {
    let pixelBuffer: CVPixelBuffer
    let cvTexture: CVMetalTexture
    let texture: MTLTexture
    var inFlight: Bool = false

    init?(width: Int, height: Int, cache: CVMetalTextureCache) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pb: CVPixelBuffer?
        let pbStatus = CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb
        )
        guard pbStatus == kCVReturnSuccess, let pb else {
            return nil
        }

        var cvTex: CVMetalTexture?
        let texStatus = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pb, nil,
            .bgra8Unorm, width, height, 0, &cvTex
        )
        guard texStatus == kCVReturnSuccess,
              let cvTex,
              let mt = CVMetalTextureGetTexture(cvTex) else {
            return nil
        }

        self.pixelBuffer = pb
        self.cvTexture = cvTex
        self.texture = mt
    }
}

final class MetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let encodeQueue: MTLCommandQueue
    private let compositePipeline: MTLRenderPipelineState
    private let blitPipeline: MTLRenderPipelineState
    private let borderPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    private let downsamplePipeline: MTLComputePipelineState
    private let blurHPipeline: MTLComputePipelineState
    private let blurVPipeline: MTLComputePipelineState
    private let blurCompositePipeline: MTLComputePipelineState
    private let backgroundRemovePipeline: MTLComputePipelineState
    private let colorCorrectionPipeline: MTLComputePipelineState
    private let skinSmoothingPipeline: MTLComputePipelineState

    private var texturePool: [String: [MTLTexture]] = [:]
    private var borrowedTextures: [MTLTexture] = []

    private var blurHalfTexture: MTLTexture?
    private var blurTempTexture: MTLTexture?
    private var blurResultTexture: MTLTexture?
    private var blurOutputTexture: MTLTexture?

    private var screenBlurChain: [MTLTexture] = []
    private var screenBlurTempTexture: MTLTexture?
    private var screenBlurResultTexture: MTLTexture?

    let outputWidth = 3840
    let outputHeight = 2160

    let streamingWidth = 1920
    let streamingHeight = 1080

    // One offscreen 4K target per in-flight frame, so the composite of frame N+1 can
    // run while the readback of frame N still reads the previous target.
    private let offscreenPoolSize = 3
    private var offscreenTextures: [MTLTexture] = []
    private var offscreenPoolIndex: UInt64 = 0
    private var offscreenPassDescriptor = MTLRenderPassDescriptor()

    // Bounds frames in flight to offscreenPoolSize so the render thread waits instead
    // of racing over offTex and pool buffers.
    private let inFlightSemaphore: DispatchSemaphore

    // Cross-queue sync: commandQueue signals after the composite pass writes offTex,
    // encodeQueue waits before reading it.
    private let hazardEvent: MTLEvent
    private var hazardValue: UInt64 = 0

    // The newest composited frame, for the preview to show.
    private let latestFrameLock = NSLock()
    private var _latestFrame: MTLTexture?

    // Each entry caches its MTLTexture wrapper so the render thread never calls
    // CVMetalTextureCacheCreateTextureFromImage.
    private let poolLock = NSLock()
    private var recordingPool: [PooledPixelBuffer] = []
    private var streamingPool: [PooledPixelBuffer] = []

    private var streamingPassDescriptor = MTLRenderPassDescriptor()
    private var streamingTexture: MTLTexture?

    var onFrame: ((MTLCommandBuffer) -> [RenderQuad])?
    // Called with the frame's scheduled time. Stamping at GPU completion instead jitters
    // by a few ms, which shows as uneven motion and uneven 30fps frame picks.
    var onOutput: ((CVPixelBuffer, CMTime) -> Void)?
    // The 4K copy is only needed for recording or a destination above 1080p. Skipping it
    // otherwise saves a full 4K blit per frame.
    var wantsFullResOutput: (() -> Bool)?
    var onStreamingOutput: ((CVPixelBuffer, CMTime) -> Void)?
    // Preview only: runs on main before each preview draw.
    var onBeforeDraw: (() -> Void)?

    var selectionBorderFrame: SIMD4<Float>?
    var selectionBorderPixelSize: SIMD2<Float> = .zero
    var selectionBorderRadius: Float = 8

    var splitDividerNDCX: Float?
    var splitDividerVisible: Bool = false


    override init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let encodeQueue = device.makeCommandQueue(),
              let hazardEvent = device.makeEvent(),
              let library = device.makeDefaultLibrary() else {
            fatalError("Metal initialization failed")
        }

        self.device = device
        self.commandQueue = commandQueue
        self.encodeQueue = encodeQueue
        self.hazardEvent = hazardEvent
        self.inFlightSemaphore = DispatchSemaphore(value: offscreenPoolSize)

        let compDesc = MTLRenderPipelineDescriptor()
        compDesc.vertexFunction = library.makeFunction(name: "compositeVertex")
        compDesc.fragmentFunction = library.makeFunction(name: "compositeFragment")
        compDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        compDesc.colorAttachments[0].isBlendingEnabled = true
        compDesc.colorAttachments[0].rgbBlendOperation = .add
        compDesc.colorAttachments[0].alphaBlendOperation = .add
        compDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        compDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        compDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        compDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.compositePipeline = try! device.makeRenderPipelineState(descriptor: compDesc)

        let blitDesc = MTLRenderPipelineDescriptor()
        blitDesc.vertexFunction = library.makeFunction(name: "blitVertex")
        blitDesc.fragmentFunction = library.makeFunction(name: "blitFragment")
        blitDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.blitPipeline = try! device.makeRenderPipelineState(descriptor: blitDesc)

        let borderDesc = MTLRenderPipelineDescriptor()
        borderDesc.vertexFunction = library.makeFunction(name: "borderVertex")
        borderDesc.fragmentFunction = library.makeFunction(name: "borderFragment")
        borderDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        borderDesc.colorAttachments[0].isBlendingEnabled = true
        borderDesc.colorAttachments[0].rgbBlendOperation = .add
        borderDesc.colorAttachments[0].alphaBlendOperation = .add
        borderDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        borderDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        borderDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        borderDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.borderPipeline = try! device.makeRenderPipelineState(descriptor: borderDesc)

        self.downsamplePipeline = try! device.makeComputePipelineState(
            function: library.makeFunction(name: "downsample")!)
        self.blurHPipeline = try! device.makeComputePipelineState(
            function: library.makeFunction(name: "gaussianBlurH")!)
        self.blurVPipeline = try! device.makeComputePipelineState(
            function: library.makeFunction(name: "gaussianBlurV")!)
        self.blurCompositePipeline = try! device.makeComputePipelineState(
            function: library.makeFunction(name: "blurComposite")!)
        self.backgroundRemovePipeline = try! device.makeComputePipelineState(
            function: library.makeFunction(name: "backgroundRemove")!)
        self.colorCorrectionPipeline = try! device.makeComputePipelineState(
            function: library.makeFunction(name: "colorCorrection")!)
        self.skinSmoothingPipeline = try! device.makeComputePipelineState(
            function: library.makeFunction(name: "skinSmoothing")!)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.textureCache = cache

        super.init()

        setupOffscreen()
        setupOutputBuffers()
        startRenderLoop()
    }

    // MARK: - Render loop

    // The stream is rendered here at a fixed 60 Hz, independent of the preview. Driven by
    // MTKView it ran on main, so any UI hitch dropped stream frames, and macOS stops a
    // hidden or fully covered window's display link, which froze the stream.
    private func startRenderLoop() {
        let thread = Thread { [weak self] in
            self?.runRenderLoop()
        }
        thread.name = "com.streamif.render"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func runRenderLoop() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let interval = 1_000_000_000 / 60 * UInt64(timebase.denom) / UInt64(timebase.numer)

        var next = mach_absolute_time()
        while true {
            autoreleasepool {
                // Stamped with the scheduled tick, so timestamps sit on an exact 60 Hz grid.
                renderFrame(frameTime: CMClockMakeHostTimeFromSystemUnits(next))
            }
            next += interval
            let now = mach_absolute_time()
            if now > next + interval {
                // Fell more than a frame behind. Skip ahead rather than burst to catch up.
                next = now
            }
            mach_wait_until(next)
        }
    }

    private func setLatestFrame(_ texture: MTLTexture) {
        latestFrameLock.lock()
        _latestFrame = texture
        latestFrameLock.unlock()
    }

    private func latestFrame() -> MTLTexture? {
        latestFrameLock.lock()
        defer { latestFrameLock.unlock() }
        return _latestFrame
    }

    // MARK: - Configuration

    func configure(view: MTKView) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
    }

    // MARK: - Zero-copy texture from CVPixelBuffer

    func makeTexture(from pixelBuffer: CVPixelBuffer, pixelFormat: MTLPixelFormat = .bgra8Unorm) -> MTLTexture? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil,
            pixelFormat, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTex = cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }

    func makeTexture(from cgImage: CGImage) -> MTLTexture? {
        let width = cgImage.width
        let height = cgImage.height

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        texDesc.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: texDesc) else { return nil }

        let bytesPerRow = 4 * width
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = ctx.data else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        return texture
    }

    // MARK: - GPU Gaussian Blur (half-resolution for performance)

    func blurComposite(
        camera: MTLTexture,
        mask: MTLTexture,
        radius: Float,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        let fullW = camera.width
        let fullH = camera.height
        let halfW = fullW / 2
        let halfH = fullH / 2

        if blurHalfTexture == nil || blurHalfTexture!.width != halfW {
            let halfDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: halfW, height: halfH, mipmapped: false
            )
            halfDesc.usage = [.shaderRead, .shaderWrite]
            halfDesc.storageMode = .private
            blurHalfTexture = device.makeTexture(descriptor: halfDesc)
            blurTempTexture = device.makeTexture(descriptor: halfDesc)
            blurResultTexture = device.makeTexture(descriptor: halfDesc)

            let fullDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: fullW, height: fullH, mipmapped: false
            )
            fullDesc.usage = [.shaderRead, .shaderWrite]
            fullDesc.storageMode = .private
            blurOutputTexture = device.makeTexture(descriptor: fullDesc)
        }

        guard let half = blurHalfTexture,
              let temp = blurTempTexture,
              let blurred = blurResultTexture,
              let output = blurOutputTexture else { return nil }

        let halfRadius = min(Int32(radius / 2.0), 15)
        let sigma = Float(radius) / 3.0 / 2.0
        var params = GPUBlurParams(radius: halfRadius, sigma: sigma)

        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let halfGrid = MTLSize(width: halfW, height: halfH, depth: 1)
        let fullGrid = MTLSize(width: fullW, height: fullH, depth: 1)

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(downsamplePipeline)
            enc.setTexture(camera, index: 0)
            enc.setTexture(half, index: 1)
            enc.dispatchThreads(halfGrid, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(blurHPipeline)
            enc.setTexture(half, index: 0)
            enc.setTexture(temp, index: 1)
            enc.setBytes(&params, length: MemoryLayout<GPUBlurParams>.stride, index: 0)
            enc.dispatchThreads(halfGrid, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(blurVPipeline)
            enc.setTexture(temp, index: 0)
            enc.setTexture(blurred, index: 1)
            enc.setBytes(&params, length: MemoryLayout<GPUBlurParams>.stride, index: 0)
            enc.dispatchThreads(halfGrid, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(blurCompositePipeline)
            enc.setTexture(camera, index: 0)
            enc.setTexture(blurred, index: 1)
            enc.setTexture(mask, index: 2)
            enc.setTexture(output, index: 3)
            enc.dispatchThreads(fullGrid, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        return output
    }

    func removeBackground(
        camera: MTLTexture,
        mask: MTLTexture,
        color: SIMD4<Float>,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        let w = camera.width
        let h = camera.height

        if blurOutputTexture == nil || blurOutputTexture!.width != w || blurOutputTexture!.height != h {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
            )
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            blurOutputTexture = device.makeTexture(descriptor: desc)
        }

        guard let output = blurOutputTexture else { return nil }

        var bgColor = color
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: w, height: h, depth: 1)

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(backgroundRemovePipeline)
            enc.setTexture(camera, index: 0)
            enc.setTexture(mask, index: 1)
            enc.setTexture(output, index: 2)
            enc.setBytes(&bgColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        return output
    }

    private var colorCorrectionTexture: MTLTexture?

    func applyColorCorrection(
        texture: MTLTexture,
        brightness: Float,
        contrast: Float,
        saturation: Float,
        gamma: Float,
        temperature: Float,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        let w = texture.width
        let h = texture.height

        if colorCorrectionTexture == nil || colorCorrectionTexture!.width != w || colorCorrectionTexture!.height != h {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
            )
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            colorCorrectionTexture = device.makeTexture(descriptor: desc)
        }

        guard let output = colorCorrectionTexture else { return nil }

        var params = GPUColorCorrectionParams(
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            gamma: gamma,
            temperature: temperature
        )

        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: w, height: h, depth: 1)

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(colorCorrectionPipeline)
            enc.setTexture(texture, index: 0)
            enc.setTexture(output, index: 1)
            enc.setBytes(&params, length: MemoryLayout<GPUColorCorrectionParams>.stride, index: 0)
            enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        return output
    }

    // MARK: - Texture Pool

    func borrowTexture(width: Int, height: Int, format: MTLPixelFormat = .bgra8Unorm) -> MTLTexture? {
        let key = "\(width)x\(height)x\(format.rawValue)"
        if var available = texturePool[key], !available.isEmpty {
            let tex = available.removeLast()
            texturePool[key] = available
            borrowedTextures.append(tex)
            return tex
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        borrowedTextures.append(tex)
        return tex
    }

    func returnBorrowedTextures() {
        for tex in borrowedTextures {
            let key = "\(tex.width)x\(tex.height)x\(tex.pixelFormat.rawValue)"
            texturePool[key, default: []].append(tex)
        }
        borrowedTextures.removeAll()
    }

    // MARK: - Skin Smoothing

    func applySkinSmoothing(
        texture: MTLTexture,
        mask: MTLTexture,
        intensity: Float,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        let w = texture.width
        let h = texture.height

        guard let output = borrowTexture(width: w, height: h) else { return nil }

        var intensityVal = intensity
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: w, height: h, depth: 1)

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(skinSmoothingPipeline)
            enc.setTexture(texture, index: 0)
            enc.setTexture(mask, index: 1)
            enc.setTexture(output, index: 2)
            enc.setBytes(&intensityVal, length: MemoryLayout<Float>.stride, index: 0)
            enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        return output
    }

    // Privacy blur. At this strength no detail survives, so it runs on a 1/8 scale copy
    // (three 2x box downsamples) and linear sampling scales it back up. Blurring at half
    // scale cost ~160 taps per pixel over a 1080p texture, twice, every frame.
    func blurTexture(
        _ texture: MTLTexture,
        radius: Float,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        let levels = 3
        let scale = Float(1 << levels)
        let smallW = max(1, texture.width >> levels)
        let smallH = max(1, texture.height >> levels)

        if screenBlurChain.first?.width != texture.width / 2 || screenBlurResultTexture?.width != smallW || screenBlurResultTexture?.height != smallH {
            screenBlurChain = (1...levels).compactMap { level in
                makeBlurTexture(width: max(1, texture.width >> level), height: max(1, texture.height >> level))
            }
            screenBlurTempTexture = makeBlurTexture(width: smallW, height: smallH)
            screenBlurResultTexture = makeBlurTexture(width: smallW, height: smallH)
        }

        guard screenBlurChain.count == levels,
              let small = screenBlurChain.last,
              let temp = screenBlurTempTexture,
              let blurred = screenBlurResultTexture else { return nil }

        let tg = MTLSize(width: 16, height: 16, depth: 1)

        var source = texture
        for target in screenBlurChain {
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.setComputePipelineState(downsamplePipeline)
                enc.setTexture(source, index: 0)
                enc.setTexture(target, index: 1)
                enc.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1), threadsPerThreadgroup: tg)
                enc.endEncoding()
            }
            source = target
        }

        let sigma = radius / 3.0 / scale
        var params = GPUBlurParams(radius: min(Int32((sigma * 3).rounded(.up)), 80), sigma: sigma)
        let smallGrid = MTLSize(width: smallW, height: smallH, depth: 1)

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(blurHPipeline)
            enc.setTexture(small, index: 0)
            enc.setTexture(temp, index: 1)
            enc.setBytes(&params, length: MemoryLayout<GPUBlurParams>.stride, index: 0)
            enc.dispatchThreads(smallGrid, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(blurVPipeline)
            enc.setTexture(temp, index: 0)
            enc.setTexture(blurred, index: 1)
            enc.setBytes(&params, length: MemoryLayout<GPUBlurParams>.stride, index: 0)
            enc.dispatchThreads(smallGrid, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        return blurred
    }

    private func makeBlurTexture(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }

    // MARK: - Offscreen render target

    private func setupOffscreen() {
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outputWidth,
            height: outputHeight,
            mipmapped: false
        )
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .private
        for _ in 0..<offscreenPoolSize {
            if let tex = device.makeTexture(descriptor: texDesc) {
                offscreenTextures.append(tex)
            }
        }

        offscreenPassDescriptor.colorAttachments[0].loadAction = .clear
        offscreenPassDescriptor.colorAttachments[0].storeAction = .store
        offscreenPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    private func setupOutputBuffers() {
        guard let cache = textureCache else {
            return
        }

        // Pool size must be >= offscreenPoolSize so the render path never
        // blocks on an empty pool while it still holds an offTex slot.
        let poolCount = 4

        for _ in 0..<poolCount {
            if let buf = PooledPixelBuffer(width: outputWidth, height: outputHeight, cache: cache) {
                recordingPool.append(buf)
            }
        }

        for _ in 0..<poolCount {
            if let buf = PooledPixelBuffer(width: streamingWidth, height: streamingHeight, cache: cache) {
                streamingPool.append(buf)
            }
        }

        let streamTexDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: streamingWidth,
            height: streamingHeight,
            mipmapped: false
        )
        streamTexDesc.usage = [.renderTarget, .shaderRead]
        streamTexDesc.storageMode = .private
        streamingTexture = device.makeTexture(descriptor: streamTexDesc)

        streamingPassDescriptor.colorAttachments[0].loadAction = .clear
        streamingPassDescriptor.colorAttachments[0].storeAction = .store
        streamingPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    private func acquirePooledBuffer(from pool: [PooledPixelBuffer]) -> PooledPixelBuffer? {
        poolLock.lock()
        defer {
            poolLock.unlock()
        }
        for buf in pool {
            if !buf.inFlight {
                buf.inFlight = true
                return buf
            }
        }
        return nil
    }

    private func releasePooledBuffer(_ buf: PooledPixelBuffer) {
        poolLock.lock()
        buf.inFlight = false
        poolLock.unlock()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        onBeforeDraw?()

        guard let offTex = latestFrame(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        if let drawable = view.currentDrawable,
           let blitDesc = view.currentRenderPassDescriptor {
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: blitDesc) {
                encoder.setRenderPipelineState(blitPipeline)

                let drawableSize = view.drawableSize
                let outputAspect = CGFloat(outputWidth) / CGFloat(outputHeight)
                let viewAspect = drawableSize.width / max(drawableSize.height, 1)

                var scaleX: Float = 1.0
                var scaleY: Float = 1.0
                if outputAspect > viewAspect {
                    scaleY = Float(viewAspect / outputAspect)
                } else {
                    scaleX = Float(outputAspect / viewAspect)
                }

                var blitUniforms = GPUBlitUniforms(scale: SIMD2<Float>(scaleX, scaleY))
                encoder.setVertexBytes(&blitUniforms, length: MemoryLayout<GPUBlitUniforms>.stride, index: 0)
                encoder.setFragmentTexture(offTex, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

                if let borderFrame = selectionBorderFrame {
                    encoder.setRenderPipelineState(borderPipeline)
                    let scaledFrame = SIMD4<Float>(
                        borderFrame.x * scaleX,
                        borderFrame.y * scaleY,
                        borderFrame.z * scaleX,
                        borderFrame.w * scaleY
                    )
                    let scaledPixelSize = SIMD2<Float>(
                        selectionBorderPixelSize.x * scaleX,
                        selectionBorderPixelSize.y * scaleY
                    )
                    var borderUniforms = GPUBorderUniforms(
                        frame: scaledFrame,
                        quadPixelSize: scaledPixelSize,
                        borderWidth: 2.0,
                        cornerRadius: selectionBorderRadius
                    )
                    encoder.setVertexBytes(&borderUniforms, length: MemoryLayout<GPUBorderUniforms>.stride, index: 0)
                    encoder.setFragmentBytes(&borderUniforms, length: MemoryLayout<GPUBorderUniforms>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }

                if splitDividerVisible, let ndcX = splitDividerNDCX {
                    encoder.setRenderPipelineState(borderPipeline)

                    let lineW: Float = 2.0 / Float(drawableSize.width)
                    let lineFrame = SIMD4<Float>(
                        ndcX * scaleX - lineW / 2,
                        -scaleY,
                        lineW,
                        scaleY * 2
                    )
                    let linePixelW: Float = 2.0
                    let linePixelH = Float(drawableSize.height) * scaleY
                    var lineUniforms = GPUBorderUniforms(
                        frame: lineFrame,
                        quadPixelSize: SIMD2<Float>(linePixelW, linePixelH),
                        borderWidth: linePixelW,
                        cornerRadius: 0
                    )
                    encoder.setVertexBytes(&lineUniforms, length: MemoryLayout<GPUBorderUniforms>.stride, index: 0)
                    encoder.setFragmentBytes(&lineUniforms, length: MemoryLayout<GPUBorderUniforms>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

                    let handleW: Float = 6.0 / Float(drawableSize.width)
                    let handleH: Float = 40.0 / Float(drawableSize.height)
                    let handleFrame = SIMD4<Float>(
                        ndcX * scaleX - handleW / 2,
                        -handleH / 2,
                        handleW,
                        handleH
                    )
                    let handlePixelW: Float = 6.0
                    let handlePixelH: Float = 40.0
                    var handleUniforms = GPUBorderUniforms(
                        frame: handleFrame,
                        quadPixelSize: SIMD2<Float>(handlePixelW, handlePixelH),
                        borderWidth: handlePixelW,
                        cornerRadius: 3
                    )
                    encoder.setVertexBytes(&handleUniforms, length: MemoryLayout<GPUBorderUniforms>.stride, index: 0)
                    encoder.setFragmentBytes(&handleUniforms, length: MemoryLayout<GPUBorderUniforms>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }

                encoder.endEncoding()
            }
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    // Composites one frame and hands it to the recorder and encoders. Runs on the render
    // thread, never on main, so UI work can't drop frames from the stream.
    private func renderFrame(frameTime: CMTime) {
        // Block until a slot frees up. Same pattern as Apple's Metal triple-buffering samples.
        inFlightSemaphore.wait()

        guard !offscreenTextures.isEmpty else {
            inFlightSemaphore.signal()
            return
        }
        let offTex = offscreenTextures[Int(offscreenPoolIndex % UInt64(offscreenTextures.count))]
        offscreenPoolIndex &+= 1

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }
        guard let quads = onFrame?(commandBuffer) else {
            inFlightSemaphore.signal()
            return
        }

        offscreenPassDescriptor.colorAttachments[0].texture = offTex

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: offscreenPassDescriptor) {
            if !quads.isEmpty {
                encoder.setRenderPipelineState(compositePipeline)
                encodeQuads(quads, encoder: encoder)
            }
            encoder.endEncoding()
        }


        // Signal once the composite has committed. encodeQueue waits on this value before
        // reading offTex.
        hazardValue &+= 1
        let frameHazardValue = hazardValue
        commandBuffer.encodeSignalEvent(hazardEvent, value: frameHazardValue)

        // Release the offTex slot when the last of the three command buffers finishes.
        let frameGroup = DispatchGroup()
        frameGroup.enter()
        commandBuffer.addCompletedHandler { _ in
            frameGroup.leave()
        }
        commandBuffer.commit()
        setLatestFrame(offTex)

        let onOutput = (wantsFullResOutput?() ?? true) ? self.onOutput : nil
        if let onOutput, let recBuf = acquirePooledBuffer(from: recordingPool) {
            if let cb2 = encodeQueue.makeCommandBuffer() {
                cb2.encodeWaitForEvent(hazardEvent, value: frameHazardValue)
                if let blit = cb2.makeBlitCommandEncoder() {
                    blit.copy(
                        from: offTex, sourceSlice: 0, sourceLevel: 0,
                        sourceOrigin: MTLOrigin(),
                        sourceSize: MTLSize(width: outputWidth, height: outputHeight, depth: 1),
                        to: recBuf.texture, destinationSlice: 0, destinationLevel: 0,
                        destinationOrigin: MTLOrigin()
                    )
                    blit.endEncoding()
                }
                frameGroup.enter()
                cb2.addCompletedHandler { [weak self] _ in
                    onOutput(recBuf.pixelBuffer, frameTime)
                    self?.releasePooledBuffer(recBuf)
                    frameGroup.leave()
                }
                cb2.commit()
            } else {
                releasePooledBuffer(recBuf)
            }
        }

        let onStreamingOutput = self.onStreamingOutput
        if let onStreamingOutput,
           let streamBuf = acquirePooledBuffer(from: streamingPool),
           let streamTex = streamingTexture {
            if let cb3 = encodeQueue.makeCommandBuffer() {
                cb3.encodeWaitForEvent(hazardEvent, value: frameHazardValue)

                streamingPassDescriptor.colorAttachments[0].texture = streamTex
                if let encoder = cb3.makeRenderCommandEncoder(descriptor: streamingPassDescriptor) {
                    encoder.setRenderPipelineState(blitPipeline)
                    var blitUniforms = GPUBlitUniforms(scale: SIMD2<Float>(1.0, 1.0))
                    encoder.setVertexBytes(&blitUniforms, length: MemoryLayout<GPUBlitUniforms>.stride, index: 0)
                    encoder.setFragmentTexture(offTex, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    encoder.endEncoding()
                }

                if let blit = cb3.makeBlitCommandEncoder() {
                    blit.copy(
                        from: streamTex, sourceSlice: 0, sourceLevel: 0,
                        sourceOrigin: MTLOrigin(),
                        sourceSize: MTLSize(width: streamingWidth, height: streamingHeight, depth: 1),
                        to: streamBuf.texture, destinationSlice: 0, destinationLevel: 0,
                        destinationOrigin: MTLOrigin()
                    )
                    blit.endEncoding()
                }

                frameGroup.enter()
                cb3.addCompletedHandler { [weak self] _ in
                    onStreamingOutput(streamBuf.pixelBuffer, frameTime)
                    self?.releasePooledBuffer(streamBuf)
                    frameGroup.leave()
                }
                cb3.commit()
            } else {
                releasePooledBuffer(streamBuf)
            }
        }

        frameGroup.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            self?.inFlightSemaphore.signal()
        }
    }

    // MARK: - Helpers

    private func encodeQuads(_ quads: [RenderQuad], encoder: MTLRenderCommandEncoder) {
        for quad in quads {
            var uniforms = GPUQuadUniforms(
                frame: quad.frame,
                texCrop: quad.texCrop,
                cornerRadius: quad.cornerRadius,
                opacity: quad.opacity,
                mirror: quad.mirror ? 1.0 : 0.0,
                _pad: 0,
                quadPixelSize: quad.quadPixelSize
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUQuadUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GPUQuadUniforms>.stride, index: 0)
            encoder.setFragmentTexture(quad.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    func flushTextureCache() {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
}
