public struct Peer: Codable {
    public let id: String
    public let metadata: Metadata
    public let trackIdToMetadata: [String: Metadata]?

    public init(id: String, metadata: Metadata, trackIdToMetadata: [String: Metadata]?) {
        self.id = id
        self.metadata = metadata
        self.trackIdToMetadata = trackIdToMetadata
    }
    
    public func with(id: String? = nil, metadata: Metadata? = nil, trackIdToMetadata: [String: Metadata]? = nil) -> Self {
        return Peer(
            id: id ?? self.id,
            metadata: metadata ?? self.metadata,
            trackIdToMetadata: trackIdToMetadata ?? self.trackIdToMetadata
        )
    }
    
    public func withTrack(trackId: String, metadata: Metadata) -> Self {
        var newTrackIdToMetadata = self.trackIdToMetadata
        newTrackIdToMetadata?[trackId] = metadata
        
        return Peer(id: self.id, metadata: self.metadata, trackIdToMetadata: newTrackIdToMetadata)
    }
    
    public func withoutTrack(trackId: String) -> Self {
        var newTrackIdToMetadata = self.trackIdToMetadata
        newTrackIdToMetadata?.removeValue(forKey: trackId)
        
        return Peer(id: self.id, metadata: self.metadata, trackIdToMetadata: newTrackIdToMetadata)
    }
    
    enum CodingKeys: String, CodingKey {
        case id, metadata, trackIdToMetadata
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.metadata = try container.decode(Metadata.self, forKey: .metadata)
        self.trackIdToMetadata = try container.decodeIfPresent([String: Metadata].self, forKey: .trackIdToMetadata)
    }
}
