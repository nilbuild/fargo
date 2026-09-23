import AVFoundation
import CoreMedia
import VideoToolbox

final class LocalRecorder {
    private(set) var isRecording = false

    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var recordingStartTime: CMTime?

    // start/stop run on main while frames arrive on the render and audio queues.
    // AVAssetWriter raises ObjC exceptions on appends after markAsFinished, so all
    // writer access is serialized.
    private let lock = NSLock()

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRecording else { return }

        let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let streamifDir = moviesDir.appendingPathComponent("Streamif")
        try? FileManager.default.createDirectory(at: streamifDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "Streamif_\(formatter.string(from: Date())).mp4"
        let outputURL = streamifDir.appendingPathComponent(filename)

        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: 3840,
                AVVideoHeightKey: 2160,
                AVVideoCompressionPropertiesKey: [
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel,
                    // Do not add AVVideoAverageBitRateKey next to this. Setting both
                    // makes the encoder silently ignore the bitrate target.
                    AVVideoQualityKey: 1.0,
                    AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                ],
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 320_000,
                AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Variable,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true

            guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
                print("[Streamif] Recording error: writer rejected its inputs")
                return
            }
            writer.add(videoInput)
            writer.add(audioInput)

            guard writer.startWriting() else {
                print("[Streamif] Recording error: \(writer.error?.localizedDescription ?? "startWriting failed")")
                return
            }

            assetWriter = writer
            videoWriterInput = videoInput
            audioWriterInput = audioInput
            recordingStartTime = nil
            isRecording = true

            print("[Streamif] Recording 4K HEVC to \(outputURL.path)")
        } catch {
            print("[Streamif] Recording error: \(error)")
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording else { return }
        isRecording = false

        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        let writer = assetWriter
        writer?.finishWriting {
            print("[Streamif] Recording saved")
        }
        assetWriter = nil
        videoWriterInput = nil
        audioWriterInput = nil
        recordingStartTime = nil
    }

    func writeVideo(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording,
              assetWriter?.status == .writing,
              let input = videoWriterInput,
              input.isReadyForMoreMediaData else { return }

        if recordingStartTime == nil {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            recordingStartTime = pts
            assetWriter?.startSession(atSourceTime: pts)
        }

        input.append(sampleBuffer)
    }

    func writeAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording,
              assetWriter?.status == .writing,
              let input = audioWriterInput,
              input.isReadyForMoreMediaData,
              recordingStartTime != nil else { return }

        input.append(sampleBuffer)
    }
}
