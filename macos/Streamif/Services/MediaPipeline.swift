import AVFoundation
import ScreenCaptureKit
import Network
import MetalKit

@MainActor @Observable
final class MediaPipeline {
    // MARK: - Observable State (MainActor)

    var requestedSidebarTab: String?
    var streamStatus: StreamStatus = .idle
    var audioLevel: Float = 0
    var isMuted = false
    var noiseSuppression = false {
        didSet { applyNoiseSuppression() }
    }
    var micVolume: Float = 1.0 {
        didSet { audioMixer.micVolume = micVolume }
    }
    var systemVolume: Float = 1.0 {
        didSet { audioMixer.systemVolume = systemVolume }
    }

    var compressorEnabled = false {
        didSet { audioMixer.compressorEnabled = compressorEnabled }
    }
    var compressorThreshold: Float = -20.0 {
        didSet { audioMixer.compressorThreshold = compressorThreshold }
    }
    var compressorRatio: Float = 4.0 {
        didSet { audioMixer.compressorRatio = compressorRatio }
    }
    var compressorMakeupGain: Float = 0.0 {
        didSet { audioMixer.compressorMakeupGain = compressorMakeupGain }
    }
    var eqEnabled = false {
        didSet { audioMixer.eqEnabled = eqEnabled }
    }
    var eqLowGain: Float = 0.0 {
        didSet { audioMixer.eqLowGain = eqLowGain }
    }
    var eqMidGain: Float = 0.0 {
        didSet { audioMixer.eqMidGain = eqMidGain }
    }
    var eqHighGain: Float = 0.0 {
        didSet { audioMixer.eqHighGain = eqHighGain }
    }

    var isScreenCapturing = false
    private(set) var isRecording = false
    var cameraError: String?
    var micError: String?
    var isCameraLoading = false

    var cameras: [CameraDevice] = []
    var microphones: [AudioDevice] = []
    var displays: [SCDisplay] = []
    var windows: [SCWindow] = []

    var selectedCameraId = ""
    var selectedMicId = ""
    var selectedDisplayId: CGDirectDisplayID?
    var selectedWindowId: CGWindowID?

