import Foundation
import GalleryDomain
import GallerySQLite

/// A compiled WHERE clause plus the parameters it needs. Nothing in this type ever puts caller text into
/// SQL — values leave through `?`.
public struct CompiledQuery: Sendable, Hashable {
    public var whereSQL: String
    public var arguments: [Value]

    public init(whereSQL: String, arguments: [Value]) {
        self.whereSQL = whereSQL
        self.arguments = arguments
    }

    /// Combining two compiled queries — an album's predicate and a "search within this album" filter.
    public func and(_ other: CompiledQuery) -> CompiledQuery {
        CompiledQuery(whereSQL: "(\(whereSQL)) AND (\(other.whereSQL))", arguments: arguments + other.arguments)
    }
}

/// Albums are queries, not stored membership. Folder, date, type, favorites and every smart rule are
/// predicates over indexed columns, so a rename, a rescan or a metadata correction cannot leave an album
/// holding a stale copy of the truth — there is only one copy.
public enum AlbumQuery {
    /// Rows that should be hidden everywhere except the views that exist precisely to show them.
    static let livePredicate = CompiledQuery(whereSQL: "media.trash = 0", arguments: [])

    public static func compile(_ kind: AlbumKind) -> CompiledQuery {
        let core: CompiledQuery
        switch kind {
        case .folder(let sourceID):
            core = .init(whereSQL: "media.src_id = ?", arguments: [.integer(sourceID.rawValue)])
        case .subfolder(let sourceID, let path):
            // One equality for the folder itself and a prefix test for its children, because a folder album
            // showing only its top level would split a camera roll into twenty albums.
            core = .init(
                whereSQL: "media.src_id = ? AND (media.parent_rel = ? OR media.parent_rel LIKE ?)",
                arguments: [.integer(sourceID.rawValue), .text(path), .text(path + "/%")]
            )
        case .day(let bucket):
            core = .init(whereSQL: "media.cap_day = ?", arguments: [.integer(Int64(bucket))])
        case .month(let bucket):
            core = .init(whereSQL: "media.cap_month = ?", arguments: [.integer(Int64(bucket))])
        case .event(let key):
            core = .init(
                whereSQL: "media.id IN (SELECT media_id FROM event_member WHERE event_id = (SELECT id FROM event WHERE key_id = ?))",
                arguments: [.integer(key.stableID)]
            )
        case .location(let clusterID):
            core = .init(whereSQL: "media.cluster_id = ?", arguments: [.integer(clusterID.rawValue)])
        case .place(let placeKey):
            core = .init(whereSQL: "media.place_key = ?", arguments: [.text(placeKey.canonical)])
        case .smart(let rule):
            core = compile(rule: rule)
        case .category(let category):
            // A confirmed verdict includes the row in that category; an exclusion removes it from every
            // category, because feedback is one verdict per photo.
            core = CompiledQuery(
                whereSQL: """
                ((media.category = ? AND NOT EXISTS (
                    SELECT 1 FROM category_feedback f
                    WHERE f.media_id = media.id AND f.verdict < 0))
                 OR media.id IN (
                    SELECT media_id FROM category_feedback WHERE category = ? AND verdict > 0))
                """,
                arguments: [.integer(Int64(category.rawValue)), .integer(Int64(category.rawValue))]
            )

        case .tag(let key):
            core = .init(whereSQL: "media.id IN (SELECT media_id FROM media_tag WHERE slug = ?)",
                         arguments: [.text(key.slug)])
        case .person(let key):
            core = .init(
                whereSQL: "media.id IN (SELECT media_id FROM face WHERE cluster_id = ?)",
                arguments: [.integer(key.stableID)]
            )
        case .duplicates:
            core = .init(whereSQL: "media.id IN (SELECT media_id FROM duplicate_member)", arguments: [])
        case .duplicateGroup(let key):
            core = .init(
                whereSQL: "media.id IN (SELECT media_id FROM duplicate_member WHERE group_id = ?)",
                arguments: [.integer(key.stableID)]
            )
        case .all:
            core = .init(whereSQL: "1", arguments: [])
        case .allPhotos:
            core = kindPredicate(.image)
        case .allVideos:
            // The MOV half of a Live Photo is a video as far as the filesystem is concerned and a
            // duplicate as far as the user is concerned.
            core = .init(
                whereSQL: "media.kind = ? AND (media.subtype & ?) = 0",
                arguments: [.integer(Int64(MediaKind.video.rawValue)),
                            .integer(Int64(MediaSubtype.livePhotoCompanion.rawValue))]
            )
        case .favorites:
            core = .init(whereSQL: "favorite.media_id IS NOT NULL", arguments: [])
        case .screenshots: core = subtypePredicate(.screenshot)
        case .raw: core = subtypePredicate(.raw)
        case .livePhotos:
            core = .init(
                whereSQL: "(media.subtype & ?) <> 0 AND (media.subtype & ?) = 0",
                arguments: [.integer(Int64(MediaSubtype.livePhoto.rawValue)),
                            .integer(Int64(MediaSubtype.livePhotoCompanion.rawValue))]
            )
        case .animated: core = subtypePredicate(.animated)
        case .offline:
            core = .init(whereSQL: "media.is_offline = 1", arguments: [])
        case .recentlyDeleted:
            return .init(whereSQL: "media.trash = ?", arguments: [.integer(Int64(TrashState.trashed.rawValue))])
        case .uncategorized:
            core = .init(whereSQL: "media.cap_day = 0 AND media.has_gps = 0", arguments: [])
        case .problems:
            return .init(whereSQL: "media.err_code <> 0", arguments: [])
        }
        return core.and(livePredicate)
    }

    private static func kindPredicate(_ kind: MediaKind) -> CompiledQuery {
        .init(whereSQL: "media.kind = ?", arguments: [.integer(Int64(kind.rawValue))])
    }

