import Foundation

/// A trip/event album's identity. Derived from the fingerprint of its first day, centroid and size so
/// the same event keeps the same ID across recomputes — otherwise favorites and scroll position would
/// break every time the heuristic parameters move.
public struct EventKey: Sendable, Hashable, Codable {
    public var stableID: Int64

    public init(stableID: Int64) { self.stableID = stableID }
}

/// A geographically-named grouping ("Kyoto", "Reykjavík") that spans several location clusters.
public struct PlaceKey: Sendable, Hashable, Codable {
    public var name: String
    public var adminArea: String?
    public var country: String?

    public init(name: String, adminArea: String? = nil, country: String? = nil) {
        self.name = name
        self.adminArea = adminArea
        self.country = country
    }

    /// Stable identity for a place album, built from the parts we actually group on.
    public var canonical: String { [name, adminArea, country].compactMap { $0 }.joined(separator: "|") }
}

/// A curated scene tag ("food", "documents", "night"). Closed vocabulary from `TagVocabulary`: the analyser
/// maps Vision's identifiers onto it, so the shelf cannot fill up with 1,300 near-duplicates of "structure".
public struct TagKey: Sendable, Hashable, Codable {
    public var slug: String

    public init(slug: String) { self.slug = slug }
}

/// A person from the face index. The stable id is what the sidebar selects; the name is whatever the user
/// typed, and it survives a re-cluster.
public struct PersonKey: Sendable, Hashable, Codable {
    public var stableID: Int64

    public init(stableID: Int64) { self.stableID = stableID }
}

/// A materialised near-duplicate set. Stable while the group lives.
public struct DuplicateKey: Sendable, Hashable, Codable {
    public var stableID: Int64

    public init(stableID: Int64) { self.stableID = stableID }
}

public enum AlbumKind: Sendable, Hashable, Codable {
    case folder(SourceID)
    case subfolder(SourceID, relativePath: String)
    case day(Int32)
    case month(Int32)
    case event(EventKey)
    case location(ClusterID)
    case place(PlaceKey)
    case smart(SmartRule)
    case tag(TagKey)
    case category(MediaCategory)
    case person(PersonKey)
    case duplicates
    case duplicateGroup(DuplicateKey)

    // The fixed type albums. These are also expressible as `smart`, but keeping named cases means the
    // sidebar's identity does not shift when someone edits a rule that happens to look the same.
    case allPhotos
    case allVideos
    case favorites
    case screenshots
    case raw
    case livePhotos
    case animated
    case offline
    case recentlyDeleted
    case uncategorized
    case problems
    case all

    /// Albums whose rows come from a materialized table rather than a predicate.
    public var isDerivedMembership: Bool {
        switch self {
        case .event, .location, .place, .tag, .person, .duplicates, .duplicateGroup: true
        default: false
        }
    }
}

/// The columns a user-authored rule may reference. The whitelist is the injection defense: `AlbumQuery`
/// maps these to fixed SQL fragments and never takes a column name from the rule's payload.
public enum PredicateKind: String, Sendable, Hashable, Codable, CaseIterable {
    case kindEquals
    case subtypeIncludes
    case subtypeExcludes
    case isFavorite
    case sourceEquals
    case parentRelHasPrefix
    case nameContains
    case dayBucketEquals
    case monthBucketEquals
    case captureAfter
    case captureBefore
    case minDurationSeconds
    case maxDurationSeconds
    case minLongSidePixels
    case hasGPS
    case placeKeyEquals
    case clusterEquals
    case byteSizeAtLeast
    /// Phase A: the analyser's score, so "best shots" is a rule like any other.
    case aestheticAtLeast
    /// Screenshots of chats and receipts: worth OCR, not worth a cover.
    case isUtility
    case tagEquals
}

public enum SmartValue: Sendable, Hashable, Codable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case boolean(Bool)
    case date(Date)

    public var intValue: Int64? {
        switch self {
        case .integer(let v): v
        case .real(let v): Int64(v)
        case .boolean(let v): v ? 1 : 0
        case .date(let v): Int64(v.timeIntervalSince1970)
        case .text: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let v): Double(v)
        case .real(let v): v
        case .boolean(let v): v ? 1 : 0
        case .date(let v): v.timeIntervalSince1970
        case .text: nil
        }
    }

    public var textValue: String? { if case .text(let v) = self { v } else { nil } }
    public var boolValue: Bool? { if case .boolean(let v) = self { v } else { nil } }
    public var dateValue: Date? { if case .date(let v) = self { v } else { nil } }
}

