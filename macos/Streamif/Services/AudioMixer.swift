import AVFoundation
import CoreMedia
import Accelerate

final class AudioMixer {
    var onMixedAudio: ((CMSampleBuffer) -> Void)?
    var noiseGateEnabled = false
    var micVolume: Float = 1.0
    var systemVolume: Float = 1.0

    var compressorEnabled = false
    var compressorThreshold: Float = -20.0
    var compressorRatio: Float = 4.0
    var compressorAttack: Float = 0.01
    var compressorRelease: Float = 0.1
    var compressorMakeupGain: Float = 0.0

    var eqEnabled = false
    var eqLowGain: Float = 0.0
    var eqMidGain: Float = 0.0
    var eqHighGain: Float = 0.0

    private let sampleRate: Double = 48000
    private let channels: Int = 2
    private let outputFormat: AVAudioFormat

    private var gateOpen = false
    private var gateGain: Float = 0
    private let gateThreshold: Float = 0.008
    private let gateAttack: Float = 0.002   // fast open
    private let gateRelease: Float = 0.05   // smooth close (avoids choppy cutoffs)

    private var compGainSmoothed: Float = 1.0

    private var eqLowState = (BiquadState(), BiquadState())
    private var eqMidState = (BiquadState(), BiquadState())
    private var eqHighState = (BiquadState(), BiquadState())
    private var eqLowCoeffs = BiquadCoeffs()
    private var eqMidCoeffs = BiquadCoeffs()
    private var eqHighCoeffs = BiquadCoeffs()
    private var lastEqLowGain: Float = .nan
    private var lastEqMidGain: Float = .nan
    private var lastEqHighGain: Float = .nan

    private var micBuffer: [Float] = []
    private var systemBuffer: [Float] = []
    private let lock = NSLock()

    private var micConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?
    private var micInputFormat: AVAudioFormat?
    private var systemInputFormat: AVAudioFormat?
    private var micFormatSet = false
    private var systemFormatSet = false

    private var outputSampleCount: Int64 = 0
    private var baseTime: CMTime = .invalid

    // Drain timer: if one source has data and the other doesn't, don't wait forever
    private var lastMicTime: CFAbsoluteTime = 0
    private var lastSystemTime: CFAbsoluteTime = 0
    private let drainTimeout: CFAbsoluteTime = 0.05
    private let maxBacklogSeconds = 0.15

    private let mixQueue = DispatchQueue(label: "com.streamif.audiomixer", qos: .userInteractive)

