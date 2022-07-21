import Logging
import WebRTC

internal var sdkLogger = Logger(label: "org.membrane.ios")
internal let pcLogPrefix = "[PeerConnection]"


/**
 MembraneRTC client.

 The client is responsible for relaying MembraneRTC Engine specific messages through given reliable transport layer.
 Once initialized, the client is responsbile for exchaning necessary messages via provided `EventTransport` and managing underlying
 `RTCPeerConnection`. The goal of the client is to be as lean as possible, meaning that all activies regarding the session such as moderating
 should be implemented by the user himself on top of the `MembraneRTC`.

 The user's ability of interacting with the client is greatly liimited to the essential actions such as joining/leaving the session,
 adding/removing local tracks and receiving information about remote peers and their tracks that can be played by the user.

 User can request 3 different types of local tracks that will get forwareded to the server by the client:
 - `LocalAudioTrack` - an audio track utilizing device's microphone
 - `LocalVideoTrack` - a video track that can utilize device's camera or if necessay use video playback from a file (useful for testing with a simulator)
 - `LocalBroadcastScreenTrack` - a screencast track taking advantage of `Broadcast Upload Extension` to record device's screen even if the app is minimized

 It is recommended to request necessary audio and video tracks before joining the room but it does not mean it can't be done afterwards (in case of screencast)

 Once the user received `onConnected` notification they can call the `join` method to initialize joining the session.
 After receiving `onJoinSuccess` a user will receive notification about various peers joining/leaving the session, new tracks being published and ready for playback
 or going inactive.
 */
public class MembraneRTC: MulticastDelegate<MembraneRTCDelegate>, ObservableObject {
    static let version = "0.1.0"

    enum State {
        case uninitialized
        case awaitingJoin
        case connected
        case disconnected
    }

    public struct ConnectOptions {
        let transport: EventTransport
        let config: Metadata

        public init(transport: EventTransport, config: Metadata) {
            self.transport = transport
            self.config = config
        }
    }

    var state: State
    private var transport: EventTransport
    
    // a common stream ID used for all non-screenshare and audio tracks
    private let localStreamId = UUID().uuidString

    // `RTCPeerConnection` config
    private var config: RTCConfiguration

    // Underyling RTC connection
    private var connection: RTCPeerConnection?

    // List of ice (may be turn) servers that are used for initializing the `RTCPeerConnection`
    private var iceServers: [RTCIceServer]

    private var localTracks: [LocalTrack] = []

    private var localPeer = Peer(id: "", metadata: [:], trackIdToMetadata: [:])

    // mapping from peer's id to itself
    private var remotePeers: [String: Peer] = [:]

    // mapping from remote track's id to its context
    private var trackContexts: [String: TrackContext] = [:]

    // mapping from transceiver's mid to its remote track id
    private var midToTrackId: [String: String] = [:]

    // receiver used for iOS screen broadcast
    private var broadcastScreenshareReceiver: ScreenBroadcastNotificationReceiver?

