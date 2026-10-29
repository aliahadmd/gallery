public protocol CatalogID: Hashable, Sendable, Codable, CustomStringConvertible {
    init(rawValue: Int64)
    var rawValue: Int64 { get }
}

extension CatalogID {
    public var description: String { "\(type(of: self))(\(rawValue))" }

    /// Encoded as a bare integer, not `{"rawValue":…}` — these IDs appear inside `AlbumKind` payloads and
    /// in view state, and a wrapper object per ID would make every one of those payloads unreadable.
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int64.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct MediaID: CatalogID {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}

public struct SourceID: CatalogID {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}

public struct AlbumID: CatalogID {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}

public struct ClusterID: CatalogID {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}
