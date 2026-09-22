import CoreMedia
import CoreVideo

protocol StreamOutput: AnyObject {
    var id: UUID { get }
    var destinationName: String { get }
    var connectionState: RTMPClient.ClientState { get }
    var onStateChanged: ((RTMPClient.ClientState) -> Void)? { get set }

    var targetWidth: Int { get }
    var targetHeight: Int { get }

    func connect()
    func disconnect()
    func sendVideo(pixelBuffer: CVPixelBuffer, presentationTime: CMTime)
    func sendAudio(sampleBuffer: CMSampleBuffer)
    func forceKeyframe()

    var streamHealth: RTMPClient.StreamHealth { get }
}

extension RTMPClient: StreamOutput {
    var destinationName: String { config.url }
    var connectionState: ClientState { state }
    var streamHealth: StreamHealth { health }
    var targetWidth: Int { config.width }
    var targetHeight: Int { config.height }
}