    private static let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])

    internal init(eventTransport: EventTransport, config: RTCConfiguration, peerMetadata: Metadata) {
        // RTCSetMinDebugLogLevel(.error)
        sdkLogger.logLevel = .info

        state = .uninitialized
        transport = eventTransport
        self.config = config
        iceServers = []

        // setup local peer
        localPeer = localPeer.with(metadata: peerMetadata)

        super.init()
    }

    /**
     Initializes the connection with the `Membrane RTC Engine` transport layer
     and sets up local audio and video track.
 
     Should not be confused with joining the actual room, which is a separate process.
 
     - Parameters:
        - with: Connection options, consists of an `EventTransport` instance that will be used for relaying media events and arbitrary `config` metadata used by `Membrane RTC Engine` for connection
        - delegate: The delegate that will receive all notification emitted by `MembraneRTC` client
 
     -  Returns: `MembraneRTC` client instance in connecting state
     */
    public static func connect(with options: ConnectOptions, delegate: MembraneRTCDelegate) -> MembraneRTC {
        let client = MembraneRTC(eventTransport: options.transport, config: RTCConfiguration(), peerMetadata: options.config)

        client.add(delegate: delegate)
        client.connect()

        return client
    }

    // Default ICE server when no turn servers are specified
    private static func defaultIceServer() -> RTCIceServer {
        let iceUrl = "stun:stun.l.google.com:19302"

        return RTCIceServer(urlStrings: [iceUrl])
    }

    /// Initiaites join process once the client has successfully connected.
    ///
    /// Once completed either `onJoinSuccess` or `onJoinError` of client's delegate gets invovked.
    public func join() {
        guard state == .awaitingJoin else {
            return
        }
        
        transport.send(event: JoinEvent(metadata: localPeer.metadata))
    }


    /// Disconnects from the `Membrane RTC Engine` transport and closes the exisitng `RTCPeerConnection`
    ///
    /// Once the `disconnect` gets invoked the client can't be reused and user should create a new client instance instead.
    public func disconnect() {
        transport.disconnect()

        localTracks.forEach { track in
            track.stop()
        }
        
        if let pc = connection {
            pc.close()
        }
    }
    
    /**
     Creates a new video track utilizing device's camera.
 
     The client assumes that app user already granted camera access permissions.
 
     - Parameters:
        - videoParameters: The parameters used for choosing the proper camera resolution and target framerate
        - metadata: The metadata that will be sent to the `Membrane RTC Engine` for media negotiation
 
     - Returns: `LocalCameraVideoTrack` instance that user then can use for things such as front / back camera switch.
     */
    public func createVideoTrack(videoParameters: VideoParameters, metadata: Metadata) -> LocalVideoTrack {
        let videoTrack = LocalVideoTrack.create(for: .camera, videoParameters: videoParameters)
        
        if state == .connected {
            connection?.add(videoTrack.rtcTrack(), streamIds: [localStreamId])
            connection?.enforceSendOnlyDirection()
        }
        
        videoTrack.start()
        
        localTracks.append(videoTrack)
        
        localPeer = localPeer.withTrack(trackId: videoTrack.rtcTrack().trackId, metadata: metadata)
        
        if state == .connected {
            transport.send(event: RenegotiateTracksEvent())
        }
        
        return videoTrack
    }
    

    /**
     Creates a new audio track utilizing device's microphone.
 
     The client assumes that app user already granted microphone access permissions.
 
     - Parameters:
        - metadata: The metadata that will be sent to the `Membrane RTC Engine` for media negotiation
 
     - Returns: `LocalAudioTrack` instance that user then can use for things such as front / back camera switch.
     */
    public func createAudioTrack(metadata: Metadata) -> LocalAudioTrack {
        let audioTrack = LocalAudioTrack()
        
        if state == .connected {
            connection?.add(audioTrack.rtcTrack(), streamIds: [localStreamId])
            connection?.enforceSendOnlyDirection()
        }
        
        audioTrack.start()
        
        localTracks.append(audioTrack)
        
        localPeer = localPeer.withTrack(trackId: audioTrack.rtcTrack().trackId, metadata: metadata)
        
        if state == .connected {
            transport.send(event: RenegotiateTracksEvent())
        }
        
        return audioTrack
    }
    
    /**
     Creates a screencast track capturing the entire device's screen.
     
     The track starts listening for a media sent from a custom  `Broadcast Upload Extension`.  For more information
     please refer to `LocalBroadcastScreenTrack` for more information.
     
     The nature of upload extension is asynchronous due to the way that iOS handle broadcasting the screen. The app user
     may be hanging on start broadcast screen therefore there is no consistent synchronous way of telling if the broadcast started.
     
     - Parameters:
        - appGroup: The App Group identifier shared by the application  with a target `Broadcast Upload Extension`
        - videoParameters: The parameters used for limiting the screen capture resolution and target framerate
        - metadata: The metadata that will be sent to the `Membrane RTC Engine` for media negotiation
        - onStart: The callback that will receive the screencast track called once the track becomes available
        - onStop: The callback that will be called once the track becomes unavailable
     */
    public func createScreencastTrack(appGroup: String, videoParameters: VideoParameters, metadata: Metadata, onStart: @escaping (_ track: LocalScreenBroadcastTrack) -> Void, onStop: @escaping () -> Void) {
        let screensharingTrack = LocalScreenBroadcastTrack(appGroup: appGroup, videoParameters: videoParameters)
        localTracks.append(screensharingTrack)

        broadcastScreenshareReceiver = ScreenBroadcastNotificationReceiver(onStart: { [weak self, weak screensharingTrack] in
            guard let track = screensharingTrack else {
                return
            }

            DispatchQueue.main.async {
                self?.setupScreencastTrack(track: track, metadata: metadata)
                onStart(track)
            }
        }, onStop: { [weak self, weak screensharingTrack] in
            DispatchQueue.main.async {
                if let track = screensharingTrack {
                    self?.removeTrack(trackId: track.rtcTrack().trackId)
                }
                onStop()
            }
        })

        screensharingTrack.delegate = broadcastScreenshareReceiver
        screensharingTrack.start()
    }
    
    /**
     Removes a local track with given `trackId`.
     
     - Parameters:
        - trackId: The id of the local track that should get stopped and removed from the client
     
     - Returns: Bool whether the track has been found and removed or not
     */
    @discardableResult
    public func removeTrack(trackId: String) -> Bool {
        guard let index = localTracks.firstIndex(where: { $0.rtcTrack().trackId == trackId}) else {
            return false
        }
        
        let track = localTracks.remove(at: index)
        let rtcTrack = track.rtcTrack()
        track.stop()
        
        if let pc = connection,
           let sender = pc.transceivers.first(where: { $0.sender.track?.trackId == rtcTrack.trackId })?.sender {
            pc.removeTrack(sender)
        }
        
        localPeer = localPeer.withoutTrack(trackId: trackId)
        
        transport.send(event: RenegotiateTracksEvent())
        
        return true
    }
    
    /// Returns information about the current local peer
    public func currentPeer() -> Peer {
        return localPeer
    }
    
    internal func connect() {
        // initiate a transport connection
        transport.connect(delegate: self).then {
            self.notify {
                self.state = .awaitingJoin
                
                $0.onConnected()
            }
        }.catch { error in
            self.notify {
                $0.onError(.transport(error.localizedDescription))
            }
        }
    }

    /// Adds given broadcast track to the peer connection and forces track renegotiation.
    private func setupScreencastTrack(track: LocalScreenBroadcastTrack, metadata: Metadata) {
        guard let pc = connection else {
            return
        }

        let screencastStreamId = UUID().uuidString
        pc.add(track.rtcTrack(), streamIds: [screencastStreamId])

        pc.enforceSendOnlyDirection()

        localPeer = localPeer.withTrack(trackId: track.rtcTrack().trackId, metadata: metadata)
        
        transport.send(event: RenegotiateTracksEvent())
    }

    /// Sets up the local peer connection with previously prepared config and local media tracks.
    private func setupPeerConnection() {
        let config = self.config
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.candidateNetworkPolicy = .all
        config.disableIPV6 = true
        config.tcpCandidatePolicy = .disabled

        // if ice servers are not empty that probably means we are using turn servers
        if iceServers.count > 0 {
            self.config.iceServers = iceServers
        } else {
            self.config.iceServers = [Self.defaultIceServer()]
        }

        guard let peerConnection = ConnectionManager.createPeerConnection(config, constraints: Self.mediaConstraints) else {
            fatalError("Failed to initialize new PeerConnection")
        }
        connection = peerConnection

        peerConnection.delegate = self
        
        localTracks.forEach { track in
            peerConnection.add(track.rtcTrack(), streamIds: [localStreamId])
            
        }
        
        peerConnection.enforceSendOnlyDirection()
    }
}

