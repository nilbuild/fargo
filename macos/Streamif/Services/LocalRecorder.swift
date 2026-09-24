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

    // The audio input refuses buffers while the writer waits on video to interleave.
    // Held here and appended once it's ready, rather than dropped.
    private var pendingAudio: [CMSampleBuffer] = []
    private let maxPendingAudio = 500

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
            // Without fragments the index is written only at the end, so a crash or
            // force quit leaves a file nothing can open.
            writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: 3840,
                AVVideoHeightKey: 2160,
                AVVideoCompressionPropertiesKey: [
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel,
                    // Do not add AVVideoQualityKey next to this. Setting both makes the
                    // encoder silently ignore the bitrate target. Quality 1.0 alone ran
                    // past 1 Gbps on screen content, backing up the writer (which then
                    // refused audio) and filling the disk.
                    AVVideoAverageBitRateKey: 60_000_000,
                    AVVideoExpectedSourceFrameRateKey: 60,
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

    func stop(completion: (() -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording else {
            completion?()
            return
        }
        isRecording = false

        flushPendingAudio()
        pendingAudio.removeAll()
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        let writer = assetWriter
        assetWriter = nil
        videoWriterInput = nil
        audioWriterInput = nil
        recordingStartTime = nil

        guard let writer else {
            completion?()
            return
        }
        writer.finishWriting {
            print("[Streamif] Recording saved")
            completion?()
        }
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
        flushPendingAudio()
    }

    func writeAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording,
              assetWriter?.status == .writing,
              recordingStartTime != nil else { return }

        pendingAudio.append(sampleBuffer)
        if pendingAudio.count > maxPendingAudio {
            pendingAudio.removeFirst(pendingAudio.count - maxPendingAudio)
        }
        flushPendingAudio()
    }

    private func flushPendingAudio() {
        guard assetWriter?.status == .writing, let input = audioWriterInput else {
            return
        }
        var appended = 0
        while appended < pendingAudio.count && input.isReadyForMoreMediaData {
            if !input.append(pendingAudio[appended]) {
                break
            }
            appended += 1
        }
        pendingAudio.removeFirst(appended)
    }
}
