import Vision
import CoreVideo

enum BackgroundMode: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case blur = "Blur"
    case remove = "Remove"

    var id: String { rawValue }
}

final class BackgroundBlur: @unchecked Sendable {
    private let requestHandler = VNSequenceRequestHandler()
    private let segmentationRequest: VNGeneratePersonSegmentationRequest
    private var mode: BackgroundMode = .none

    var blurRadius: CGFloat = 20
    var removalColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
    var skinSmoothingEnabled: Bool = false

    init() {
        segmentationRequest = VNGeneratePersonSegmentationRequest()
        segmentationRequest.qualityLevel = .balanced
        segmentationRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    func setMode(_ newMode: BackgroundMode) {
        mode = newMode
    }

    func setEnabled(_ enabled: Bool) {
        mode = enabled ? .blur : .none
    }

    var enabled: Bool { mode != .none }
    var needsSegmentation: Bool { mode != .none || skinSmoothingEnabled }
    var currentMode: BackgroundMode { mode }

    func segmentationMask(for pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard needsSegmentation else { return nil }

        do {
            try requestHandler.perform([segmentationRequest], on: pixelBuffer)
        } catch {
            return nil
        }

        return segmentationRequest.results?.first?.pixelBuffer
    }
}