extension MembraneRTC: RTCPeerConnectionDelegate {
    public func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {
        sdkLogger.info("\(pcLogPrefix) new stream added")
    }

    public func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {
        sdkLogger.info("\(pcLogPrefix) stream has been removed")
    }

    public func peerConnection(_: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        let descriptions: [RTCSignalingState: String] = [
            .haveLocalOffer: "have local offer",
            .haveRemoteOffer: "have remote offer",
            .haveLocalPrAnswer: "have local pr answer",
            .haveRemotePrAnswer: "have remote pr answer",
            .stable: "stable",
            .closed: "closed",
        ]

        sdkLogger.debug("\(pcLogPrefix) changed signaling state to \(descriptions[stateChanged] ?? "unknown")")
    }

    public func peerConnection(_: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let trackId = midToTrackId[transceiver.mid],
              var trackContext = trackContexts[trackId]
        else {
            sdkLogger.error("\(pcLogPrefix) started receiving on a transceiver with an unknown 'mid' parameter or without registered track context")
            return
        }

        // assign given receiver to its track's context

        let track = transceiver.receiver.track
        if let audioTrack = track as? RTCAudioTrack {
            trackContext.track = RemoteAudioTrack(track: audioTrack)
        }

        if let videoTrack = track as? RTCVideoTrack {
            trackContext.track = RemoteVideoTrack(track: videoTrack)
        }

        trackContexts[trackId] = trackContext

        notify {
            $0.onTrackReady(ctx: trackContext)
        }

        sdkLogger.debug("\(pcLogPrefix) started receiving on a transceiver with a mid: \(transceiver.mid) and id \(transceiver.receiver.track?.trackId ?? "")")
    }

