import Foundation

public typealias Payload = [String: Any?]

/// Protocol for outgoing `MembraneRTC` events
public protocol SendableEvent {
    func serialize() -> Payload
}

/// Available types of incoming media events.
public enum ReceivableEventType: String, Codable {
    case PeerAccepted = "peerAccepted"
    case PeerJoined = "peerJoined"
    case PeerLeft = "peerLeft"
    case PeerUpdated = "peerUpdated"
    case Custom = "custom"
    case OfferData = "offerData"
    case Candidate = "candidate"
    case TracksAdded = "tracksAdded"
    case TracksRemoved = "tracksRemoved"
    case TrackUpdated = "trackUpdated"
    case SdpAnswer = "sdpAnswer"
}

/// Protocol for incoming `MembraneRTC` events
public protocol ReceivableEvent {
    var type: ReceivableEventType { get }
}

internal struct ReceivableEventBase: Decodable {
    let type: ReceivableEventType
}

public enum Events {
    internal static func decodeEvent<T: Decodable>(from data: Data) -> T? {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            sdkLogger.error("failed to decode an event: \(error)")
            return nil
        }
    }

    /*
     Deserialization of incoming events is quite specific.

     Each incoming event is of given format:
     ```
     {
        "type": "(dedicated event name)",
        "data": "arbitrary event's payload object"
     }
     ```

     It is quite problematic as we have to decode each event twice. Once to get the event's type,
     and when we know the type we can decode the event's data payload (due to static typing
     we need to explicitly call decode with generic parameter).

     A subset of events are embeded inside of one specific event of type "custom".
     In this case the "data" payload contains a whole new event on its own:
     ```
     {
        "type": "custom",
        "data": {
            "type": "(dedicated event name)",
            "data": "arbitrary event's payload object"
        }
     }
     ```

     This time we are basically performing the deserialization 3 times:
     - to recognize "custom" type
     - to recognize the nested event's type
     - to finally deserialize the payload into an explicit event
     */
    public static func deserialize(payload: Payload) -> ReceivableEvent? {
        guard let rawData = payload["data"] as? String else {
            sdkLogger.error("Failed to extract 'data' field from json payload: \(payload)")
            return nil
        }

        let data = rawData.data(using: .utf8)!

        guard let base: ReceivableEventBase = decodeEvent(from: data) else {
            sdkLogger.error("Failed to decode ReceivableEventBase")
            return nil
        }

        switch base.type {
        case .PeerAccepted:
            let event: PeerAcceptedEvent? = decodeEvent(from: data)

            return event

        case .PeerJoined:
            let event: PeerJoinedEvent? = decodeEvent(from: data)

            return event

        case .PeerLeft:
            let event: PeerLeftEvent? = decodeEvent(from: data)

            return event

        case .PeerUpdated:
            let event: PeerUpdateEvent? = decodeEvent(from: data)

            return event

        case .TracksAdded:
            let event: TracksAddedEvent? = decodeEvent(from: data)

            return event

        case .TracksRemoved:
            let event: TracksRemovedEvent? = decodeEvent(from: data)

            return event

        case .TrackUpdated:
            let event: TracksUpdatedEvent? = decodeEvent(from: data)

            return event

        case .Custom:
            guard let baseEvent: BaseCustomEvent = decodeEvent(from: data) else {
                return nil
            }

            switch baseEvent.data.type {
            case .OfferData:
                guard let event: CustomEvent<OfferDataEvent> = decodeEvent(from: data) else {
                    return nil
                }

                return event.data

            case .Candidate:
                guard let event: CustomEvent<RemoteCandidateEvent> = decodeEvent(from: data) else {
                    return nil
                }

                return event.data

            case .SdpAnswer:
                guard let event: CustomEvent<SdpAnswerEvent> = decodeEvent(from: data) else {
                    return nil
                }

                return event.data

            default:
                sdkLogger.warning("Unhandled custom event parsing for \(baseEvent.data.type)")

                return nil
            }
        default:
            return nil
        }
    }
}

/*
 Sendable events
 */
struct JoinEvent: SendableEvent {
    let metadata: Metadata

    init(metadata: Metadata) {
        self.metadata = metadata
    }

    func serialize() -> Payload {
        return [
            "type": "join",
            "data": ["metadata": metadata],
        ]
    }
}

struct SdpOfferEvent: SendableEvent {
    let sdp: String
    let trackIdToTrackMetadata: [String: Metadata]
    let midToTrackId: [String: String]

    init(sdp: String, trackIdToTrackMetadata: [String: Metadata], midToTrackId: [String: String]) {
        self.sdp = sdp
        self.trackIdToTrackMetadata = trackIdToTrackMetadata
        self.midToTrackId = midToTrackId
    }