    enum ScreenSource: Equatable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
    }
    var selectedScreenSource: ScreenSource?

    var canvasConfig = CanvasConfig() {
        didSet {
            metalCompositor.canvasConfig = canvasConfig
            Persistence.saveCanvasConfig(canvasConfig)
        }
    }

    // MARK: - Metal Pipeline

    let renderer = MetalRenderer()
    let metalCompositor = MetalCompositor()

    // MARK: - Streaming (native RTMP, no HaishinKit)

    let streamManager = StreamManager()
    private var latestFullResBuffer: CVPixelBuffer?

    var overlays: [StreamOverlay] = []
    var isScreenBlurred = false
    nonisolated(unsafe) var renderScreenBlurred = false

    var backgroundMode: BackgroundMode = .none {
        didSet { metalCompositor.backgroundBlur.setMode(backgroundMode) }
    }
    var backgroundBlurEnabled: Bool {
        get { backgroundMode == .blur }
        set { backgroundMode = newValue ? .blur : .none }
    }
    var backgroundBlurRadius: CGFloat = 20 {
        didSet { metalCompositor.backgroundBlur.blurRadius = backgroundBlurRadius }
    }
    var backgroundRemovalColor: SIMD4<Float> {
        get { metalCompositor.backgroundBlur.removalColor }
        set { metalCompositor.backgroundBlur.removalColor = newValue }
    }

    var colorCorrectionEnabled = false {
        didSet { metalCompositor.colorCorrectionEnabled = colorCorrectionEnabled }
    }
    var colorBrightness: Float = 0.0 {
        didSet { metalCompositor.colorBrightness = colorBrightness }
    }
    var colorContrast: Float = 1.0 {
        didSet { metalCompositor.colorContrast = colorContrast }
    }
    var colorSaturation: Float = 1.0 {
        didSet { metalCompositor.colorSaturation = colorSaturation }
    }
    var colorGamma: Float = 1.0 {
        didSet { metalCompositor.colorGamma = colorGamma }
    }
    var colorTemperature: Float = 0.0 {
        didSet { metalCompositor.colorTemperature = colorTemperature }
    }

    var colorFilterPreset: ColorFilterPreset = .none {
        didSet {
            if let params = colorFilterPreset.colorParams {
                metalCompositor.colorCorrectionEnabled = true
                metalCompositor.colorBrightness = params.brightness
                metalCompositor.colorContrast = params.contrast
                metalCompositor.colorSaturation = params.saturation
                metalCompositor.colorGamma = params.gamma
                metalCompositor.colorTemperature = params.temperature
            } else if !colorCorrectionEnabled {
                metalCompositor.colorCorrectionEnabled = false
            }
        }
    }

    var skinSmoothingEnabled = false {
        didSet { metalCompositor.backgroundBlur.skinSmoothingEnabled = skinSmoothingEnabled }
    }
    var skinSmoothingIntensity: Float = 0.5 {
        didSet { metalCompositor.skinSmoothingIntensity = skinSmoothingIntensity }
    }

    let mediaPlayer = MediaPlayer()
    var mediaPlayerState: MediaPlayer.State = .empty
    var mediaUrl: URL?

    var savedMediaPresets: [MediaPreset] = []
    var activeMediaPresetId: UUID?

    var canvasSources: [CanvasSource] = []
    var selectedCanvasSourceId: UUID?
    var isCanvasDragging = false
    var isOverlayDragging = false

    var canvases: [Canvas] = []
    var activeCanvasId: UUID?
    private var persistDebounceTask: Task<Void, Never>?

    private var reconcileTask: Task<Void, Never>?

    private var hasWarmedScreenCapture = false

    let soundBoard = SoundBoard()

    let captionService = CaptionService()

    let audioBus = AudioBus()
    private var audioBusSubscriptions: [AudioBusSubscription] = []

    let youtubeAuth = YouTubeAuth()
    private(set) var youtubeAPI: YouTubeAPI?
    let youtubeChatService = YouTubeChatService()
    var youtubeBroadcast: YouTubeBroadcast?
    var youtubeStream: YouTubeStream?
    var featuredChatMessage: YouTubeChatMessage?

    let twitchAuth = TwitchAuth()
    let twitchChatService = TwitchChatService()

    var allChatMessages: [YouTubeChatMessage] {
        let yt = youtubeChatService.messages
        let tw = twitchChatService.messages
        return (yt + tw).sorted { $0.publishedAt < $1.publishedAt }
    }

    private let recorder = LocalRecorder()

    private let audioMixer = AudioMixer()
    private var systemAudioStream: SCStream?
    private var systemAudioOutput: ScreenFrameOutput?
    var systemAudioEnabled = true {
        didSet {
            if systemAudioEnabled != oldValue {
                Task {
                    await stopSystemAudioCapture()
                    await startSystemAudioCapture()
                }
            }
        }
    }

    private let captureSession = AVCaptureSession()
    private var cameraInput: AVCaptureDeviceInput?
    private var micInput: AVCaptureDeviceInput?
    private var frameDelegate: CaptureDelegate?
    private let captureQueue = DispatchQueue(label: "com.streamif.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.streamif.audio", qos: .userInteractive)

    private var extraCameraSessions: [String: AVCaptureSession] = [:]
    private var extraCameraDelegates: [String: CanvasCameraCaptureDelegate] = [:]
    private var extraCameraWatchdogTasks: [String: Task<Void, Never>] = [:]

    private let sessionQueue = DispatchQueue(label: "com.streamif.cameraSession", qos: .userInitiated)

    private nonisolated(unsafe) var lastMainCameraFrameTime: CFAbsoluteTime = 0
    private var cameraWatchdogTask: Task<Void, Never>?

    private nonisolated(unsafe) var lastMainMicFrameTime: CFAbsoluteTime = 0
    private var micWatchdogTask: Task<Void, Never>?

    private var extraScreenStreams: [String: SCStream] = [:]
    private var extraScreenOutputs: [String: ScreenFrameOutput] = [:]

    // False on every screen-capture start, true once a frame actually arrives.
    // Canvas switches wait on this so the new source has real pixels.
    private var screenFrameAvailable = false

    private var screenStream: SCStream?
    private var screenOutput: ScreenFrameOutput?

    private var audioSmoothed: Float = 0
    private var lastAudioUIUpdate: CFAbsoluteTime = 0
    private let audioUIUpdateInterval: CFAbsoluteTime = 0.05

    private nonisolated(unsafe) var frameCount: Int = 0

    // MARK: - Lifecycle

    func start() async {
        canvasConfig = Persistence.loadCanvasConfig()
        metalCompositor.canvasConfig = canvasConfig
        captionService.onTextChanged = { [weak self] text in
            self?.metalCompositor.captionText = text
        }
        wireAudioBusSubscribers()
        overlays = Persistence.loadOverlays()
        syncOverlays()
        youtubeAPI = YouTubeAPI(auth: youtubeAuth)
        setupChatSync()

        savedMediaPresets = Persistence.loadMediaPresets()
        if savedMediaPresets.isEmpty {
            savedMediaPresets = MediaPreset.defaults
        }
        MediaPreset.exportBundledAssets(&savedMediaPresets)
        Persistence.saveMediaPresets(savedMediaPresets)
        activeMediaPresetId = Persistence.loadActiveMediaPresetId() ?? savedMediaPresets.first?.id

        canvases = Persistence.loadCanvases()
        if canvases.isEmpty {
            canvases = Canvas.builtInCanvases()
            Persistence.saveCanvases(canvases)
        }
        activeCanvasId = Persistence.loadActiveCanvasId() ?? canvases.first?.id

        if let active = activeCanvas {
            canvasSources = active.sources
        }
        syncCanvasSources()

        if let camId = Persistence.loadSelectedCamera() { selectedCameraId = camId }
        if let micId = Persistence.loadSelectedMic() { selectedMicId = micId }
        if let dispId = Persistence.loadSelectedDisplay() { selectedDisplayId = dispId }

        discoverDevices()
        await requestPermissions()
        setupCaptureSession()
        setupRendererCallbacks()
        setupStreamManager()
        setupAudioMixer()
        setupMediaPlayer()

        if activeCanvasNeedsScreen {
            await startScreenCapture()
        }

        await updateCanvasCameraCaptures()

        if activeCanvasNeedsMedia {
            activateMediaPresetForScene()
        }

        await startSystemAudioCapture()
    }

    func stop() async {
        await stopStreaming()
        await stopScreenCapture()
        await stopSystemAudioCapture()

        // Cancel any pending watchdogs so they don't try to reattach inputs
        // mid-shutdown.
        cameraWatchdogTask?.cancel()
        micWatchdogTask?.cancel()
        for task in extraCameraWatchdogTasks.values {
            task.cancel()
        }
        extraCameraWatchdogTasks.removeAll()

        // Stop the extras and the main session on sessionQueue. The main session is
        // the last capture-lifecycle call still made from main.
        let extras = Array(extraCameraSessions.values)
        extraCameraSessions.removeAll()
        extraCameraDelegates.removeAll()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [self] in
                for session in extras {
                    session.stopRunning()
                }
                self.captureSession.stopRunning()
                cont.resume()
            }
        }
    }

    // MARK: - Metal Renderer Callbacks

    private func setupRendererCallbacks() {
        renderer.onFrame = { [weak self] commandBuffer in
            guard let self else { return [] }

            let blurScreen = self.renderScreenBlurred

            self.frameCount += 1
            if self.frameCount % 60 == 0 {
                self.renderer.flushTextureCache()
            }

            return self.metalCompositor.buildQuads(
                renderer: self.renderer,
                commandBuffer: commandBuffer,
                screenBlurred: blurScreen
            )
        }

        renderer.wantsFullResOutput = { [weak self] in
            guard let self else {
                return false
            }
            return self.recorder.isRecording || self.streamManager.destinations.contains { $0.targetHeight > 1080 }
        }

        renderer.onOutput = { [weak self] pixelBuffer, time in
            guard let self else { return }
            self.latestFullResBuffer = pixelBuffer
            if self.recorder.isRecording {
                guard let sb = self.makeSampleBuffer(from: pixelBuffer, presentationTime: time) else { return }
                self.recorder.writeVideo(sb)
            }
        }

        renderer.onStreamingOutput = { [weak self] pixelBuffer, time in
            guard let self else { return }
            if self.streamManager.isLive || self.streamManager.isConnecting {
                if let fullRes = self.latestFullResBuffer {
                    self.streamManager.sendVideo(fullResBuffer: fullRes, streamingBuffer: pixelBuffer, presentationTime: time)
                } else {
                    self.streamManager.sendVideo(pixelBuffer: pixelBuffer, presentationTime: time)
                }
            }
        }
    }

    // MARK: - Stream Manager

    private func setupStreamManager() {
        streamManager.onStatusChanged = { [weak self] status in
            self?.streamStatus = status
            if status.isLive {
                NSApplication.shared.dockTile.badgeLabel = "LIVE"
            } else {
                NSApplication.shared.dockTile.badgeLabel = nil
            }
        }
    }

    // MARK: - Device Discovery

    private func discoverDevices() {
        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video, position: .unspecified
        ).devices.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName, device: $0) }

        if !cameras.contains(where: { $0.id == selectedCameraId }), let f = cameras.first {
            selectedCameraId = f.id
        }

        microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified
        ).devices.map { AudioDevice(id: $0.uniqueID, name: $0.localizedName, device: $0) }

        if !microphones.contains(where: { $0.id == selectedMicId }), let f = microphones.first {
            selectedMicId = f.id
        }
    }

    private func requestPermissions() async {
        let v = await AVCaptureDevice.requestAccess(for: .video)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        if !v { cameraError = "Camera permission denied" }
    }

    // MARK: - Capture Session

    private func setupCaptureSession() {
        // Take app-mode control of Center Stage so AVFoundation doesn't auto-apply it.
        // Without this, virtual and Continuity Camera devices spam
        // "Failed setCenterStageFramingModeForStream" for an effect they don't support.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false

        captureSession.beginConfiguration()

        addCameraInput()
        addMicInput()

        if captureSession.canSetSessionPreset(.hd4K3840x2160) {
            captureSession.sessionPreset = .hd4K3840x2160
        } else if captureSession.canSetSessionPreset(.hd1920x1080) {
            captureSession.sessionPreset = .hd1920x1080
        } else {
            captureSession.sessionPreset = .high
        }

        let delegate = CaptureDelegate(
            onVideo: { [weak self] sb in
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
                // Pass `true` so the per-source `isMirrored` flag fully controls
                // mirroring (capturedMirrored && source.isMirrored in the compositor).
                self?.metalCompositor.feedCameraFrame(pb, mirrored: true)
                // nonisolated(unsafe) write on the capture queue. Only the watchdog reads it,
                // and a stale read just delays detection by one tick.
                self?.lastMainCameraFrameTime = CFAbsoluteTimeGetCurrent()
            },
            onAudio: { [weak self] sb, conn in
                guard let self else { return }
                // The level meter needs the AVCaptureConnection (not the buffer),
                // so it stays here. Everything else flows through the bus.
                self.processAudioLevel(conn)
                self.audioBus.publish(sb)
                // Mic watchdog timestamp, same nonisolated(unsafe) pattern as the camera one.
                self.lastMainMicFrameTime = CFAbsoluteTimeGetCurrent()
            }
        )
        frameDelegate = delegate

        let videoOut = AVCaptureVideoDataOutput()
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOut.alwaysDiscardsLateVideoFrames = true
        videoOut.setSampleBufferDelegate(delegate, queue: captureQueue)
        if captureSession.canAddOutput(videoOut) { captureSession.addOutput(videoOut) }

        // Pin audio to 16-bit signed int, interleaved, 48kHz stereo. Float32 makes CMIO
        // build a malformed destination ASBD for some virtual devices and spam PCMConverter
        // errors per frame. Leaving audioSettings nil delivers the device's native format,
        // which AudioMixer's cached AVAudioConverter can't handle when it isn't byte-for-byte
        // identical between buffers. AudioMixer converts to Float32 anyway, so the bit depth
        // here doesn't affect quality.
        let audioOut = AVCaptureAudioDataOutput()
        audioOut.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        audioOut.setSampleBufferDelegate(delegate, queue: audioQueue)
        if captureSession.canAddOutput(audioOut) { captureSession.addOutput(audioOut) }

        captureSession.commitConfiguration()
        captureSession.startRunning()
        armCameraFirstFrameWatchdog()
        armMicFirstFrameWatchdog()
    }

    func armMicFirstFrameWatchdog() {
        micWatchdogTask?.cancel()
        lastMainMicFrameTime = 0
        let armedAt = CFAbsoluteTimeGetCurrent()
        micWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.lastMainMicFrameTime > armedAt { return }
            print("[Streamif] Mic watchdog: no audio in 2.5s, re-attaching input")
            self.sessionQueue.async { [self] in
                self.captureSession.beginConfiguration()
                self.addMicInput()
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async { [self] in
                    self.lastMainMicFrameTime = 0
                }
            }
        }
    }

    func armCameraFirstFrameWatchdog() {
        cameraWatchdogTask?.cancel()
        lastMainCameraFrameTime = 0
        let armedAt = CFAbsoluteTimeGetCurrent()
        cameraWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.lastMainCameraFrameTime > armedAt { return }
            print("[Streamif] Camera watchdog: no frames in 2.5s, re-attaching input")
            self.sessionQueue.async { [self] in
                self.captureSession.beginConfiguration()
                self.addCameraInput()
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async { [self] in
                    self.lastMainCameraFrameTime = 0
                }
            }
        }
    }

    private func armExtraCameraFirstFrameWatchdog(deviceId: String) {
        extraCameraWatchdogTasks[deviceId]?.cancel()
        let armedAt = CFAbsoluteTimeGetCurrent()
        extraCameraWatchdogTasks[deviceId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled else { return }
            guard let delegate = self.extraCameraDelegates[deviceId],
                  let session = self.extraCameraSessions[deviceId] else { return }
            if delegate.lastFrameTime > armedAt { return }
            print("[Streamif] Extra camera watchdog: no frames in 2.5s for \(deviceId), re-attaching input")
            guard let device = self.cameras.first(where: { $0.id == deviceId })?.device else { return }
            self.sessionQueue.async {
                session.beginConfiguration()
                for input in session.inputs {
                    session.removeInput(input)
                }
                if let newInput = try? AVCaptureDeviceInput(device: device),
                   session.canAddInput(newInput) {
                    session.addInput(newInput)
                    self.pinFrameRate(device, to: 60)
                }
                session.commitConfiguration()
            }
        }
    }

    private func addCameraInput() {
        if let c = cameraInput { captureSession.removeInput(c); cameraInput = nil }
        guard let dev = cameras.first(where: { $0.id == selectedCameraId })?.device else {
            cameraError = "No camera found"; return
        }
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
                cameraInput = input
                cameraError = nil
                pinFrameRate(dev, to: 60)
            } else {
                cameraError = "Cannot add camera"
            }
        } catch { cameraError = error.localizedDescription }
    }

    /// Asks the camera for a fixed frame rate. Left alone, a device runs at
    /// whatever it defaults to and auto-exposure is free to halve that in poor
    /// light, while the compositor and encoder keep assuming 60.
    ///
    /// Setting a duration outside the supported ranges raises an ObjC exception,
    /// which unwinds through the Swift task and leaves the concurrency runtime
    /// with a dangling executor record (later crashing in SwiftUI hit-testing).
    /// So the duration must come from a range that really contains it: some
    /// cameras report many discrete ranges like 30.00003-30.00003 fps, where
    /// rounding the bounds to integers produces a rate outside every range.
    private func pinFrameRate(_ device: AVCaptureDevice, to target: Int32) {
        let supported = device.activeFormat.videoSupportedFrameRateRanges
        let wanted = Double(target)
        let duration: CMTime
        if supported.contains(where: { $0.minFrameRate <= wanted && wanted <= $0.maxFrameRate }) {
            duration = CMTimeMake(value: 1, timescale: target)
        } else if let fastest = supported.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
            // Target isn't supported: use the fastest range's exact bound
            // nearest to it, rather than a rounded rate that may not exist.
            duration = fastest.maxFrameRate < wanted ? fastest.minFrameDuration : fastest.maxFrameDuration
        } else {
            return
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            try ObjCException.perform {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            print("[MediaPipeline] Camera pinned to \(1 / duration.seconds) fps")
        } catch {
            print("[MediaPipeline] Could not pin camera frame rate: \(error)")
        }
    }


    private func addMicInput() {
        if let c = micInput { captureSession.removeInput(c); micInput = nil }
        guard !microphones.isEmpty else {
            micError = "No microphone available"
            return
        }

        // Try the user's selection first, then every other mic. If the preferred device
        // is unauthorized, unplugged, or held by another app, we still get audio.
        var candidates: [AudioDevice] = []
        if let preferred = microphones.first(where: { $0.id == selectedMicId }) {
            candidates.append(preferred)
        }
        for mic in microphones where mic.id != selectedMicId {
            candidates.append(mic)
        }

        var lastError: String?
        for candidate in candidates {
            do {
                let input = try AVCaptureDeviceInput(device: candidate.device)
                guard captureSession.canAddInput(input) else {
                    lastError = "Capture session refused '\(candidate.device.localizedName)'"
                    continue
                }
                captureSession.addInput(input)
                micInput = input
                if candidate.id != selectedMicId {
                    selectedMicId = candidate.id
                    micError = "Switched to '\(candidate.device.localizedName)' - your previous mic is unavailable"
                } else {
                    micError = nil
                }
                return
            } catch {
                let nsError = error as NSError
                lastError = nsError.localizedDescription
                continue
            }
        }

        if let lastError {
            if lastError.lowercased().contains("not authorized") {
                micError = "Microphone access denied. Open System Settings → Privacy & Security → Microphone and enable Streamif, then relaunch the app."
            } else {
                micError = lastError
            }
        } else {
            micError = "Could not attach any microphone"
        }
    }

    // MARK: - Audio Bus

    private func wireAudioBusSubscribers() {
        guard audioBusSubscriptions.isEmpty else { return }

        audioBusSubscriptions.append(audioBus.subscribe { [weak self] sb in
            guard let self else { return }
            if !self.isMuted {
                self.audioMixer.feedMic(sb)
            }
        })

        audioBusSubscriptions.append(audioBus.subscribe { [weak self] sb in
            self?.captionService.appendAudio(sb)
        })
    }

    // MARK: - Audio Level (throttled to 20Hz)

    private func processAudioLevel(_ connection: AVCaptureConnection) {
        guard !isMuted else {
            throttledAudioUIUpdate(0)
            return
        }

        guard let ch = connection.audioChannels.first else { return }
        let power = ch.averagePowerLevel
        let norm = max(0, min(1, (power + 50) / 50)) * micVolume
        audioSmoothed = audioSmoothed * 0.7 + norm * 0.3

        throttledAudioUIUpdate(audioSmoothed)
    }

    private func throttledAudioUIUpdate(_ level: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAudioUIUpdate >= audioUIUpdateInterval else { return }
        lastAudioUIUpdate = now

        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = level
        }
    }

    // MARK: - Device Selection

    var selectedCamera: AVCaptureDevice? { cameras.first { $0.id == selectedCameraId }?.device }
    var selectedMic: AVCaptureDevice? { microphones.first { $0.id == selectedMicId }?.device }

    func selectCamera(_ id: String) {
        selectedCameraId = id
        isCameraLoading = true
        Persistence.saveSelectedCamera(id)
        // Session lifecycle goes on sessionQueue, not captureQueue. captureQueue delivers
        // sample buffers, and configuring the session there can race with frame callbacks.
        sessionQueue.async { [self] in
            captureSession.beginConfiguration()
            addCameraInput()
            if captureSession.canSetSessionPreset(.hd4K3840x2160) {
                captureSession.sessionPreset = .hd4K3840x2160
            } else if captureSession.canSetSessionPreset(.hd1920x1080) {
                captureSession.sessionPreset = .hd1920x1080
            } else {
                captureSession.sessionPreset = .high
            }
            captureSession.commitConfiguration()
            DispatchQueue.main.async { [self] in
                isCameraLoading = false
                // The watchdog re-arms on every input change, so reset the timer.
                self.armCameraFirstFrameWatchdog()
                // A source whose cameraDeviceId matched the OLD selectedCameraId rode the main
                // session's texture and would silently follow the new global. A source matching
                // the NEW one now has a redundant extra session to tear down.
                Task { await self.updateCanvasCameraCaptures() }
            }
        }
    }

    func selectMicrophone(_ id: String) {
        selectedMicId = id
        Persistence.saveSelectedMic(id)
        sessionQueue.async { [self] in
            self.captureSession.beginConfiguration()
            self.addMicInput()
            self.captureSession.commitConfiguration()
            DispatchQueue.main.async { [self] in
                self.armMicFirstFrameWatchdog()
            }
        }
    }

    // MARK: - Mute

    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            audioLevel = 0
        }
    }

    func toggleScreenBlur() {
        isScreenBlurred.toggle()
        renderScreenBlurred = isScreenBlurred
    }

    private func applyNoiseSuppression() {
        audioMixer.noiseGateEnabled = noiseSuppression
        print("[Streamif] Noise suppression \(noiseSuppression ? "enabled" : "disabled")")
    }

    // MARK: - Canvas-driven scene switching

    private func canvasNeedsScreen(_ canvas: Canvas) -> Bool {
        canvas.sources.contains { $0.type == .screenCapture }
    }

    private func canvasNeedsMedia(_ canvas: Canvas) -> Bool {
        canvas.sources.contains { $0.type == .mediaFile }
    }

    var activeCanvasNeedsScreen: Bool {
        guard let canvas = activeCanvas else { return false }
        return canvasNeedsScreen(canvas)
    }

    var activeCanvasNeedsMedia: Bool {
        guard let canvas = activeCanvas else { return false }
        return canvasNeedsMedia(canvas)
    }

    func setCanvas(_ id: UUID) async {
        guard let target = canvases.first(where: { $0.id == id }) else { return }
        let isSame = activeCanvasId == id
        let needsScreen = canvasNeedsScreen(target)
        let needsGate = (streamManager.isLive || isRecording)

        if !isSame {
            persistCanvasSources()
        }

        // Only when live or recording does a blank frame reach viewers or disk, so
        // only then do we wait.
        if needsGate && needsScreen && !isScreenCapturing {
            await startScreenCapture()
            hasWarmedScreenCapture = true
            await waitForFirstScreenFrame(timeout: 1.0)
        }

        activeCanvasId = id
        canvasSources = target.sources
        selectedCanvasSourceId = nil
        syncCanvasSources()
        Persistence.saveActiveCanvasId(activeCanvasId)

        // switchToMediaPreset loads the media and then calls setCanvas, so reloading here
        // when media is already loaded restarts the video forever and keeps pulling the
        // canvas back to Media.
        if canvasNeedsMedia(target) && mediaUrl == nil {
            activateMediaPresetForScene()
        }

        if !isSame && streamManager.isLive {
            streamManager.forceKeyframe()
        }

        // Serial reconcile task, off the hot swap path. The chain keeps rapid A to B to A
        // switches from racing.
        enqueueReconcile { [weak self] in
            guard let self else { return }
            if needsScreen && !self.isScreenCapturing {
                await self.startScreenCapture()
                self.hasWarmedScreenCapture = true
            }
            // Lazy-warm: leaving a screen canvas doesn't tear down the main stream. It stops
            // at app shutdown. Costs some idle GPU, buys instant switches.
            await self.updateCanvasCameraCaptures()
            await self.updateCanvasScreenCaptures()
        }
    }

    private func enqueueReconcile(_ work: @escaping @MainActor () async -> Void) {
        let previous = reconcileTask
        reconcileTask = Task { @MainActor in
            await previous?.value
            if Task.isCancelled { return }
            await work()
        }
    }

    func syncOverlays() {
        metalCompositor.overlays = overlays
        updateCaptionServiceState()
    }

    func addOverlay(_ overlay: StreamOverlay) {
        overlays.append(overlay)
        syncOverlays()
        Persistence.saveOverlays(overlays)
    }

    func removeOverlay(_ id: UUID) {
        overlays.removeAll { $0.id == id }
        metalCompositor.clearOverlayCache(for: id)
        syncOverlays()
        Persistence.saveOverlays(overlays)
    }

    private func updateCaptionServiceState() {
        let hasActiveCaption = overlays.contains { $0.type == .captions && $0.isVisible }
        if hasActiveCaption {
            if !captionService.isRunning {
                captionService.start()
            }
        } else if captionService.isRunning {
            captionService.stop()
        }
    }

    func updateOverlay(_ overlay: StreamOverlay) {
        if let idx = overlays.firstIndex(where: { $0.id == overlay.id }) {
            overlays[idx] = overlay
            syncOverlays()
            Persistence.saveOverlays(overlays)
        }
    }

    func moveOverlay(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < overlays.count,
              destinationIndex >= 0, destinationIndex <= overlays.count else { return }
        let overlay = overlays.remove(at: sourceIndex)
        let insertAt = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        overlays.insert(overlay, at: min(insertAt, overlays.count))
        syncOverlays()
        Persistence.saveOverlays(overlays)
    }

    // MARK: - YouTube Integration

    private func setupChatSync() {
        Task {
            while !Task.isCancelled {
                if youtubeChatService.isPolling || twitchChatService.isConnected {
                    metalCompositor.chatMessages = allChatMessages
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func startYouTubeChat() {
        guard let api = youtubeAPI, let chatId = youtubeBroadcast?.liveChatId else { return }
        youtubeChatService.start(api: api, liveChatId: chatId)
    }

    func stopYouTubeChat() {
        youtubeChatService.stop()
        syncChatMessages()
        dismissFeaturedMessage()
    }

    func connectTwitchChat(channel: String) async {
        guard let token = await twitchAuth.getAccessToken(),
              let username = twitchAuth.username else { return }
        twitchChatService.connect(token: token, username: username, channel: channel)
    }

    func disconnectTwitchChat() {
        twitchChatService.disconnect()
        syncChatMessages()
        dismissFeaturedMessage()
    }

    private func syncChatMessages() {
        if !youtubeChatService.isPolling && !twitchChatService.isConnected {
            metalCompositor.chatMessages = []
        } else {
            metalCompositor.chatMessages = allChatMessages
        }
    }

    func featureChatMessage(_ message: YouTubeChatMessage) {
        if featuredChatMessage?.id == message.id {
            dismissFeaturedMessage()
            return
        }
        featuredChatMessage = message
        metalCompositor.featuredChatMessage = message
    }

    func dismissFeaturedMessage() {
        featuredChatMessage = nil
        metalCompositor.featuredChatMessage = nil
        metalCompositor.clearFeaturedChatCache()
    }

    @discardableResult
    func fetchActiveBroadcastChat() async -> String? {
        guard let api = youtubeAPI, youtubeAuth.isSignedIn else {
            return "Not signed in to YouTube."
        }

        do {
            if let broadcast = try await api.getActiveBroadcast() {
                if let chatId = broadcast.liveChatId {
                    youtubeBroadcast = broadcast
                    youtubeChatService.start(api: api, liveChatId: chatId)
                    return nil
                }
                return "Broadcast found but has no live chat ID."
            }
            return "No active broadcast found. Start streaming on YouTube first."
        } catch {
            print("[YouTube] Failed to fetch active broadcast: \(error)")
            return "YouTube API error: \(error.localizedDescription)"
        }
    }

    // MARK: - Canvas Sources

    func syncCanvasSources() {
        metalCompositor.canvasSources = canvasSources
    }

    func persistCanvasSources() {
        guard let activeId = activeCanvasId,
              let idx = canvases.firstIndex(where: { $0.id == activeId }) else { return }
        canvases[idx].sources = canvasSources

        persistDebounceTask?.cancel()
        persistDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            Persistence.saveCanvases(canvases)
        }
    }

    // MARK: - Canvas Management

    var activeCanvas: Canvas? {
        guard let activeId = activeCanvasId else { return nil }
        return canvases.first { $0.id == activeId }
    }

    func createCanvas(name: String? = nil) {
        let count = canvases.count + 1
        let canvas = Canvas(name: name ?? "Canvas \(count)")
        canvases.append(canvas)
        Persistence.saveCanvases(canvases)
        Task { await setCanvas(canvas.id) }
    }

    func deleteCanvas(_ id: UUID) {
        guard let idx = canvases.firstIndex(where: { $0.id == id }) else { return }
        if canvases[idx].isBuiltIn { return }

        let wasActive = activeCanvasId == id
        canvases.remove(at: idx)
        Persistence.saveCanvases(canvases)

        if wasActive, let next = canvases.first {
            Task { await setCanvas(next.id) }
        }
    }

    func renameCanvas(_ id: UUID, name: String) {
        guard let idx = canvases.firstIndex(where: { $0.id == id }) else { return }
        canvases[idx].name = name
        Persistence.saveCanvases(canvases)
    }

    func addCanvasSource(_ source: CanvasSource) {
        canvasSources.append(source)
        syncCanvasSources()
        persistCanvasSources()
        enqueueReconcile { [weak self] in
            guard let self else { return }
            await self.reconcileScreenCaptureForActiveCanvas()
            await self.updateCanvasCameraCaptures()
        }
    }

    func removeCanvasSource(_ id: UUID) {
        canvasSources.removeAll { $0.id == id }
        metalCompositor.clearSourceCache(for: id)
        syncCanvasSources()
        persistCanvasSources()
        enqueueReconcile { [weak self] in
            guard let self else { return }
            await self.reconcileScreenCaptureForActiveCanvas()
            await self.updateCanvasCameraCaptures()
        }
    }

    func updateCanvasSource(_ source: CanvasSource) {
        if let idx = canvasSources.firstIndex(where: { $0.id == source.id }) {
            let oldDeviceId = canvasSources[idx].cameraDeviceId
            let oldScreenSpec = canvasSources[idx].screenSourceSpec
            canvasSources[idx] = source
            syncCanvasSources()
            persistCanvasSources()
            let cameraChanged = source.type == .camera && source.cameraDeviceId != oldDeviceId
            let screenChanged = source.type == .screenCapture && source.screenSourceSpec != oldScreenSpec
            if cameraChanged || screenChanged {
                enqueueReconcile { [weak self] in
                    guard let self else { return }
                    if cameraChanged {
                        await self.updateCanvasCameraCaptures()
                    }
                    if screenChanged {
                        await self.updateCanvasScreenCaptures()
                    }
                }
            }
        }
    }

    func reorderCanvasSources(_ ids: [UUID]) {
        var reordered: [CanvasSource] = []
        for (index, id) in ids.enumerated() {
            if var source = canvasSources.first(where: { $0.id == id }) {
                source.zOrder = index
                reordered.append(source)
            }
        }
        canvasSources = reordered
        syncCanvasSources()
        persistCanvasSources()
    }

    func duplicateCanvasSource(_ id: UUID) {
        guard let source = canvasSources.first(where: { $0.id == id }) else { return }
        let maxZ = canvasSources.map(\.zOrder).max() ?? 0
        var copy = CanvasSource(type: source.type, label: source.label + " Copy", zOrder: maxZ + 1)
        copy.x = min(source.x + 0.02, 0.95)
        copy.y = min(source.y + 0.02, 0.95)
        copy.width = source.width
        copy.height = source.height
        copy.cornerRadius = source.cornerRadius
        copy.opacity = source.opacity
        copy.cameraDeviceId = source.cameraDeviceId
        copy.isMirrored = source.isMirrored
        copy.cropLeft = source.cropLeft
        copy.cropRight = source.cropRight
        copy.cropTop = source.cropTop
        copy.cropBottom = source.cropBottom
        copy.imagePath = source.imagePath
        copy.isLocked = false
        addCanvasSource(copy)
        selectedCanvasSourceId = copy.id
    }

    func moveCanvasSourceUp(_ id: UUID) {
        let sorted = canvasSources.sorted { $0.zOrder < $1.zOrder }
        guard let idx = sorted.firstIndex(where: { $0.id == id }), idx < sorted.count - 1 else { return }
        var updated = sorted
        let currentZ = updated[idx].zOrder
        updated[idx].zOrder = updated[idx + 1].zOrder
        updated[idx + 1].zOrder = currentZ
        canvasSources = updated
        syncCanvasSources()
        persistCanvasSources()
    }

    func moveCanvasSourceDown(_ id: UUID) {
        let sorted = canvasSources.sorted { $0.zOrder < $1.zOrder }
        guard let idx = sorted.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        var updated = sorted
        let currentZ = updated[idx].zOrder
        updated[idx].zOrder = updated[idx - 1].zOrder
        updated[idx - 1].zOrder = currentZ
        canvasSources = updated
        syncCanvasSources()
        persistCanvasSources()
    }

    func reorderCanvasSource(_ draggedId: UUID, toZOrderOf targetId: UUID) {
        var sorted = canvasSources.sorted { $0.zOrder > $1.zOrder }
        guard let fromIndex = sorted.firstIndex(where: { $0.id == draggedId }),
              let toIndex = sorted.firstIndex(where: { $0.id == targetId }) else { return }
        if fromIndex == toIndex { return }

        let item = sorted.remove(at: fromIndex)
        let insertAt = fromIndex < toIndex ? toIndex : toIndex
        sorted.insert(item, at: insertAt)

        for (i, _) in sorted.enumerated() {
            sorted[i].zOrder = sorted.count - 1 - i
        }
        canvasSources = sorted
        syncCanvasSources()
        persistCanvasSources()
    }

    func reconcileScreenCaptureForActiveCanvas() async {
        let needs = activeCanvasNeedsScreen
        if needs && !isScreenCapturing {
            await startScreenCapture()
            hasWarmedScreenCapture = true
        }
        await updateCanvasScreenCaptures()
    }

    private var globalScreenSpec: String {
        switch selectedScreenSource {
        case .display(let id): return "d:\(id)"
        case .window(let id): return "w:\(id)"
        case nil: return ""
        }
    }

    func updateCanvasScreenCaptures() async {
        let globalSpec = globalScreenSpec
        let neededSpecs = Set(
            canvasSources
                .filter { $0.type == .screenCapture && !$0.screenSourceSpec.isEmpty && $0.screenSourceSpec != globalSpec }
                .map(\.screenSourceSpec)
        )

        for spec in extraScreenStreams.keys where !neededSpecs.contains(spec) {
            await stopExtraScreenStream(spec: spec)
        }

        for spec in neededSpecs where extraScreenStreams[spec] == nil {
            await startExtraScreenStream(spec: spec)
        }
    }

    private func startExtraScreenStream(spec: String) async {
        await discoverScreenSources()

        let filter: SCContentFilter
        var bufferWidth = 3840
        var bufferHeight = 2160

        if spec.hasPrefix("d:"), let displayId = UInt32(spec.dropFirst(2)) {
            guard let display = displays.first(where: { $0.displayID == displayId }) else { return }
            filter = SCContentFilter(display: display, excludingWindows: await selfWindowsToExclude())
            let (pixelW, pixelH) = pixelDimensions(forDisplayID: displayId,
                                                   fallbackW: display.width,
                                                   fallbackH: display.height)
            let (w, h) = fitWithin(sourceW: pixelW, sourceH: pixelH, maxW: 3840, maxH: 2160)
            bufferWidth = w
            bufferHeight = h
        } else if spec.hasPrefix("w:"), let windowId = UInt32(spec.dropFirst(2)) {
            guard let window = windows.first(where: { $0.windowID == windowId }) else { return }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = backingScale(forWindow: window)
            let (w, h) = fitWithin(
                sourceW: window.frame.width * scale,
                sourceH: window.frame.height * scale,
                maxW: 3840,
                maxH: 2160
            )
            bufferWidth = w
            bufferHeight = h
        } else {
            return
        }

        let config = SCStreamConfiguration()
        config.width = bufferWidth
        config.height = bufferHeight
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let output = ScreenFrameOutput(onScreen: { [weak self] sb in
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            self?.metalCompositor.feedExtraScreenFrame(pb, spec: spec)
        })

        do {
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "com.streamif.screen.\(spec)", qos: .userInteractive))
            try await stream.startCapture()
            extraScreenStreams[spec] = stream
            extraScreenOutputs[spec] = output
        } catch {
            print("[Streamif] Extra screen capture error for \(spec): \(error)")
        }
    }

    /// Our own windows, which display captures leave out so the app doesn't film itself.
    /// The chat pop-out is left in when the user has chosen to show it on stream.
    private func selfWindowsToExclude() async -> [SCWindow] {
        let myBundleId = Bundle.main.bundleIdentifier
        let visibleChatWindow = ChatPopout.shared.showInScreenShare ? ChatPopout.shared.windowNumber : nil
        return (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))?.windows.filter {
            $0.owningApplication?.bundleIdentifier == myBundleId
                && visibleChatWindow != Int($0.windowID)
        } ?? []
    }

    /// Recomputes the excluded windows on running display captures, e.g. after the chat
    /// pop-out opens or its screen-share toggle flips.
    func refreshScreenCaptureExclusions() async {
        let excluded = await selfWindowsToExclude()
        var targets: [(SCStream, CGDirectDisplayID)] = []
        if let screenStream, case .display(let id) = selectedScreenSource {
            targets.append((screenStream, id))
        }
        for (spec, stream) in extraScreenStreams where spec.hasPrefix("d:") {
            if let id = UInt32(spec.dropFirst(2)) { targets.append((stream, id)) }
        }
        for (stream, id) in targets {
            guard let display = displays.first(where: { $0.displayID == id }) else { continue }
            try? await stream.updateContentFilter(SCContentFilter(display: display, excludingWindows: excluded))
        }
    }

    private func stopExtraScreenStream(spec: String) async {
        guard let stream = extraScreenStreams.removeValue(forKey: spec) else { return }
        let output = extraScreenOutputs.removeValue(forKey: spec)
        if let output {
            try? stream.removeStreamOutput(output, type: .screen)
        }
        try? await stream.stopCapture()
        metalCompositor.clearExtraScreenBuffer(spec: spec)
    }

    func updateCanvasCameraCaptures() async {
        // What the active canvas needs right now. We never start a camera speculatively
        // for a canvas the user isn't looking at, since that would light the LED.
        let activeNeededDeviceIds = Set(
            canvasSources
                .filter { $0.type == .camera && !$0.cameraDeviceId.isEmpty && $0.cameraDeviceId != selectedCameraId }
                .map(\.cameraDeviceId)
        )
        // What any canvas references. A running extra stays warm while some canvas still
        // wants it, so only orphaned extras get torn down.
        let referencedDeviceIds = Set(
            canvases.flatMap(\.sources)
                .filter { $0.type == .camera && !$0.cameraDeviceId.isEmpty && $0.cameraDeviceId != selectedCameraId }
                .map(\.cameraDeviceId)
        )

        let removedSessions: [(String, AVCaptureSession)] = extraCameraSessions
            .filter { !referencedDeviceIds.contains($0.key) }
            .map { ($0.key, $0.value) }
        for (deviceId, _) in removedSessions {
            extraCameraWatchdogTasks[deviceId]?.cancel()
            extraCameraWatchdogTasks.removeValue(forKey: deviceId)
            extraCameraSessions.removeValue(forKey: deviceId)
            extraCameraDelegates.removeValue(forKey: deviceId)
            metalCompositor.clearExtraCameraBuffer(deviceId: deviceId)
        }
        if !removedSessions.isEmpty {
            let sessions = removedSessions.map { $0.1 }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                sessionQueue.async {
                    for session in sessions {
                        session.stopRunning()
                    }
                    cont.resume()
                }
            }
        }

        let preset = captureSession.sessionPreset
        let compositor = metalCompositor
        let queue = captureQueue
        for deviceId in activeNeededDeviceIds where extraCameraSessions[deviceId] == nil {
            guard let device = cameras.first(where: { $0.id == deviceId })?.device else {
                print("[Streamif] Extra camera: no discovered device matches saved id \(deviceId) - source will fall back to main camera texture")
                continue
            }
            let result: (AVCaptureSession, CanvasCameraCaptureDelegate)? = await withCheckedContinuation { cont in
                sessionQueue.async {
                    let session = AVCaptureSession()
                    session.beginConfiguration()
                    do {
                        let input = try AVCaptureDeviceInput(device: device)
                        if session.canAddInput(input) {
                            session.addInput(input)
                        }
                        // The main camera's preset may be one this device can't do.
                        if session.canSetSessionPreset(preset) {
                            session.sessionPreset = preset
                        } else if session.canSetSessionPreset(.hd1920x1080) {
                            session.sessionPreset = .hd1920x1080
                        }
                        let output = AVCaptureVideoDataOutput()
                        output.videoSettings = [
                            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                        ]
                        let delegate = CanvasCameraCaptureDelegate(deviceId: deviceId, compositor: compositor)
                        output.setSampleBufferDelegate(delegate, queue: queue)
                        if session.canAddOutput(output) {
                            session.addOutput(output)
                        }
                        session.commitConfiguration()
                        session.startRunning()
                        cont.resume(returning: (session, delegate))
                    } catch {
                        session.commitConfiguration()
                        print("[Streamif] Extra camera error for \(deviceId): \(error)")
                        cont.resume(returning: nil)
                    }
                }
            }
            if let (session, delegate) = result {
                extraCameraSessions[deviceId] = session
                extraCameraDelegates[deviceId] = delegate
                armExtraCameraFirstFrameWatchdog(deviceId: deviceId)
            }
        }
    }

    // MARK: - Audio Mixer

    private func setupAudioMixer() {
        audioMixer.onMixedAudio = { [weak self] sb in
            self?.streamManager.sendAudio(sampleBuffer: sb)
            self?.recorder.writeAudio(sb)
        }
    }

    // MARK: - Media Player

    private func setupMediaPlayer() {
        mediaPlayer.onFrame = { [weak self] pb in
            self?.metalCompositor.feedMediaFrame(pb)
        }
        mediaPlayer.onStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                self?.mediaPlayerState = state
            }
        }
    }

    func loadMedia(url: URL) {
        mediaUrl = url
        mediaPlayer.load(url: url)
        mediaPlayer.isLooping = true
        mediaPlayer.play()
    }

    func playMedia() {
        mediaPlayer.play()
    }

    func pauseMedia() {
        mediaPlayer.pause()
    }

    func stopMedia() {
        mediaPlayer.stop()
        mediaUrl = nil
    }

    // MARK: - Media Preset Management

    var activeMediaPreset: MediaPreset? {
        guard let activeId = activeMediaPresetId else { return nil }
        return savedMediaPresets.first { $0.id == activeId }
    }

    func createMediaPreset(name: String? = nil) {
        let count = savedMediaPresets.count + 1
        let preset = MediaPreset(name: name ?? "Preset \(count)")
        savedMediaPresets.append(preset)
        switchToMediaPreset(preset.id)
    }

    func switchToMediaPreset(_ id: UUID) {
        guard let preset = savedMediaPresets.first(where: { $0.id == id }) else { return }
        activeMediaPresetId = id
        Persistence.saveActiveMediaPresetId(activeMediaPresetId)

        applyMediaPresetToMediaCanvas(preset)

        stopMedia()
        metalCompositor.clearMedia()

        if let path = preset.filePath, preset.isVideo {
            loadMedia(url: URL(fileURLWithPath: path))
        }

        Task { await setCanvas(Canvas.mediaBuiltInId) }
    }

    private func applyMediaPresetToMediaCanvas(_ preset: MediaPreset) {
        guard let idx = canvases.firstIndex(where: { $0.id == Canvas.mediaBuiltInId }) else { return }
        guard !canvases[idx].sources.isEmpty else { return }

        var source = canvases[idx].sources[0]
        source.label = preset.name

        if preset.filePath != nil, preset.isVideo {
            source.type = .mediaFile
            source.imagePath = ""
        } else if let path = preset.filePath, preset.isImage {
            source.type = .image
            source.imagePath = path
        } else {
            source.type = .image
            source.imagePath = ""
        }

        canvases[idx].sources[0] = source
        Persistence.saveCanvases(canvases)

        if activeCanvasId == Canvas.mediaBuiltInId {
            canvasSources = canvases[idx].sources
            syncCanvasSources()
        }
    }

    func setMediaPresetFile(_ id: UUID, path: String) {
        guard let idx = savedMediaPresets.firstIndex(where: { $0.id == id }) else { return }
        savedMediaPresets[idx].filePath = path
        Persistence.saveMediaPresets(savedMediaPresets)

        if id == activeMediaPresetId {
            switchToMediaPreset(id)
        }
    }

    func renameMediaPreset(_ id: UUID, name: String) {
        guard let idx = savedMediaPresets.firstIndex(where: { $0.id == id }) else { return }
        savedMediaPresets[idx].name = name
        Persistence.saveMediaPresets(savedMediaPresets)
    }

    func deleteMediaPreset(_ id: UUID) {
        let wasActive = activeMediaPresetId == id
        savedMediaPresets.removeAll { $0.id == id }

        if wasActive {
            if let first = savedMediaPresets.first {
                switchToMediaPreset(first.id)
            } else {
                activeMediaPresetId = nil
                stopMedia()
                metalCompositor.clearMedia()
            }
        }

        Persistence.saveMediaPresets(savedMediaPresets)
        Persistence.saveActiveMediaPresetId(activeMediaPresetId)
    }

    func activateMediaPresetForScene() {
        if let id = activeMediaPresetId {
            switchToMediaPreset(id)
        }
    }

    // MARK: - System Audio Capture

    private func startSystemAudioCapture() async {
        guard systemAudioStream == nil else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return }

            // Sound effects and media files play through the speakers, so they only
            // reach the stream through this capture. With system audio off it still
            // runs, limited to this app's own sound.
            let filter: SCContentFilter
            if systemAudioEnabled {
                filter = SCContentFilter(display: display, excludingWindows: [])
            } else {
                guard let app = content.applications.first(where: { $0.bundleIdentifier == Bundle.main.bundleIdentifier }) else {
                    return
                }
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            }
            let config = SCStreamConfiguration()
            config.width = 2
            config.height = 2
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = false
            config.channelCount = 2
            config.sampleRate = 48000

            let output = ScreenFrameOutput(
                onScreen: nil,
                onAudio: { [weak self] sb in
                    self?.audioMixer.feedSystem(sb)
                }
            )
            systemAudioOutput = output

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            let sysAudioQueue = DispatchQueue(label: "com.streamif.systemaudio", qos: .userInteractive)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sysAudioQueue)
            // SCStream produces video frames even when we only want audio. A no-op screen
            // output consumes them, otherwise CoreMedia logs a dropped-frame error for each one.
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sysAudioQueue)
            try await stream.startCapture()
            systemAudioStream = stream
        } catch {
            print("[Streamif] System audio capture error: \(error)")
        }
    }

    private func stopSystemAudioCapture() async {
        guard let stream = systemAudioStream else { return }
        do { try await stream.stopCapture() } catch {}
        systemAudioStream = nil
        systemAudioOutput = nil
    }

    // MARK: - Screen Capture

    func discoverScreenSources() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            displays = content.displays
            let junkApps: Set<String> = ["com.apple.controlcenter", "com.apple.dock"]
            let junkTitles: Set<String> = ["StatusIndicator", "Cursor", "Menubar", "Backstop"]
            windows = content.windows.filter { window in
                guard let app = window.owningApplication else { return false }
                let bid = app.bundleIdentifier ?? ""
                guard bid != Bundle.main.bundleIdentifier else { return false }
                if junkApps.contains(bid) { return false }
                guard let title = window.title, !title.isEmpty else { return false }
                if junkTitles.contains(title) { return false }
                if title.hasPrefix("Control Center") { return false }
                guard window.isOnScreen else { return false }
                guard window.frame.width >= 50, window.frame.height >= 50 else { return false }
                return window.windowLayer == 0
            }
            if selectedDisplayId == nil, let f = displays.first { selectedDisplayId = f.displayID }
            if selectedScreenSource == nil, let f = displays.first {
                selectedScreenSource = .display(f.displayID)
            }
        } catch { print("[Streamif] Screen source error: \(error)") }
    }

    func selectScreenSource(_ source: ScreenSource) async {
        selectedScreenSource = source
        if isScreenCapturing {
            await stopScreenCapture()
            await startScreenCapture()
        }
        // The global default changed, so a per-source override that used to match it and
        // rode the main stream may now need its own extra.
        await updateCanvasScreenCaptures()
    }

    private func waitForFirstScreenFrame(timeout: TimeInterval) async {
        if screenFrameAvailable {
            return
        }
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while !screenFrameAvailable && CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func startScreenCapture() async {
        guard !isScreenCapturing else { return }
        await discoverScreenSources()

        let filter: SCContentFilter
        // Size the buffer to the source's native aspect ratio so the compositor's aspect-fit
        // centers it. A fixed 4K buffer puts non-16:9 window captures in the top-left.
        var bufferWidth = 3840
        var bufferHeight = 2160
        switch selectedScreenSource {
        case .display(let displayId):
            guard let display = displays.first(where: { $0.displayID == displayId }) else { return }
            filter = SCContentFilter(display: display, excludingWindows: await selfWindowsToExclude())
            let (pixelW, pixelH) = pixelDimensions(forDisplayID: displayId,
                                                   fallbackW: display.width,
                                                   fallbackH: display.height)
            let (w, h) = fitWithin(
                sourceW: pixelW,
                sourceH: pixelH,
                maxW: 3840,
                maxH: 2160
            )
            bufferWidth = w
            bufferHeight = h
        case .window(let windowId):
            guard let window = windows.first(where: { $0.windowID == windowId }) else { return }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = backingScale(forWindow: window)
            let (w, h) = fitWithin(
                sourceW: window.frame.width * scale,
                sourceH: window.frame.height * scale,
                maxW: 3840,
                maxH: 2160
            )
            bufferWidth = w
            bufferHeight = h
        case nil:
            return
        }

        let config = SCStreamConfiguration()
        config.width = bufferWidth
        config.height = bufferHeight
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        screenFrameAvailable = false
        let output = ScreenFrameOutput(onScreen: { [weak self] sb in
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            self?.metalCompositor.feedScreenFrame(pb)
            Task { @MainActor [weak self] in
                self?.screenFrameAvailable = true
            }
        })
        screenOutput = output

        do {
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "com.streamif.screen", qos: .userInteractive))
            try await stream.startCapture()
            screenStream = stream; isScreenCapturing = true
        } catch { print("[Streamif] Screen capture error: \(error)") }
    }

    private func pixelDimensions(forDisplayID displayId: CGDirectDisplayID,
                                 fallbackW: Int,
                                 fallbackH: Int) -> (CGFloat, CGFloat) {
        if let mode = CGDisplayCopyDisplayMode(displayId) {
            return (CGFloat(mode.pixelWidth), CGFloat(mode.pixelHeight))
        }
        return (CGFloat(fallbackW), CGFloat(fallbackH))
    }

    private func backingScale(forWindow window: SCWindow) -> CGFloat {
        let frame = window.frame
        var best: (display: SCDisplay, area: CGFloat)?
        for display in displays {
            let intersection = display.frame.intersection(frame)
            if intersection.isNull {
                continue
            }
            let area = intersection.width * intersection.height
            if best == nil || area > best!.area {
                best = (display, area)
            }
        }
        guard let display = best?.display else {
            return 2.0
        }
        if let mode = CGDisplayCopyDisplayMode(display.displayID), mode.width > 0 {
            return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
        }
        return 2.0
    }

    private func fitWithin(sourceW: CGFloat, sourceH: CGFloat, maxW: Int, maxH: Int) -> (Int, Int) {
        guard sourceW > 0, sourceH > 0 else {
            return (maxW, maxH)
        }
        let scale = min(CGFloat(maxW) / sourceW, CGFloat(maxH) / sourceH, 1.0)
        let w = max(2, Int((sourceW * scale).rounded()) & ~1)
        let h = max(2, Int((sourceH * scale).rounded()) & ~1)
        return (w, h)
    }

    private func stopScreenCapture() async {
        guard isScreenCapturing else { return }
        isScreenCapturing = false
        screenFrameAvailable = false
        let stream = screenStream
        let output = screenOutput
        screenStream = nil
        screenOutput = nil
        if let stream, let output {
            do {
                try stream.removeStreamOutput(output, type: .screen)
            } catch {
                print("[Streamif] removeStreamOutput failed: \(error)")
            }
        }
        do {
            try await stream?.stopCapture()
        } catch {
            print("[Streamif] stopCapture failed: \(error)")
        }
    }

    // MARK: - Streaming (Native RTMP)

    func startStreaming(destinations: [StreamDestination], record: Bool = false) {
        let enabled = destinations.filter { $0.enabled }
        guard !enabled.isEmpty else { return }
        guard !streamStatus.isLive else { return }
        streamStatus = .connecting

        for dest in enabled {
            let client = RTMPClient(config: RTMPClient.Config(
                url: dest.rtmpUrl,
                streamKey: dest.streamKey,
                width: dest.videoWidth,
                height: dest.videoHeight,
                videoBitrate: dest.videoBitrate,
                audioBitrate: dest.audioBitrate,
                fps: dest.fps,
                sampleRate: 48000,
                channels: 2
            ), id: dest.id)

            streamManager.addDestination(client)
        }

        if record {
            startRecording()
        }
    }

    func startStreaming(destination: StreamDestination) {
        startStreaming(destinations: [destination])
    }

    func stopStreaming() async {
        streamManager.removeAll()
        streamStatus = .idle
        stopRecording()
        stopYouTubeChat()
    }

    // MARK: - Local Recording

    func startRecording() {
        recorder.start()
        isRecording = recorder.isRecording
    }

    func stopRecording(completion: (() -> Void)? = nil) {
        recorder.stop(completion: completion)
        isRecording = false
    }

    // MARK: - Sample Buffer Creation

    private nonisolated func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &fd)
        guard let formatDesc = fd else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer,
            formatDescription: formatDesc, sampleTiming: &timing,
            sampleBufferOut: &sb
        )
        return sb
    }

    // MARK: - Test Connection

    func testConnection(_ dest: StreamDestination) async -> (success: Bool, message: String) {
        let url = dest.rtmpUrl.hasSuffix("/") ? dest.rtmpUrl + dest.streamKey : dest.rtmpUrl + "/" + dest.streamKey
        guard let u = URL(string: url), let host = u.host else { return (false, "Invalid URL") }
        let port = u.port ?? (u.scheme == "rtmps" ? 443 : 1935)

        return await withCheckedContinuation { cont in
            var done = false
            let conn = NWConnection(host: .init(host), port: .init(integerLiteral: UInt16(port)), using: .tcp)
            conn.stateUpdateHandler = { state in
                guard !done else { return }
                switch state {
                case .ready: done = true; conn.cancel(); cont.resume(returning: (true, "OK (\(host):\(port))"))
                case .failed(let e): done = true; conn.cancel(); cont.resume(returning: (false, e.localizedDescription))
                default: break
                }
            }
            conn.start(queue: DispatchQueue(label: "com.streamif.test"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                guard !done else { return }; done = true; conn.cancel()
                cont.resume(returning: (false, "Timed out"))
            }
        }
    }
}