    public func peerConnection(_: RTCPeerConnection,
                               didAdd receiver: RTCRtpReceiver, streams _: [RTCMediaStream])
    {
        sdkLogger.info("\(pcLogPrefix) new receiver has been added: \(receiver.receiverId)")
    }

    public func peerConnection(_: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {
        sdkLogger.info("\(pcLogPrefix) receiver has been removed: \(rtpReceiver.receiverId)")
    }

    public func peerConnection(_: RTCPeerConnection, didChangeLocalCandidate local: RTCIceCandidate, remoteCandidate remote: RTCIceCandidate, lastReceivedMs _: Int32, changeReason reason: String) {
        sdkLogger.debug("\(pcLogPrefix) a local candidate has been changed due to: '\(reason)'\nlocal: \(local.sdp)\nremote: \(remote.sdp)")
    }

    public func peerConnectionShouldNegotiate(_: RTCPeerConnection) {
        sdkLogger.debug("\(pcLogPrefix) should negotiate")
    }

    public func peerConnection(_: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let descriptions: [RTCIceConnectionState: String] = [
            .new: "new",
            .checking: "checking",
            .connected: "connected",
            .closed: "closed",
            .completed: "completed",
            .disconnected: "disconnected",
            .failed: "failed",
            .count: "count",
        ]

        sdkLogger.debug("\(pcLogPrefix) new connection state: \(descriptions[newState] ?? "unknown")")

        switch newState {
        case .connected:
            state = .connected
        case .disconnected:
            state = .disconnected
        default:
            break
        }
    }

    public func peerConnection(_: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        let descriptions: [RTCIceGatheringState: String] = [
            .new: "new",
            .gathering: "gathering",
            .complete: "complete",
        ]

        sdkLogger.debug("\(pcLogPrefix) new ice gathering state: \(descriptions[newState] ?? "unknown")")
    }

    public func peerConnection(_: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onLocalCandidate(candidate)
    }

    public func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {
        sdkLogger.debug("\(pcLogPrefix) a list of candidates has been removed")
    }

    public func peerConnection(_: RTCPeerConnection, didOpen _: RTCDataChannel) {}
}

extension MembraneRTC: EventTransportDelegate {
    public func didReceive(event: ReceivableEvent) {
        switch event.type {
        case .PeerAccepted:
            let peerAccepted = event as! PeerAcceptedEvent

            localPeer = localPeer.with(id: peerAccepted.data.id)

            // initialize all present peers
            peerAccepted.data.peersInRoom.forEach { peer in
                self.remotePeers[peer.id] = peer

                // initialize peer's track contexts
                peer.trackIdToMetadata?.forEach { trackId, metadata in
                    let context = TrackContext(track: nil, peer: peer, trackId: trackId, metadata: metadata)

                    self.trackContexts[trackId] = context

                    self.notify {
                        $0.onTrackAdded(ctx: context)
                    }
                }
            }

            notify {
                $0.onJoinSuccess(peerID: peerAccepted.data.id, peersInRoom: peerAccepted.data.peersInRoom)
            }

        case .PeerJoined:
            let peerJoined = event as! PeerJoinedEvent

            guard peerJoined.data.peer.id != localPeer.id else {
                return
            }

            let peer = peerJoined.data.peer
            remotePeers[peerJoined.data.peer.id] = peer

            notify {
                $0.onPeerJoined(peer: peerJoined.data.peer)
            }

        case .PeerLeft:
            let peerLeft = event as! PeerLeftEvent

            guard let peer = remotePeers[peerLeft.data.peerId] else {
                return
            }

            remotePeers.removeValue(forKey: peer.id)

            // for a leaving peer clear his track contexts
            if let trackIds = peer.trackIdToMetadata?.keys {
                let contexts = trackIds.compactMap { id in
                    self.trackContexts[id]
                }

                trackIds.forEach { id in
                    self.trackContexts.removeValue(forKey: id)
                }

                contexts.forEach { context in
                    self.notify {
                        $0.onTrackRemoved(ctx: context)
                    }
                }
            }

            notify {
                $0.onPeerLeft(peer: peer)
            }

        case .PeerUpdated:
            let peerUpdated = event as! PeerUpdateEvent

            guard var peer = remotePeers[peerUpdated.data.peerId] else {
                return
            }

            // update peer's metadata
            peer = peer.with(metadata: peerUpdated.data.metadata)
            
            remotePeers.updateValue(peer, forKey: peer.id)

            notify {
                $0.onPeerUpdated(peer: peer)
            }

        case .OfferData:
            let offerData = event as! OfferDataEvent

            DispatchQueue.sdk.async {
                self.onOfferData(offerData)
            }

        case .SdpAnswer:
            let sdpAnswer = event as! SdpAnswerEvent

            DispatchQueue.sdk.async {
                self.onSdpAnswer(sdpAnswer)
            }

        case .Candidate:
            let candidate = event as! RemoteCandidateEvent

            DispatchQueue.sdk.async {
                self.onRemoteCandidate(candidate)
            }

        case .TracksAdded:
            let tracksAdded = event as! TracksAddedEvent

            // ignore local participant
            guard localPeer.id != tracksAdded.data.peerId else {
                return
            }

            guard var peer = remotePeers[tracksAdded.data.peerId] else {
                return
            }

            // update tracks of the remote peer
            peer = peer.with(trackIdToMetadata: tracksAdded.data.trackIdToMetadata)
            remotePeers[peer.id] = peer

            // for each track create a corresponding track context
            peer.trackIdToMetadata?.forEach { trackId, metadata in
                let context = TrackContext(track: nil, peer: peer, trackId: trackId, metadata: metadata)

                self.trackContexts[trackId] = context

                self.notify {
                    $0.onTrackAdded(ctx: context)
                }
            }

        case .TracksRemoved:
            let tracksRemoved = event as! TracksRemovedEvent

            guard let _ = remotePeers[tracksRemoved.data.peerId] else {
                return
            }

            // for each track clear its context and notify delegates
            tracksRemoved.data.trackIds.forEach { id in
                guard let context = self.trackContexts[id] else {
                    return
                }

                self.trackContexts.removeValue(forKey: id)

                self.notify {
                    $0.onTrackRemoved(ctx: context)
                }
            }

        default:
            sdkLogger.error("Failed to handle ReceivableEvent of type \(event.type)")

            return
        }
    }

