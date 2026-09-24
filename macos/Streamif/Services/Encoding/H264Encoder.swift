import VideoToolbox
import CoreMedia
import CoreVideo

final class H264Encoder {
    var onEncodedFrame: ((CMSampleBuffer, Bool) -> Void)?

    private(set) var sps: Data?
    private(set) var pps: Data?

    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private var bitrate: Int
    private var keyframeInterval: Double
    private let profileLevel: CFString

    private var targetFPS: Int
    private var lastEncodedTime: CMTime = .invalid
    private let minFrameInterval: Double
    private var forceNextKeyframe = false
    private var usesConstantBitRate = false

    private let encodingQueue = DispatchQueue(label: "com.streamif.h264encoder", qos: .userInitiated)

    init(
        width: Int,
        height: Int,
        bitrate: Int,
        fps: Int = 30,
        keyframeInterval: Double = 2.0,
        profileLevel: CFString = kVTProfileLevel_H264_High_AutoLevel
    ) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.bitrate = bitrate
        self.targetFPS = fps
        self.keyframeInterval = keyframeInterval
        self.profileLevel = profileLevel
        self.minFrameInterval = 1.0 / Double(fps)

        createSession()
    }

    deinit {
        invalidate()
    }

    // MARK: - Session Lifecycle

    private func createSession() {
        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            print("[H264Encoder] Failed to create session: \(status)")
            return
        }

        self.session = session
        applyProperties()

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepareStatus != noErr {
            print("[H264Encoder] Failed to prepare: \(prepareStatus)")
        }
    }

    private func applyProperties() {
        guard let session else { return }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel)

        // Platforms ask for CBR: a steady rate keeps ingest buffers from underrunning on
        // static scenes and spiking on scene changes. Apple Silicon supports it; other
        // encoders refuse the key and get an average rate with a burst cap.
        usesConstantBitRate = VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_ConstantBitRate, value: bitrate as CFNumber
        ) == noErr
        if !usesConstantBitRate {
            applyAverageBitRate(bitrate)
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: keyframeInterval as CFNumber)

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: Double(targetFPS) as CFNumber)

        // B-frames are off. They make DTS and PTS non-monotonic, which RTMP
        // ingest servers reject.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                             value: kCFBooleanTrue)
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        sps = nil
        pps = nil
    }

    // MARK: - Encoding

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session else { return }

        if lastEncodedTime.isValid {
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(presentationTime, lastEncodedTime))
            if elapsed < minFrameInterval * 0.8 {
                return
            }
        }
        lastEncodedTime = presentationTime

        var infoFlags = VTEncodeInfoFlags()

        var frameProps: CFDictionary? = nil
        if forceNextKeyframe {
            forceNextKeyframe = false
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: CMTime(value: 1, timescale: Int32(targetFPS)),
            frameProperties: frameProps,
            infoFlagsOut: &infoFlags
        ) { [weak self] status, flags, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            self.handleEncodedFrame(sampleBuffer)
        }

        if status != noErr {
            print("[H264Encoder] Encode failed: \(status)")
        }
    }

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
                isKeyframe = !notSync
            }
        }

        if isKeyframe {
            extractParameterSets(from: sampleBuffer)
        }

        onEncodedFrame?(sampleBuffer, isKeyframe)
    }

    // MARK: - SPS/PPS Extraction

    private func extractParameterSets(from sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        var spsSize: Int = 0
        var spsCount: Int = 0
        var spsPointer: UnsafePointer<UInt8>?
        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil
        )
        if spsStatus == noErr, let spsPointer {
            sps = Data(bytes: spsPointer, count: spsSize)
        }

        var ppsSize: Int = 0
        var ppsPointer: UnsafePointer<UInt8>?
        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
        )
        if ppsStatus == noErr, let ppsPointer {
            pps = Data(bytes: ppsPointer, count: ppsSize)
        }
    }

    // MARK: - Runtime Configuration

    func updateBitrate(_ newBitrate: Int) {
        guard let session else { return }
        bitrate = newBitrate
        if usesConstantBitRate {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ConstantBitRate, value: newBitrate as CFNumber)
            return
        }
        applyAverageBitRate(newBitrate)
    }

    private func applyAverageBitRate(_ rate: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: rate as CFNumber)
        let byteLimit = Double(rate) / 8.0 * 2.5
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [byteLimit, 1.0] as CFArray)
    }

    func forceKeyframe() {
        forceNextKeyframe = true
    }
}