public struct SmartPredicate: Sendable, Hashable, Codable {
    public var kind: PredicateKind
    public var value: SmartValue

    public init(_ kind: PredicateKind, _ value: SmartValue) {
        self.kind = kind
        self.value = value
    }
}

/// `all` must hold, `any` needs one member (when non-empty), `none` must all fail.
public struct SmartRule: Sendable, Hashable, Codable {
    public var name: String
    public var all: [SmartPredicate]
    public var any: [SmartPredicate]
    public var none: [SmartPredicate]

    public init(name: String, all: [SmartPredicate] = [], any: [SmartPredicate] = [], none: [SmartPredicate] = []) {
        self.name = name
        self.all = all
        self.any = any
        self.none = none
    }

    public var isEmpty: Bool { all.isEmpty && any.isEmpty && none.isEmpty }

    /// The columns this rule touches — used to prove a rule is satisfiable before it reaches the SQL layer.
    public var referencedKinds: Set<PredicateKind> {
        Set((all + any + none).map(\.kind))
    }
}

public struct Album: Identifiable, Sendable, Hashable, Codable {
    public let id: AlbumID
    public var kind: AlbumKind
    public var title: String
    public var subtitle: String?

    /// Chosen by the catalog as the highest-ranked item with a cached thumbnail, so covers never ask the
    /// imaging layer to bake one just to draw the sidebar.
    public var coverMediaID: MediaID?
    public var itemCount: Int

    /// Sidebar ordering key, negated date buckets so "newest first" is a plain ascending sort.
    public var sortKey: Int64

    public init(
        id: AlbumID,
        kind: AlbumKind,
        title: String,
        subtitle: String? = nil,
        coverMediaID: MediaID? = nil,
        itemCount: Int = 0,
        sortKey: Int64 = 0
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.coverMediaID = coverMediaID
        self.itemCount = itemCount
        self.sortKey = sortKey
    }

    /// Date albums bucket by `yyyymmdd`; a day before 2000 is a corrupt-EXIF sentinel, not a real album.
    public static func day(_ bucket: Int32, count: Int) -> Album {
        Album(
            id: AlbumID(rawValue: Self.syntheticID(for: .day(bucket))),
            kind: .day(bucket),
            title: Self.title(forDayBucket: bucket),
            itemCount: count,
            sortKey: -Int64(bucket)
        )
    }

    public static func month(_ bucket: Int32, count: Int) -> Album {
        Album(
            id: AlbumID(rawValue: Self.syntheticID(for: .month(bucket))),
            kind: .month(bucket),
            title: Self.title(forMonthBucket: bucket),
            itemCount: count,
            sortKey: -Int64(bucket)
        )
    }

    /// Albums derived from queries have no row of their own, so their ID is a pure function of the kind —
    /// which keeps selection stable across reloads.
    public static func syntheticID(for kind: AlbumKind) -> Int64 {
        var data = Data()
        if case .folder(let sourceID) = kind { data.append(contentsOf: String(sourceID.rawValue).utf8) }
        else if case .subfolder(let sourceID, let path) = kind {
            data.append(contentsOf: "\(sourceID.rawValue)/\(path)".utf8)
        } else {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            if let encoded = try? encoder.encode(kind) { data = encoded }
        }
        return fnv1aID(data)
    }

    static func title(forDayBucket bucket: Int32) -> String {
        guard let date = CaptureMoment.date(forDayBucket: bucket, timeZone: .current) else {
            return String(format: "%d", bucket)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    static func title(forMonthBucket bucket: Int32) -> String {
        let year = Int(bucket) / 100
        let month = Int(bucket) % 100
        guard (1...12).contains(month) else { return String(format: "%d", bucket) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        guard let date = Calendar(identifier: .gregorian).date(from: components) else {
            return String(format: "%d", bucket)
        }
        return formatter.string(from: date)
    }
}