    public func didReceive(error: EventTransportError) {
        notify {
            $0.onError(.transport(error.description))
        }
    }
}

extension MembraneRTC {
    /// Handles the `OfferDataEvent`, creates a local description and sends `SdpAnswerEvent`
    func onOfferData(_ offerData: OfferDataEvent) {
        setTurnServers(offerData.data.integratedTurnServers, offerData.data.iceTransportPolicy)

        if connection == nil {
            setupPeerConnection()
        }

        guard let pc = connection else {
            return
        }

        addNecessaryTransceivers(offerData)

        if state == .connected {
            pc.restartIce()
        }

        pc.offer(for: Self.mediaConstraints, completionHandler: { offer, error in
            guard let offer = offer else {
                if let err = error {
                    self.notify {
                        $0.onError(.rtc(err.localizedDescription))
                    }
                }
                return
            }

            pc.setLocalDescription(offer, completionHandler: { error in
                guard let err = error else {
                    self.transport.send(event: SdpOfferEvent(sdp: offer.sdp, trackIdToTrackMetadata: self.localPeer.trackIdToMetadata ?? [:], midToTrackId: self.getMidToTrackId()))
                    return
                }

                self.notify {
                    $0.onError(.rtc(err.localizedDescription))
                }

            })
        })
    }

    /// Parses a list of turn servers and sets them up as `iceServers` that can be used for `RTCPeerConnection` ceration.
    private func setTurnServers(_ turnServers: [OfferDataEvent.TurnServer], _ iceTransportPolicy: String) {
        switch iceTransportPolicy {
        case "all":
            config.iceTransportPolicy = .all
        case "relay":
            config.iceTransportPolicy = .relay
        default:
            break
        }

        let servers: [RTCIceServer] = turnServers.map { server in
            let url = ["turn", ":", server.serverAddr, ":", String(server.serverPort), "?transport=", server.transport].joined()

            return RTCIceServer(
                urlStrings: [url],
                username: server.username,
                credential: server.password
            )
        }

        iceServers = servers
    }