    private static func subtypePredicate(_ subtype: MediaSubtype) -> CompiledQuery {
        .init(whereSQL: "(media.subtype & ?) <> 0", arguments: [.integer(Int64(subtype.rawValue))])
    }

    /// `all` must hold, `any` needs at least one, `none` must all fail. An empty rule is `1`, not an error:
    /// a half-built rule in the settings editor should show everything rather than nothing.
    public static func compile(rule: SmartRule) -> CompiledQuery {
        var parts: [String] = []
        var arguments: [Value] = []

        for predicate in rule.all {
            let compiled = compile(predicate)
            parts.append(compiled.whereSQL)
            arguments.append(contentsOf: compiled.arguments)
        }
        if !rule.any.isEmpty {
            var anyParts: [String] = []
            for predicate in rule.any {
                let compiled = compile(predicate)
                anyParts.append(compiled.whereSQL)
                arguments.append(contentsOf: compiled.arguments)
            }
            parts.append("(\(anyParts.joined(separator: " OR ")))")
        }
        for predicate in rule.none {
            let compiled = compile(predicate)
            parts.append("NOT (\(compiled.whereSQL))")
            arguments.append(contentsOf: compiled.arguments)
        }
        guard !parts.isEmpty else { return CompiledQuery(whereSQL: "1", arguments: []) }
        return CompiledQuery(whereSQL: parts.joined(separator: " AND "), arguments: arguments)
    }

    /// The whitelist. A `PredicateKind` maps to a fixed fragment; nothing read from a rule's payload
    /// reaches the SQL text, which is why a rule saved by an older build cannot become an injection.
    private static func compile(_ predicate: SmartPredicate) -> CompiledQuery {
        let value = predicate.value
        switch predicate.kind {
        case .kindEquals:
            return .init(whereSQL: "media.kind = ?", arguments: [.integer(value.intValue ?? -1)])
        case .subtypeIncludes:
            return .init(whereSQL: "(media.subtype & ?) <> 0", arguments: [.integer(value.intValue ?? 0)])
        case .subtypeExcludes:
            return .init(whereSQL: "(media.subtype & ?) = 0", arguments: [.integer(value.intValue ?? 0)])
        case .isFavorite:
            let wanted = value.boolValue ?? true
            return .init(
                whereSQL: wanted ? "favorite.media_id IS NOT NULL" : "favorite.media_id IS NULL",
                arguments: []
            )
        case .sourceEquals:
            return .init(whereSQL: "media.src_id = ?", arguments: [.integer(value.intValue ?? 0)])
        case .parentRelHasPrefix:
            return .init(whereSQL: "media.parent_rel LIKE ?",
                         arguments: [.text((value.textValue ?? "") + "/%")])
        case .nameContains:
            return .init(whereSQL: "media.name LIKE ?", arguments: [.text("%" + (value.textValue ?? "") + "%")])
        case .dayBucketEquals:
            return .init(whereSQL: "media.cap_day = ?", arguments: [.integer(value.intValue ?? 0)])
        case .monthBucketEquals:
            return .init(whereSQL: "media.cap_month = ?", arguments: [.integer(value.intValue ?? 0)])
        case .captureAfter:
            return .init(whereSQL: "media.cap_utc > ?",
                         arguments: [.real(value.dateValue?.timeIntervalSince1970 ?? 0)])
        case .captureBefore:
            return .init(whereSQL: "media.cap_utc < ?",
                         arguments: [.real(value.dateValue?.timeIntervalSince1970 ?? 0)])
        case .minDurationSeconds:
            return .init(whereSQL: "media.duration_us >= ?",
                         arguments: [.integer(Int64((value.doubleValue ?? 0) * 1_000_000))])
        case .maxDurationSeconds:
            return .init(whereSQL: "media.duration_us <= ?",
                         arguments: [.integer(Int64((value.doubleValue ?? 0) * 1_000_000))])
        case .minLongSidePixels:
            return .init(
                whereSQL: "MAX(COALESCE(media.px_w, 0), COALESCE(media.px_h, 0)) >= ?",
                arguments: [.integer(value.intValue ?? 0)]
            )
        case .hasGPS:
            return .init(whereSQL: "media.has_gps = ?",
                         arguments: [.integer((value.boolValue ?? true) ? 1 : 0)])
        case .placeKeyEquals:
            return .init(whereSQL: "media.place_key = ?", arguments: [.text(value.textValue ?? "")])
        case .clusterEquals:
            return .init(whereSQL: "media.cluster_id = ?", arguments: [.integer(value.intValue ?? 0)])
        case .byteSizeAtLeast:
            return .init(whereSQL: "media.size_bytes >= ?", arguments: [.integer(value.intValue ?? 0)])
        case .aestheticAtLeast:
            return .init(whereSQL: "media.aesthetic >= ?", arguments: [.real(value.doubleValue ?? 0)])
        case .isUtility:
            return .init(whereSQL: "media.is_utility = ?",
                         arguments: [.integer((value.boolValue ?? true) ? 1 : 0)])
        case .tagEquals:
            return .init(whereSQL: "media.id IN (SELECT media_id FROM media_tag WHERE slug = ?)",
                         arguments: [.text(value.textValue ?? "")])
        }
    }
}

/// A page of media plus the cursor that continues it. `nextCursor` is derived from the last row of *this*
/// page, so the caller never has to know which column the sort used.
public struct MediaPage: Sendable, Hashable {
    public var items: [MediaItem]
    public var nextCursor: SortCursor?
    public var hasMore: Bool

    public init(items: [MediaItem], nextCursor: SortCursor?, hasMore: Bool) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }

    public static let empty = MediaPage(items: [], nextCursor: nil, hasMore: false)
}