    init() {
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        )!
    }

    // MARK: - Input

    func feedMic(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = extractPCM(sampleBuffer, source: .mic) else { return }

        if baseTime == .invalid {
            baseTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        }

        lock.lock()
        micBuffer.append(contentsOf: pcm)
        lastMicTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()

        mixQueue.async { [weak self] in self?.tryMix() }
    }

    func feedSystem(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = extractPCM(sampleBuffer, source: .system) else { return }

        if baseTime == .invalid {
            baseTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        }

        lock.lock()
        systemBuffer.append(contentsOf: pcm)
        lastSystemTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()

        mixQueue.async { [weak self] in self?.tryMix() }
    }

    private enum Source { case mic, system }

    // MARK: - Mixing

    private func tryMix() {
        lock.lock()

        let frameSize = channels
        let minFrames = 1024 * frameSize
        let now = CFAbsoluteTimeGetCurrent()

        let hasMic = micBuffer.count >= minFrames
        let hasSystem = systemBuffer.count >= minFrames
        let micStale = (now - lastMicTime) > drainTimeout && lastMicTime > 0
        let systemStale = (now - lastSystemTime) > drainTimeout && lastSystemTime > 0

        let shouldMix = (hasMic && hasSystem) ||
                        (hasMic && (systemStale || !systemFormatSet)) ||
                        (hasSystem && (micStale || !micFormatSet))

        guard shouldMix else {
            lock.unlock()
            return
        }

        let micAvailable = micBuffer.count
        let systemAvailable = systemBuffer.count

        let count: Int
        if hasMic && hasSystem {
            count = min(micAvailable, systemAvailable)
        } else if hasMic {
            count = micAvailable
        } else {
            count = systemAvailable
        }

        let mixCount = (count / frameSize) * frameSize
        guard mixCount > 0 else {
            lock.unlock()
            return
        }

        var mixed = [Float](repeating: 0, count: mixCount)

        if micBuffer.count >= mixCount {
            var mic = Array(micBuffer.prefix(mixCount))
            micBuffer.removeFirst(mixCount)
            var gain = micVolume
            vDSP_vsmul(mic, 1, &gain, &mic, 1, vDSP_Length(mixCount))
            vDSP_vadd(mixed, 1, mic, 1, &mixed, 1, vDSP_Length(mixCount))
        }

        if systemBuffer.count >= mixCount {
            var sys = Array(systemBuffer.prefix(mixCount))
            systemBuffer.removeFirst(mixCount)
            var gain = systemVolume
            vDSP_vsmul(sys, 1, &gain, &sys, 1, vDSP_Length(mixCount))
            vDSP_vadd(mixed, 1, sys, 1, &mixed, 1, vDSP_Length(mixCount))
        }

        // Mic and system audio run on separate clocks, and mixing takes the smaller of
        // the two, so the faster source's surplus piles up and drifts out of sync.
        trimBacklog(&micBuffer)
        trimBacklog(&systemBuffer)

        lock.unlock()

        if noiseGateEnabled {
            applyNoiseGate(&mixed, count: mixCount)
        }

        if eqEnabled {
            applyEQ(&mixed, count: mixCount)
        }

        if compressorEnabled {
            applyCompressor(&mixed, count: mixCount)
        }

        var minVal: Float = -1.0
        var maxVal: Float = 1.0
        vDSP_vclip(mixed, 1, &minVal, &maxVal, &mixed, 1, vDSP_Length(mixCount))

        let frameCount = mixCount / channels
        if let sb = makeSampleBuffer(from: mixed, frameCount: frameCount) {
            onMixedAudio?(sb)
        }
    }

    private func trimBacklog(_ buffer: inout [Float]) {
        let maxSamples = Int(sampleRate * maxBacklogSeconds) * channels
        guard buffer.count > maxSamples else {
            return
        }
        buffer.removeFirst(buffer.count - maxSamples)
    }

    // MARK: - Noise Gate

    private func applyNoiseGate(_ samples: inout [Float], count: Int) {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))

        let target: Float = rms > gateThreshold ? 1.0 : 0.0
        let smoothing = target > gateGain ? gateAttack : gateRelease

        // Ramp the gain per sample to avoid clicks
        let samplesToProcess = count
        for i in 0..<samplesToProcess {
            gateGain += (target - gateGain) * smoothing
            samples[i] *= gateGain
        }
    }

    // MARK: - PCM Extraction

    private func extractPCM(_ sampleBuffer: CMSampleBuffer, source: Source) -> [Float]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        var asbd = asbdPtr.pointee
        guard let srcFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        // Build or rebuild the converter when the upstream format first appears or changes.
        // Some virtual devices renegotiate mid-stream, and a cached AVAudioConverter fed a
        // mismatched buffer trips its FillComplexProc isEqual: assertion.
        let cachedFormat = source == .mic ? micInputFormat : systemInputFormat
        if cachedFormat == nil || !cachedFormat!.isEqual(srcFormat) {
            let isDirectMatch = srcFormat.sampleRate == sampleRate &&
                srcFormat.channelCount == AVAudioChannelCount(channels) &&
                srcFormat.commonFormat == .pcmFormatFloat32 &&
                srcFormat.isInterleaved
            let conv: AVAudioConverter? = isDirectMatch ? nil : AVAudioConverter(from: srcFormat, to: outputFormat)
            if !isDirectMatch && conv == nil { return nil }
            switch source {
            case .mic:
                micConverter = conv
                micInputFormat = srcFormat
                micFormatSet = true
            case .system:
                systemConverter = conv
                systemInputFormat = srcFormat
                systemFormatSet = true
            }
        }

        guard let inputPCM = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return nil }
        inputPCM.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount),
            into: inputPCM.mutableAudioBufferList
        )
        guard status == noErr else { return nil }

        let converter = source == .mic ? micConverter : systemConverter
        let outputPCM: AVAudioPCMBuffer
        if let converter {
            let ratio = sampleRate / converter.inputFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else { return nil }

            var consumed = false
            var error: NSError?
            let convStatus = converter.convert(to: out, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return inputPCM
            }
            guard convStatus != .error, out.frameLength > 0 else { return nil }
            outputPCM = out
        } else {
            outputPCM = inputPCM
        }

        let totalSamples = Int(outputPCM.frameLength) * channels
        guard let floatData = outputPCM.floatChannelData else { return nil }

        var result: [Float]
        if outputPCM.format.isInterleaved {
            result = Array(UnsafeBufferPointer(start: floatData[0], count: totalSamples))
        } else {
            result = [Float](repeating: 0, count: totalSamples)
            for ch in 0..<channels {
                for i in 0..<Int(outputPCM.frameLength) {
                    result[i * channels + ch] = floatData[ch][i]
                }
            }
        }

        if source == .mic {
            centerMono(&result)
        }
        return result
    }

    // Mono mics, and interfaces with the mic on input 1, arrive with signal on the left
    // channel only. Collapse to mono and write it to both channels so the voice is centered.
    // When one side is effectively silent use the live side alone, so the level doesn't
    // drop 6dB from averaging with silence.
    private func centerMono(_ samples: inout [Float]) {
        guard channels == 2 else {
            return
        }
        let frames = samples.count / 2
        guard frames > 0 else {
            return
        }

        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            left[i] = samples[i * 2]
            right[i] = samples[i * 2 + 1]
        }

        var leftRMS: Float = 0
        var rightRMS: Float = 0
        vDSP_rmsqv(left, 1, &leftRMS, vDSP_Length(frames))
        vDSP_rmsqv(right, 1, &rightRMS, vDSP_Length(frames))

        let silenceRatio: Float = 0.03
        var mono: [Float]
        if rightRMS < leftRMS * silenceRatio {
            mono = left
        } else if leftRMS < rightRMS * silenceRatio {
            mono = right
        } else {
            mono = [Float](repeating: 0, count: frames)
            var half: Float = 0.5
            vDSP_vasm(left, 1, right, 1, &half, &mono, 1, vDSP_Length(frames))
        }

        for i in 0..<frames {
            samples[i * 2] = mono[i]
            samples[i * 2 + 1] = mono[i]
        }
    }

    // MARK: - Output

    private func makeSampleBuffer(from samples: [Float], frameCount: Int) -> CMSampleBuffer? {
        guard !samples.isEmpty else { return nil }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard let formatDesc else { return nil }

        let pts = CMTimeAdd(baseTime, CMTime(value: outputSampleCount, timescale: Int32(sampleRate)))
        outputSampleCount += Int64(frameCount)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let dataSize = samples.count * MemoryLayout<Float>.size

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard let blockBuffer else { return nil }

        _ = samples.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
        }

        var sampleSize = channels * MemoryLayout<Float>.size
        CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }

    func reset() {
        lock.lock()
        micBuffer.removeAll()
        systemBuffer.removeAll()
        lock.unlock()
        outputSampleCount = 0
        baseTime = .invalid
        micConverter = nil
        systemConverter = nil
        micInputFormat = nil
        systemInputFormat = nil
        micFormatSet = false
        systemFormatSet = false
        compGainSmoothed = 1.0
        eqLowState = (BiquadState(), BiquadState())
        eqMidState = (BiquadState(), BiquadState())
        eqHighState = (BiquadState(), BiquadState())
        lastEqLowGain = .nan
        lastEqMidGain = .nan
        lastEqHighGain = .nan
    }

    // MARK: - 3-Band EQ (Biquad Filters)

    private func applyEQ(_ samples: inout [Float], count: Int) {
        let sr = Float(sampleRate)

        if eqLowGain != lastEqLowGain {
            eqLowCoeffs = BiquadCoeffs.lowShelf(frequency: 200, gainDB: eqLowGain, sampleRate: sr)
            lastEqLowGain = eqLowGain
        }
        if eqMidGain != lastEqMidGain {
            eqMidCoeffs = BiquadCoeffs.peaking(frequency: 1000, gainDB: eqMidGain, q: 1.0, sampleRate: sr)
            lastEqMidGain = eqMidGain
        }
        if eqHighGain != lastEqHighGain {
            eqHighCoeffs = BiquadCoeffs.highShelf(frequency: 5000, gainDB: eqHighGain, sampleRate: sr)
            lastEqHighGain = eqHighGain
        }

        let frames = count / channels
        for i in 0..<frames {
            let idx = i * channels

            var s = samples[idx]
            s = eqLowCoeffs.process(sample: s, state: &eqLowState.0)
            s = eqMidCoeffs.process(sample: s, state: &eqMidState.0)
            s = eqHighCoeffs.process(sample: s, state: &eqHighState.0)
            samples[idx] = s

            if channels > 1 {
                var r = samples[idx + 1]
                r = eqLowCoeffs.process(sample: r, state: &eqLowState.1)
                r = eqMidCoeffs.process(sample: r, state: &eqMidState.1)
                r = eqHighCoeffs.process(sample: r, state: &eqHighState.1)
                samples[idx + 1] = r
            }
        }
    }

    // MARK: - Compressor

    private func applyCompressor(_ samples: inout [Float], count: Int) {
        let thresholdLinear = powf(10.0, compressorThreshold / 20.0)
        let ratio = max(compressorRatio, 1.0)
        let makeupLinear = powf(10.0, compressorMakeupGain / 20.0)
        let attackCoeff = expf(-1.0 / (Float(sampleRate) * compressorAttack))
        let releaseCoeff = expf(-1.0 / (Float(sampleRate) * compressorRelease))

        for i in 0..<count {
            let input = samples[i]
            let level = abs(input)

            var targetGain: Float = 1.0
            if level > thresholdLinear {
                let overDB = 20.0 * log10f(level / thresholdLinear)
                let compressedOverDB = overDB / ratio
                targetGain = thresholdLinear * powf(10.0, compressedOverDB / 20.0) / max(level, 1e-10)
            }

            let coeff = targetGain < compGainSmoothed ? attackCoeff : releaseCoeff
            compGainSmoothed = coeff * compGainSmoothed + (1.0 - coeff) * targetGain

            samples[i] = input * compGainSmoothed * makeupLinear
        }
    }
}

