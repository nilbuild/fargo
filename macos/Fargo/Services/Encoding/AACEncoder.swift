import AVFoundation
import CoreMedia

final class AACEncoder {
    var onEncodedFrame: ((Data, CMTime) -> Void)?

    let sampleRate: Int
    let channels: Int
    let bitrate: Int

    private let framesPerAAC: AVAudioFrameCount = 1024

    private let pcmFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat

    private var formatConverter: AVAudioConverter?
    private var aacConverter: AVAudioConverter?
    private var actualInputFormat: AVAudioFormat?
    private var isSetUp = false

    private var pcmBuffer: AVAudioPCMBuffer?
    private var pcmWriteOffset: AVAudioFrameCount = 0

    private var baseTime: CMTime = .invalid
    private var samplesEncoded: Int64 = 0

    init(sampleRate: Int = 48000, channels: Int = 2, bitrate: Int = 160_000) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitrate = bitrate

        self.pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!

        self.outputFormat = AVAudioFormat(
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitrate,
                AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
            ]
        )!
    }

    // MARK: - Encoding

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        if baseTime == .invalid {
            baseTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        }

        if !isSetUp {
            setupConverters(asbd: asbdPtr.pointee)
        }

        guard isSetUp, aacConverter != nil, pcmBuffer != nil else { return }

        guard let inputPCM = makePCMBuffer(from: sampleBuffer) else { return }

        let converted: AVAudioPCMBuffer
        if formatConverter != nil {
            guard let c = convertFormat(inputPCM) else { return }
            converted = c
        } else {
            converted = inputPCM
        }

        appendAndEncode(converted)
    }

    // MARK: - Lazy Setup

    private func setupConverters(asbd: AudioStreamBasicDescription) {
        var mutableASBD = asbd

        guard let srcFormat = AVAudioFormat(streamDescription: &mutableASBD) else {
            print("[AACEncoder] Cannot create AVAudioFormat from microphone ASBD")
            return
        }

        actualInputFormat = srcFormat

        let needsFormatConversion = srcFormat.sampleRate != Double(sampleRate) ||
                                     srcFormat.channelCount != AVAudioChannelCount(channels) ||
                                     srcFormat.commonFormat != .pcmFormatFloat32 ||
                                     srcFormat.isInterleaved

        if needsFormatConversion {
            guard let conv = AVAudioConverter(from: srcFormat, to: pcmFormat) else {
                print("[AACEncoder] Cannot create format converter from \(srcFormat)")
                return
            }
            formatConverter = conv
        }

        guard let aac = AVAudioConverter(from: pcmFormat, to: outputFormat) else {
            print("[AACEncoder] Cannot create AAC converter")
            return
        }
        aac.bitRate = bitrate
        aacConverter = aac

        pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: framesPerAAC * 4)
        pcmWriteOffset = 0
        isSetUp = true

        print("[AACEncoder] Mic format: \(Int(srcFormat.sampleRate))Hz, \(srcFormat.channelCount)ch, interleaved=\(srcFormat.isInterleaved), bits=\(srcFormat.streamDescription.pointee.mBitsPerChannel)")
        print("[AACEncoder] Output: \(sampleRate)Hz, \(channels)ch AAC-LC @ \(bitrate / 1000)kbps" +
              (needsFormatConversion ? " (converting from mic format)" : ""))
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let inputFormat = actualInputFormat else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        guard let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else { return nil }
        pcm.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount),
            into: pcm.mutableAudioBufferList
        )

        if status != noErr {
            return nil
        }

        return pcm
    }

    // MARK: - Format Conversion (resample / channel upmix)

    private func convertFormat(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let formatConverter else { return nil }

        let ratio = Double(sampleRate) / formatConverter.inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1

        guard let output = AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: outputFrameCount
        ) else { return nil }

        var consumed = false
        var error: NSError?
        let status = formatConverter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }

        if status == .error {
            if let error {
                print("[AACEncoder] Format convert error: \(error)")
            }
            return nil
        }

        return output.frameLength > 0 ? output : nil
    }

    // MARK: - Ring Buffer + AAC Encoding

    private func appendAndEncode(_ converted: AVAudioPCMBuffer) {
        guard let pcmBuffer else { return }

        var srcOffset: AVAudioFrameCount = 0
        let totalFrames = converted.frameLength

        while srcOffset < totalFrames {
            let spaceInBuffer = pcmBuffer.frameCapacity - pcmWriteOffset
            let framesToCopy = min(totalFrames - srcOffset, spaceInBuffer)

            if framesToCopy > 0 {
                copyPCMFrames(from: converted, fromOffset: srcOffset, to: pcmBuffer, toOffset: pcmWriteOffset, count: framesToCopy)
                pcmWriteOffset += framesToCopy
                srcOffset += framesToCopy
            }

            while pcmWriteOffset >= framesPerAAC {
                encodeOneFrame()
                let remaining = pcmWriteOffset - framesPerAAC
                if remaining > 0 {
                    copyPCMFrames(from: pcmBuffer, fromOffset: framesPerAAC, to: pcmBuffer, toOffset: 0, count: remaining)
                }
                pcmWriteOffset = remaining
            }
        }
    }

    private func encodeOneFrame() {
        guard let pcmBuffer, let aacConverter else { return }

        guard let inputSlice = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: framesPerAAC) else { return }
        inputSlice.frameLength = framesPerAAC
        copyPCMFrames(from: pcmBuffer, fromOffset: 0, to: inputSlice, toOffset: 0, count: framesPerAAC)

        let outputBuffer = AVAudioCompressedBuffer(
            format: outputFormat,
            packetCapacity: 1,
            maximumPacketSize: 1536
        )

        var consumed = false
        var error: NSError?
        let status = aacConverter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputSlice
        }

        if status == .error {
            if let error {
                print("[AACEncoder] AAC encode error: \(error)")
            }
            return
        }

        if outputBuffer.byteLength > 0 {
            let aacData = Data(bytes: outputBuffer.data, count: Int(outputBuffer.byteLength))
            let pts = CMTimeAdd(baseTime, CMTime(value: samplesEncoded, timescale: Int32(sampleRate)))
            samplesEncoded += Int64(framesPerAAC)
            onEncodedFrame?(aacData, pts)
        }
    }

    // MARK: - PCM Buffer Helpers

    private func copyPCMFrames(
        from src: AVAudioPCMBuffer, fromOffset srcOffset: AVAudioFrameCount,
        to dst: AVAudioPCMBuffer, toOffset dstOffset: AVAudioFrameCount,
        count: AVAudioFrameCount
    ) {
        let channelCount = Int(dst.format.channelCount)
        for ch in 0..<channelCount {
            guard let srcData = src.floatChannelData?[ch],
                  let dstData = dst.floatChannelData?[ch] else { continue }
            memcpy(dstData.advanced(by: Int(dstOffset)),
                   srcData.advanced(by: Int(srcOffset)),
                   Int(count) * MemoryLayout<Float>.size)
        }
        if dstOffset + count > dst.frameLength {
            dst.frameLength = dstOffset + count
        }
    }

    // MARK: - Flush

    func flush() {
        if pcmWriteOffset > 0, let pcmBuffer {
            let remaining = framesPerAAC - pcmWriteOffset
            let channelCount = Int(pcmBuffer.format.channelCount)
            for ch in 0..<channelCount {
                guard let channelData = pcmBuffer.floatChannelData?[ch] else { continue }
                memset(channelData.advanced(by: Int(pcmWriteOffset)), 0, Int(remaining) * MemoryLayout<Float>.size)
            }
            pcmWriteOffset = framesPerAAC
            encodeOneFrame()
            pcmWriteOffset = 0
        }
    }
}