    func serialize() -> Payload {
        return [
            "type": "custom",
            "data": [
                "type": "sdpOffer",
                "data": [
                    "sdpOffer": [
                        "type": "offer",
                        "sdp": sdp,
                    ],
                    "trackIdToTrackMetadata": trackIdToTrackMetadata,
                    "midToTrackId": midToTrackId,
                ],
            ],
        ]
    }
}

struct LocalCandidateEvent: SendableEvent {
    let candidate: String
    let sdpMLineIndex: Int32

    init(candidate: String, sdpMLineIndex: Int32) {
        self.candidate = candidate
        self.sdpMLineIndex = sdpMLineIndex
    }

    func serialize() -> Payload {
        return [
            "type": "custom",
            "data": [
                "type": "candidate",
                "data": [
                    "candidate": candidate,
                    "sdpMLineIndex": sdpMLineIndex,
                ],
            ],
        ]
    }
}

struct RenegotiateTracksEvent: SendableEvent {
    init() {}

    func serialize() -> Payload {
        return [
            "type": "custom",
            "data": [
                "type": "renegotiateTracks",
            ],
        ]
    }
}

/*
 Receivable events
 */

struct PeerAcceptedEvent: ReceivableEvent, Codable {
    struct Data: Codable {
        let id: String
        let peersInRoom: [Peer]
    }

    let type: ReceivableEventType
    let data: Data
}

struct PeerJoinedEvent: ReceivableEvent, Codable {
    struct Data: Codable {
        let peer: Peer
    }

    let type: ReceivableEventType
    let data: Data
}

struct PeerLeftEvent: ReceivableEvent, Codable {
    struct Data: Codable {
        let peerId: String
    }

    let type: ReceivableEventType
    let data: Data
}

struct PeerUpdateEvent: ReceivableEvent, Codable {
    struct Data: Codable {
        let peerId: String
        let metadata: Metadata
    }

    let type: ReceivableEventType
    let data: Data
}

struct OfferDataEvent: ReceivableEvent, Codable {
    struct TurnServer: Codable {
        let username: String
        let password: String
        let serverAddr: String
        let serverPort: UInt32
        let transport: String
    }

    struct Data: Codable {
        let iceTransportPolicy: String
        let integratedTurnServers: [TurnServer]
        let tracksTypes: [String: Int]
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.integratedTurnServers = try container.decode([TurnServer].self, forKey: .integratedTurnServers)
            self.tracksTypes = try container.decode([String: Int].self, forKey: .tracksTypes)
            if container.contains(.iceTransportPolicy) {
                self.iceTransportPolicy = try container.decode(String.self, forKey: .iceTransportPolicy)
            } else {
                self.iceTransportPolicy = "all"
            }
        }
    }

    let type: ReceivableEventType
    let data: Data
}

struct TracksAddedEvent: ReceivableEvent, Codable {
    struct Data: Codable {
        let peerId: String
        let trackIdToMetadata: [String: Metadata]
    }

    let type: ReceivableEventType
    let data: Data
}

struct TracksRemovedEvent: ReceivableEvent, Codable {
    struct Data: Codable {
        let peerId: String
        let trackIds: [String]
    }

    let type: ReceivableEventType
    let data: Data
}

struct TracksUpdatedEvent: ReceivableEvent, Codable {
    struct Data: Codable {
        let peerId: String
        let trackId: String
        let metadata: Metadata
    }

    let type: ReceivableEventType
    let data: Data
}

struct SdpAnswerEvent: ReceivableEvent, Codable {
    struct Data: Codable {
        let type: String
        let sdp: String
        let midToTrackId: [String: String?]
    }

    let type: ReceivableEventType
    let data: Data
}

struct RemoteCandidateEvent: ReceivableEvent, Codable {
    struct Data: Codable {
        let candidate: String
        let sdpMLineIndex: Int32
        let sdpMid: String?
    }

    let type: ReceivableEventType
    let data: Data
}

// This is kinda strange as we can't dynamically decode json strings to structs
// e.g. to [String: Any] type
// Therefore we need to preform a 2-phase decoding, meaning that we need to extract types first
// and then based on them statically decode embedded events
struct BaseCustomEvent: ReceivableEvent, Codable {
    struct Data: Codable {
        let type: ReceivableEventType
    }

    let type: ReceivableEventType
    let data: Data
}

struct CustomEvent<EventType: ReceivableEvent & Codable>: ReceivableEvent, Codable {
    let type: ReceivableEventType
    let data: EventType
}
