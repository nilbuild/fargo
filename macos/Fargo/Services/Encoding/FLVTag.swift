import Foundation
import CoreMedia

enum FLVTag {

    // MARK: - Video Tags (H.264/AVC)

    static func avcSequenceHeader(sps: Data, pps: Data) -> Data {
        var data = Data()

        // FLV video tag header: frame type 1 (keyframe) << 4 | codec ID 7 (AVC)
        data.append(0x17)

        // AVC packet type: 0 = sequence header
        data.append(0x00)

        // Composition time offset: 0 (3 bytes, big-endian)
        data.append(contentsOf: [0x00, 0x00, 0x00])

        // AVC decoder configuration record
        data.append(0x01) // configurationVersion
        data.append(sps.count > 1 ? sps[1] : 0x64) // AVCProfileIndication (High)
        data.append(sps.count > 2 ? sps[2] : 0x00) // profile_compatibility
        data.append(sps.count > 3 ? sps[3] : 0x1F) // AVCLevelIndication
        data.append(0xFF) // lengthSizeMinusOne = 3 (4-byte NAL length)

        // SPS
        data.append(0xE1) // numOfSequenceParameterSets = 1 (5 bits, upper 3 reserved as 1)
        data.append(UInt8((sps.count >> 8) & 0xFF)) // spsLength (big-endian)
        data.append(UInt8(sps.count & 0xFF))
        data.append(sps)

        // PPS
        data.append(0x01) // numOfPictureParameterSets = 1
        data.append(UInt8((pps.count >> 8) & 0xFF)) // ppsLength (big-endian)
        data.append(UInt8(pps.count & 0xFF))
        data.append(pps)

        return data
    }

    static func avcNALU(sampleBuffer: CMSampleBuffer, isKeyframe: Bool, compositionTimeMs: Int32 = 0) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var data = Data()

        // FLV video tag header
        let frameType: UInt8 = isKeyframe ? 0x17 : 0x27 // key=1, inter=2 << 4 | codec=7
        data.append(frameType)

        // AVC packet type: 1 = NAL unit
        data.append(0x01)

        // Composition time offset (3 bytes, big-endian, signed)
        let cts = compositionTimeMs
        data.append(UInt8((cts >> 16) & 0xFF))
        data.append(UInt8((cts >> 8) & 0xFF))
        data.append(UInt8(cts & 0xFF))

        // The NAL units are already in AVCC format with 4-byte length prefixes
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                                  totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer else { return nil }

        data.append(Data(bytes: dataPointer, count: length))

        return data
    }

    static func avcEndOfSequence() -> Data {
        var data = Data()
        data.append(0x17) // keyframe + AVC
        data.append(0x02) // AVC end of sequence
        data.append(contentsOf: [0x00, 0x00, 0x00]) // composition time
        return data
    }

    // MARK: - Audio Tags (AAC)

    static func aacSequenceHeader(sampleRate: Int, channels: Int) -> Data {
        var data = Data()

        // FLV audio tag header: format 10 (AAC) << 4 | rate index << 2 | 16-bit << 1 | stereo
        let rateIndex: UInt8 = sampleRate >= 44100 ? 3 : (sampleRate >= 22050 ? 2 : (sampleRate >= 11025 ? 1 : 0))
        data.append(0xA0 | (rateIndex << 2) | 0x02 | (channels > 1 ? 0x01 : 0x00))

        // AAC packet type: 0 = sequence header
        data.append(0x00)

        // AudioSpecificConfig (2 bytes)
        let asc = audioSpecificConfig(sampleRate: sampleRate, channels: channels)
        data.append(asc)

        return data
    }

    static func aacRawFrame(data audioData: Data, sampleRate: Int, channels: Int) -> Data {
        var data = Data()

        // FLV audio tag header, same layout as the sequence header
        let rateIndex: UInt8 = sampleRate >= 44100 ? 3 : (sampleRate >= 22050 ? 2 : (sampleRate >= 11025 ? 1 : 0))
        data.append(0xA0 | (rateIndex << 2) | 0x02 | (channels > 1 ? 0x01 : 0x00))

        // AAC packet type: 1 = raw
        data.append(0x01)

        // Raw AAC frame, no ADTS header
        data.append(audioData)

        return data
    }

    // MARK: - AudioSpecificConfig

    static func audioSpecificConfig(sampleRate: Int, channels: Int) -> Data {
        // 5 bits object type, 4 bits sample rate index, 4 bits channel config, padded to 2 bytes

        let objectType: UInt8 = 2 // AAC-LC

        let freqIndex: UInt8 = {
            switch sampleRate {
            case 96000: return 0
            case 88200: return 1
            case 64000: return 2
            case 48000: return 3
            case 44100: return 4
            case 32000: return 5
            case 24000: return 6
            case 22050: return 7
            case 16000: return 8
            case 12000: return 9
            case 11025: return 10
            case 8000:  return 11
            default:    return 4 // default to 44.1kHz
            }
        }()

        let channelConfig = UInt8(min(channels, 7))

        // Pack into 2 bytes: [TTTTTFFF] [FCCCC000]
        let byte0 = (objectType << 3) | (freqIndex >> 1)
        let byte1 = (freqIndex << 7) | (channelConfig << 3)

        return Data([byte0, byte1])
    }
}
