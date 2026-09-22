import Foundation
import Testing

@Suite("AAC tags")
struct FLVAudioTagTests {

    // AudioSpecificConfig packs 5 bits of object type, 4 of sample rate index and 4 of
    // channel config into 2 bytes. Wrong shifts decode at the wrong rate instead of failing.
    @Test("AudioSpecificConfig for 48kHz stereo AAC-LC")
    func ascFor48kStereo() {
        #expect(FLVTag.audioSpecificConfig(sampleRate: 48_000, channels: 2) == Data([0x11, 0x90]))
    }

    @Test("AudioSpecificConfig for 44.1kHz mono AAC-LC")
    func ascFor44kMono() {
        #expect(FLVTag.audioSpecificConfig(sampleRate: 44_100, channels: 1) == Data([0x12, 0x08]))
    }

    @Test("AudioSpecificConfig falls back to the 44.1kHz index for unknown rates")
    func ascFallsBackTo44k() {
        let unknown = FLVTag.audioSpecificConfig(sampleRate: 37_000, channels: 2)
        let fallback = FLVTag.audioSpecificConfig(sampleRate: 44_100, channels: 2)

        #expect(unknown == fallback)
    }

    @Test("the AAC sequence header carries the FLV header plus the config")
    func aacSequenceHeaderLayout() {
        let header = FLVTag.aacSequenceHeader(sampleRate: 48_000, channels: 2)

        #expect(header.count == 4)
        // 0xA0 AAC | rate index 3 << 2 | 16-bit sample size | stereo
        #expect(header[0] == 0xAF)
        #expect(header[1] == 0x00, "packet type 0 = sequence header")
        #expect(Data(header.suffix(2)) == FLVTag.audioSpecificConfig(sampleRate: 48_000, channels: 2))
    }

    @Test("mono clears the stereo bit of the FLV audio header")
    func monoClearsStereoBit() {
        let stereo = FLVTag.aacSequenceHeader(sampleRate: 48_000, channels: 2)
        let mono = FLVTag.aacSequenceHeader(sampleRate: 48_000, channels: 1)

        #expect(stereo[0] & 0x01 == 0x01)
        #expect(mono[0] & 0x01 == 0x00)
    }

    @Test("a raw AAC frame is prefixed with a packet-type-1 header")
    func rawFrameLayout() {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let tag = FLVTag.aacRawFrame(data: payload, sampleRate: 48_000, channels: 2)

        #expect(tag.count == payload.count + 2)
        #expect(tag[0] == 0xAF)
        #expect(tag[1] == 0x01, "packet type 1 = raw AAC")
        #expect(Data(tag.suffix(payload.count)) == payload)
    }
}

@Suite("AVC tags")
struct FLVVideoTagTests {

    private let sps = Data([0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9])
    private let pps = Data([0x68, 0xEB, 0xE3, 0xCB])

    @Test("the AVC decoder configuration record matches the AVCC layout")
    func avcSequenceHeaderLayout() {
        let header = FLVTag.avcSequenceHeader(sps: sps, pps: pps)

        let expected = Data([
            0x17,             // keyframe + AVC codec id
            0x00,             // AVC packet type 0 = sequence header
            0x00, 0x00, 0x00, // composition time
            0x01,             // configurationVersion
            0x64,             // profile (from sps[1])
            0x00,             // profile compatibility (sps[2])
            0x1F,             // level (sps[3])
            0xFF,             // lengthSizeMinusOne = 3
            0xE1,             // 1 SPS
            0x00, 0x06,       // SPS length
        ]) + sps + Data([
            0x01,             // 1 PPS
            0x00, 0x04,       // PPS length
        ]) + pps

        #expect(header == expected)
    }

    @Test("SPS and PPS lengths are big-endian 16-bit")
    func parameterSetLengthsAreBigEndian() {
        let longSPS = Data(repeating: 0x42, count: 300)
        let header = FLVTag.avcSequenceHeader(sps: longSPS, pps: pps)

        let spsLength = Int(header[11]) << 8 | Int(header[12])
        #expect(spsLength == 300)

        let ppsLengthOffset = 13 + longSPS.count + 1
        let ppsLength = Int(header[ppsLengthOffset]) << 8 | Int(header[ppsLengthOffset + 1])
        #expect(ppsLength == pps.count)
    }

    @Test("end of sequence is a keyframe tag with packet type 2")
    func endOfSequenceLayout() {
        #expect(FLVTag.avcEndOfSequence() == Data([0x17, 0x02, 0x00, 0x00, 0x00]))
    }
}
