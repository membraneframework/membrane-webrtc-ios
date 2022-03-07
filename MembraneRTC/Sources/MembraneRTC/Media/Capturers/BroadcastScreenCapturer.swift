import Foundation

import WebRTC

internal func downscaleResolution(from: Dimensions, to: Dimensions) -> Dimensions {
    if from.height > to.height {
        let ratio = Float(from.height) / Float(from.width)
        
        let newHeight = to.height
        let newWidth = Int32((Float(newHeight) / ratio).rounded(.down))
        
        return Dimensions(width: newWidth, height: newHeight)
    } else if from.width > to.width {
        let ratio = Float(from.height) / Float(from.width)
        
        let newWidth = to.width
        let newHeight = Int32((Float(newWidth) * ratio).rounded(.down))
        
        return Dimensions(width: newWidth, height: newHeight)
    }
    
    return from
}

/// Utility for creating a `CVPixelBuffer` from raw bytes.
public extension CVPixelBuffer {
    static func from(_ data: Data, width: Int, height: Int, pixelFormat: OSType) -> CVPixelBuffer {
        data.withUnsafeBytes { buffer in
            var pixelBuffer: CVPixelBuffer!

            let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, nil, &pixelBuffer)
            guard result == kCVReturnSuccess else { fatalError() }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

            var source = buffer.baseAddress!

            for plane in 0 ..< CVPixelBufferGetPlaneCount(pixelBuffer) {
                let dest = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
                let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                let planeSize = height * bytesPerRow

                memcpy(dest, source, planeSize)
                source += planeSize
            }

            return pixelBuffer
        }
    }
}

internal protocol BroadcastScreenCapturerDelegate: AnyObject {
    func started()
    func stopped()
    func paused()
    func resumed()
}

/// `VideoCapturer` that is responsible for capturing media from a remote `Broadcast Extension` that sends samples
/// via `IPC` mechanism.
///
/// The capturer works in a `Server` mode, receiving appropriate notifications/samples from the extension that is working in a `Client` mode.
/// The expected behaviour is to start the capturer prior to starting the extension as the server is responsible for opening the `IPC` port first.
/// If the client starts before the server it will automatically close as the port will be closed.
///
/// The communication is performed by using `Proto Buffers` to gracefully handle serialization and deserialization of raw bytes sent via IPC port.
class BroadcastScreenCapturer: RTCVideoCapturer, VideoCapturer {
    public weak var capturerDelegate: BroadcastScreenCapturerDelegate?

    private let videoParameters: VideoParameters
    private let appGroup: String
    private let ipcServer: IPCServer
    private let source: RTCVideoSource
    private var started = false
    private var isReceivingSamples: Bool = false

    private var timeoutTimer: Timer?

    internal let supportedPixelFormats = DispatchQueue.webRTC.sync { RTCCVPixelBuffer.supportedPixelFormats() }

    init(_ source: RTCVideoSource, appGroup: String, videoParameters: VideoParameters, delegate: BroadcastScreenCapturerDelegate? = nil) {
        self.source = source
        self.appGroup = appGroup
        self.videoParameters = videoParameters
        
        capturerDelegate = delegate
        ipcServer = IPCServer()

        super.init(delegate: source)

        // check every 2 seconds if the screensharing is still active or crashed
        // this is needed as we can't know if the IPC Client stopped working or not, so at least
        // we can check that that we receiving some samples
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            // NOTE: there is basically no way of telling if the user has still
            // an opened RPSystemBroadcastPickerView, but we can assume that if the application
            // is in inactive state then this is a case therefore ignore the timeoutTimer tick
            if UIApplication.shared.applicationState == .inactive {
                return
            }

            if !self.isReceivingSamples {
                self.capturerDelegate?.stopped()
                timer.invalidate()
                return
            }

            self.isReceivingSamples = false
        }

        ipcServer.onReceive = { [weak self] _, _, data in
            guard
                let self = self,
                let sample = try? BroadcastMessage(serializedData: data)
            else {
                return
            }

            switch sample.type {
            case let .notification(notification):
                switch notification {
                case .started:
                    sdkLogger.info("BroadcastScreenCapturer has been started")
                    self.capturerDelegate?.started()
                    self.started = true
                case .finished:
                    sdkLogger.info("BroadcastScreenCapturer has been stopped")
                    self.capturerDelegate?.stopped()
                case .paused:
                    sdkLogger.info("BroadcastScreenCapturer has been paused")
                    self.capturerDelegate?.paused()
                case .resumed:
                    sdkLogger.info("BroadcastScreenCapturer has been resumed")
                    self.capturerDelegate?.resumed()
                default:
                    break
                }

            case let .video(video):
                if !self.started {
                    fatalError("Started receiving video samples without `started` notificcation...")
                }

                self.isReceivingSamples = true

                let dimensions = downscaleResolution(from: Dimensions(width: Int32(video.width), height: Int32(video.height)), to: videoParameters.dimensions)
                
                self.source.adaptOutputFormat(toWidth: dimensions.width, height: dimensions.height, fps: Int32(videoParameters.encoding.maxFps))

                let pixelBuffer = CVPixelBuffer.from(sample.buffer, width: Int(video.width), height: Int(video.height), pixelFormat: video.format)
                let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
                let width = Int32(CVPixelBufferGetWidth(pixelBuffer))

                let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer,
                                                 adaptedWidth: width,
                                                 adaptedHeight: height,
                                                 cropWidth: width,
                                                 cropHeight: height,
                                                 cropX: 0,
                                                 cropY: 0)

                var rotation: RTCVideoRotation = ._0

                switch video.rotation {
                case 90:
                    rotation = ._90
                case 180:
                    rotation = ._180
                case 270:
                    rotation = ._270
                default:
                    break
                }

                // NOTEe: somehow local Metal renderer for RTCVPixelBuffer does not render the video
                // the I420 somehow does so keep it in that format as long as it works
                let buffer = rtcBuffer.toI420()
                let videoFrame = RTCVideoFrame(buffer: buffer, rotation: rotation, timeStampNs: sample.timestamp)

                let delegate = source as RTCVideoCapturerDelegate

                delegate.capturer(self, didCapture: videoFrame)

            default:
                break
            }
        }
    }

    public func startCapture() {
        guard ipcServer.listen(for: appGroup) else {
            fatalError("Failed to open IPC for screen broadcast, make sure that both app and extension are using same App Group")
        }
    }

    public func stopCapture() {
        ipcServer.close()
        ipcServer.dispose()
    }
}
