import WebRTC

/// Utility wrapper around a local `RTCVideoTrack` also managing an instance of `VideoCapturer`
public class LocalVideoTrack: VideoTrack, LocalTrack {
    private let videoSource: RTCVideoSource
    internal var capturer: VideoCapturer?
    private let track: RTCVideoTrack

    public enum Capturer {
        case camera, file
    }

    override internal init() {
        let source = ConnectionManager.createVideoSource()

        videoSource = source
        track = ConnectionManager.createVideoTrack(source: source)

        super.init()

        capturer = createCapturer(videoSource: source)
    }

    public static func create(for capturer: Capturer, videoParameters: VideoParameters) -> LocalVideoTrack {
        switch capturer {
        case .camera:
            return LocalCameraVideoTrack(parameters: videoParameters)
        case .file:
            return LocalFileVideoTrack()
        }
    }

    internal func createCapturer(videoSource _: RTCVideoSource) -> VideoCapturer {
        fatalError("Basic LocalVideoTrack does not provide a default capturer")
    }
    
    public var trackID: String { track.trackId }

    public func start() {
        capturer?.startCapture()
    }

    public func stop() {
        capturer?.stopCapture()
    }

    public func enabled() -> Bool {
        return track.isEnabled
    }
    
    public func setEnabled(_ enabled: Bool) {
        track.isEnabled = enabled
    }

    override func rtcTrack() -> RTCMediaStreamTrack {
        return track
    }
}

public class LocalCameraVideoTrack: LocalVideoTrack {
    private let videoParameters: VideoParameters
    
    init(parameters: VideoParameters) {
        self.videoParameters = parameters
    }
    
    override internal func createCapturer(videoSource: RTCVideoSource) -> VideoCapturer {
        return CameraCapturer(videoParameters: videoParameters, delegate: videoSource)
    }

    public func switchCamera() {
        guard let capturer = capturer as? CameraCapturer else {
            return
        }

        capturer.switchCamera()
    }
}

public class LocalFileVideoTrack: LocalVideoTrack {
    override internal func createCapturer(videoSource: RTCVideoSource) -> VideoCapturer {
        return FileCapturer(videoSource)
    }
}