    /// On each `OfferData` we receive an information about an amount of audio/video
    /// tracks that we have to receive. For each type of track we need a proper transceiver that
    /// will be used for receiving the media. So each time when we don't have an appropriate amount of audio/video
    /// transceiers just create the missing ones and set their directions to `recvOnly` which is the only direction
    /// acceptable by the `Membrane RTC Engine`.
    private func addNecessaryTransceivers(_ offerData: OfferDataEvent) {
        guard let pc = connection else {
            return
        }

        let necessaryAudio = offerData.data.tracksTypes["audio"] ?? 0
        let necessaryVideo = offerData.data.tracksTypes["video"] ?? 0

        var lackingAudio: Int = necessaryAudio
        var lackingVideo: Int = necessaryVideo

        pc.transceivers.filter {
            $0.direction == .recvOnly
        }.forEach { transceiver in
            guard let track = transceiver.receiver.track else {
                return
            }

            switch track.kind {
            case "audio": lackingAudio -= 1
            case "video": lackingVideo -= 1
            default:
                break
            }
        }

        sdkLogger.info("peerConnection adding \(lackingAudio) audio and \(lackingVideo) video lacking transceivers")

        // NOTE: check the lacking amount just in case there are some bugs
        // that caused the lacking amount to go under zero
        if lackingAudio > 0 {
            for _ in 0 ..< lackingAudio {
                pc.addTransceiver(of: .audio)?.setDirection(.recvOnly, error: nil)
            }
        }

        if lackingVideo > 0 {
            for _ in 0 ..< lackingVideo {
                pc.addTransceiver(of: .video)?.setDirection(.recvOnly, error: nil)
            }
        }
    }

    /// Returns a mapping from `mid` of transceivers to their corresponding remote tracks' ids.
    private func getMidToTrackId() -> [String: String] {
        guard let pc = connection else {
            return [:]
        }
        
        var mapping: [String: String] = [:]
        if let localTracksKeys = localPeer.trackIdToMetadata?.keys {
            let localTracks: [String] = Array(localTracksKeys)

            pc.transceivers.forEach { transceiver in
                guard let trackId: String = transceiver.sender.track?.trackId,
                      localTracks.contains(trackId)
                else {
                    return
                }
                mapping[transceiver.mid] = trackId
            }
        }

        return mapping
    }

    /// Receives the `SdpAnswerEvent` and sets the remote description.
    func onSdpAnswer(_ sdpAnswer: SdpAnswerEvent) {
        guard let pc = connection else {
            return
        }

        // FIXEME: trackId returned from backend sometimes happens to be null...
        midToTrackId = sdpAnswer.data.midToTrackId.filter { $0.value != nil } as! [String: String]

        let description = RTCSessionDescription(type: .answer, sdp: sdpAnswer.data.sdp)

        pc.setRemoteDescription(description, completionHandler: { error in
            guard let err = error else {
                return
            }

            sdkLogger.error("error occured while trying to set a remote description \(err)")
        })
    }

    /// Receives the `RemoveCandidateEvent`, parses it to an ice candidate and adds to the current peer connection.
    func onRemoteCandidate(_ remoteCandidate: RemoteCandidateEvent) {
        guard let pc = connection else {
            return
        }

        let candidate = RTCIceCandidate(sdp: remoteCandidate.data.candidate, sdpMLineIndex: remoteCandidate.data.sdpMLineIndex, sdpMid: remoteCandidate.data.sdpMid)

        pc.add(candidate, completionHandler: { error in
            guard let err = error else {
                return
            }

            sdkLogger.error("error occured  during remote ice candidate processing: \(err)")
        })
    }

    /// Sends the local ice candidate to the `Membrane RTC Engine` instance via transport layer.
    func onLocalCandidate(_ candidate: RTCIceCandidate) {
        transport.send(event: LocalCandidateEvent(candidate: candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex))
    }
}

internal extension DispatchQueue {
    static let webRTC = DispatchQueue(label: "membrane.rtc.webRTC")
    static let sdk = DispatchQueue(label: "membrane.rtc.sdk")
}