// MARK: - Biquad Filter Types

struct BiquadState {
    var x1: Float = 0, x2: Float = 0
    var y1: Float = 0, y2: Float = 0
}

struct BiquadCoeffs {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0
    var a1: Float = 0, a2: Float = 0

    mutating func process(sample x0: Float, state s: inout BiquadState) -> Float {
        let y0 = b0 * x0 + b1 * s.x1 + b2 * s.x2 - a1 * s.y1 - a2 * s.y2
        s.x2 = s.x1; s.x1 = x0
        s.y2 = s.y1; s.y1 = y0
        return y0
    }

    static func lowShelf(frequency: Float, gainDB: Float, sampleRate: Float) -> BiquadCoeffs {
        let A = powf(10.0, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * frequency / sampleRate
        let cosw0 = cosf(w0)
        let sinw0 = sinf(w0)
        let alpha = sinw0 / 2.0 * sqrtf(2.0)
        let sqrtA2alpha = 2.0 * sqrtf(A) * alpha

        let a0 = (A + 1) + (A - 1) * cosw0 + sqrtA2alpha
        return BiquadCoeffs(
            b0: A * ((A + 1) - (A - 1) * cosw0 + sqrtA2alpha) / a0,
            b1: 2.0 * A * ((A - 1) - (A + 1) * cosw0) / a0,
            b2: A * ((A + 1) - (A - 1) * cosw0 - sqrtA2alpha) / a0,
            a1: -2.0 * ((A - 1) + (A + 1) * cosw0) / a0,
            a2: ((A + 1) + (A - 1) * cosw0 - sqrtA2alpha) / a0
        )
    }

    static func highShelf(frequency: Float, gainDB: Float, sampleRate: Float) -> BiquadCoeffs {
        let A = powf(10.0, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * frequency / sampleRate
        let cosw0 = cosf(w0)
        let sinw0 = sinf(w0)
        let alpha = sinw0 / 2.0 * sqrtf(2.0)
        let sqrtA2alpha = 2.0 * sqrtf(A) * alpha

        let a0 = (A + 1) - (A - 1) * cosw0 + sqrtA2alpha
        return BiquadCoeffs(
            b0: A * ((A + 1) + (A - 1) * cosw0 + sqrtA2alpha) / a0,
            b1: -2.0 * A * ((A - 1) + (A + 1) * cosw0) / a0,
            b2: A * ((A + 1) + (A - 1) * cosw0 - sqrtA2alpha) / a0,
            a1: 2.0 * ((A - 1) - (A + 1) * cosw0) / a0,
            a2: ((A + 1) - (A - 1) * cosw0 - sqrtA2alpha) / a0
        )
    }

    static func peaking(frequency: Float, gainDB: Float, q: Float, sampleRate: Float) -> BiquadCoeffs {
        let A = powf(10.0, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * frequency / sampleRate
        let cosw0 = cosf(w0)
        let sinw0 = sinf(w0)
        let alpha = sinw0 / (2.0 * q)

        let a0 = 1.0 + alpha / A
        return BiquadCoeffs(
            b0: (1.0 + alpha * A) / a0,
            b1: (-2.0 * cosw0) / a0,
            b2: (1.0 - alpha * A) / a0,
            a1: (-2.0 * cosw0) / a0,
            a2: (1.0 - alpha / A) / a0
        )
    }
}