// MARK: - Capture Delegate

private class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let onVideo: (CMSampleBuffer) -> Void
    let onAudio: (CMSampleBuffer, AVCaptureConnection) -> Void

    init(onVideo: @escaping (CMSampleBuffer) -> Void, onAudio: @escaping (CMSampleBuffer, AVCaptureConnection) -> Void) {
        self.onVideo = onVideo; self.onAudio = onAudio
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from conn: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput { onVideo(sb) }
        else if output is AVCaptureAudioDataOutput { onAudio(sb, conn) }
    }
}

private final class CanvasCameraCaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let deviceId: String
    let compositor: MetalCompositor

    nonisolated(unsafe) var lastFrameTime: CFAbsoluteTime = 0

    init(deviceId: String, compositor: MetalCompositor) {
        self.deviceId = deviceId
        self.compositor = compositor
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from conn: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let mirrored = conn.isVideoMirrored
        compositor.feedExtraCameraFrame(pb, deviceId: deviceId, mirrored: mirrored)
        lastFrameTime = CFAbsoluteTimeGetCurrent()
    }
}

// MARK: - Screen Frame Output

private class ScreenFrameOutput: NSObject, SCStreamOutput {
    let onScreen: ((CMSampleBuffer) -> Void)?
    let onAudio: ((CMSampleBuffer) -> Void)?

    init(onScreen: ((CMSampleBuffer) -> Void)?, onAudio: ((CMSampleBuffer) -> Void)? = nil) {
        self.onScreen = onScreen
        self.onAudio = onAudio
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            onScreen?(sb)
        case .audio:
            onAudio?(sb)
        @unknown default:
            break
        }
    }
}
