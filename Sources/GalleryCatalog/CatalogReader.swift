import Foundation
import GalleryDomain
import GallerySQLite

/// One page of ids in ascending order.
public struct IDPage: Sendable, Hashable {
    public var ids: [MediaID]
    public var hasMore: Bool

    public init(ids: [MediaID], hasMore: Bool) {
        self.ids = ids
        self.hasMore = hasMore
    }
}

/// The aggregate the selection bar and the aggregate inspector show for a whole-album selection.
public struct SelectionSummary: Sendable, Hashable {
    public var total: Int
    public var images: Int
    public var videos: Int
    public var byteSize: Int64
    public var favorites: Int

    public init(total: Int, images: Int, videos: Int, byteSize: Int64, favorites: Int) {
        self.total = total
        self.images = images
        self.videos = videos
        self.byteSize = byteSize
        self.favorites = favorites
    }
}

/// The read side. A second connection, opened `SQLITE_OPEN_READONLY`, is what lets the grid keep scrolling
/// while a 100k-file scan is mid-batch — WAL gives the reader a snapshot instead of a queue behind the
/// writer, and `query_only=ON` means a bug in this file cannot corrupt the catalog.
public actor CatalogReader {
    private let handle: SQLiteHandle

    private init(handle: SQLiteHandle) {
        self.handle = handle
    }

    public static func open(at url: URL) throws -> CatalogReader {
        let handle = try SQLiteHandle.open(path: url.path, kind: .readOnly)
        return CatalogReader(handle: handle)
    }

    /// A database written by a newer build is browsable, not broken. The caller opens read-only after
    /// `Catalog.open` refuses it, so the user sees their library and a reason instead of an empty window.
    public var isStaleSchema: Bool {
        get throws { (try handle.userVersion()) > Schema.version }
    }

    // MARK: - Paging

    /// Keyset paging against `sort`. The sort expression is also selected under an alias, because the next
    /// page's cursor has to be read back from whatever the ordering actually compared — `OFFSET` would avoid
    /// that plumbing and would still be walking every skipped row at 100k.
    public func page(
        album: AlbumKind,
        sort: MediaSort = .default,
        after cursor: SortCursor? = nil,
        limit: Int = 200
    ) throws -> MediaPage {
        let compiled = AlbumQuery.compile(album)
        var sql = """
        SELECT \(CatalogRow.itemSelectList), \(sort.field.columnSQL) AS sort_value
        \(CatalogRow.itemFrom)
        WHERE \(compiled.whereSQL)
        """
        var arguments = compiled.arguments

        if let cursor {
            sql += " AND \(sort.keysetPredicateSQL)"
            arguments.append(contentsOf: cursorValue(cursor.primary))
            arguments.append(.integer(cursor.id))
        }

        sql += " ORDER BY \(sort.orderBySQL) LIMIT ?"
        // One extra row answers "is there another page" without a second COUNT(*) query.
        arguments.append(.integer(Int64(limit + 1)))

        let rows = try handle.query(sql, arguments)
        guard !rows.isEmpty else { return .empty }

        let hasMore = rows.count > limit
        let kept = hasMore ? Array(rows.dropLast()) : rows
        let items = try kept.map(CatalogRow.item)
        let nextCursor = hasMore && kept.count > 0 ? try sortCursor(from: kept[kept.count - 1]) : nil
        return MediaPage(items: items, nextCursor: nextCursor, hasMore: hasMore)
    }

    private func sortCursor(from row: Row) throws -> SortCursor {        let value = try row.value(named: "sort_value")
        let primary: CursorValue = switch value {
        case .integer(let v): .integer(v)
        case .real(let v): .real(v)
        case .text(let v): .text(v)
        case .blob, .null: .integer(0)
        }
        return SortCursor(primary: primary, id: try row.int64(named: "id"))
    }

    private func cursorValue(_ value: CursorValue) -> [Value] {
        switch value {
        case .integer(let v): [.integer(v)]
        case .real(let v): [.real(v)]
        case .text(let v): [.text(v)]
        }
    }

    public func item(id: MediaID) throws -> MediaItem? {
        let rows = try handle.query(
            "SELECT \(CatalogRow.itemSelectList) \(CatalogRow.itemFrom) WHERE media.id = ?",
            [.integer(id.rawValue)]
        )
        return try rows.first.map(CatalogRow.item)
    }

    public func items(ids: [MediaID]) throws -> [MediaItem] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        return try handle.query(
            "SELECT \(CatalogRow.itemSelectList) \(CatalogRow.itemFrom) WHERE media.id IN (\(placeholders))",
            ids.map { .integer($0.rawValue) }
        ).map(CatalogRow.item)
    }

    public func count(album: AlbumKind) throws -> Int {
        let compiled = AlbumQuery.compile(album)
        let value = try handle.firstValue(
            "SELECT COUNT(*) \(CatalogRow.itemFrom) WHERE \(compiled.whereSQL)",
            compiled.arguments
        )
        return Int(value?.int64OrZero ?? 0)
    }

    // MARK: - Whole-album selection

    /// One page of ids in ascending id order. A whole-album selection is resolved with this: the cursor is
    /// the last id seen, and `upperBound` (frozen when the user confirmed an action) keeps rows scanned later
    /// out of it.
    public func ids(
        album: AlbumKind, after cursor: MediaID? = nil, upperBound: MediaID? = nil, limit: Int = 500
    ) throws -> IDPage {
        let compiled = AlbumQuery.compile(album)
        var sql = "SELECT media.id FROM media LEFT JOIN favorite ON favorite.media_id = media.id WHERE \(compiled.whereSQL)"
        var arguments = compiled.arguments
        if let cursor {
            sql += " AND media.id > ?"
            arguments.append(.integer(cursor.rawValue))
        }
        if let upperBound {
            sql += " AND media.id <= ?"
            arguments.append(.integer(upperBound.rawValue))
        }
        sql += " ORDER BY media.id LIMIT ?"
        arguments.append(.integer(Int64(limit + 1)))

        let rows = try handle.query(sql, arguments)
        let hasMore = rows.count > limit
        let kept = hasMore ? Array(rows.dropLast()) : rows
        return IDPage(ids: try kept.map { MediaID(rawValue: try $0.int64(named: "id")) },
                      hasMore: hasMore)
    }

    /// The same page as `ids`, as full rows — what a batch action consumes.
    public func items(
        album: AlbumKind, after cursor: MediaID? = nil, upperBound: MediaID? = nil, limit: Int = 200
    ) throws -> [MediaItem] {
        let compiled = AlbumQuery.compile(album)
        var sql = "SELECT \(CatalogRow.itemSelectList) \(CatalogRow.itemFrom) WHERE \(compiled.whereSQL)"
        var arguments = compiled.arguments
        if let cursor {
            sql += " AND media.id > ?"
            arguments.append(.integer(cursor.rawValue))
        }
        if let upperBound {
            sql += " AND media.id <= ?"
            arguments.append(.integer(upperBound.rawValue))
        }
        sql += " ORDER BY media.id LIMIT ?"
        arguments.append(.integer(Int64(limit)))
        return try handle.query(sql, arguments).map(CatalogRow.item)
    }

    /// The reverse of `liveCompanions`: companion id → still id. Selecting only the video half has to pull
    /// the still into the same rename, or the pair stops being a pair on the next walk.
    public func liveStills(of ids: [MediaID]) throws -> [MediaID: MediaID] {
        guard !ids.isEmpty else { return [:] }
        var result: [MediaID: MediaID] = [:]
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + 500, ids.count)])
            let rows = try items(ids: chunk)
            var folders: [String: [MediaItem]] = [:]
            for row in rows where row.subtype.contains(.livePhotoCompanion) {
                folders["\(row.sourceID.rawValue)|\(row.parentDirectory)", default: []].append(row)
            }
            for (_, companions) in folders {
                guard let first = companions.first else { continue }
                let siblings = try handle.query(
                    """
                    SELECT \(CatalogRow.itemSelectList) \(CatalogRow.itemFrom)
                    WHERE media.src_id = ? AND media.parent_rel = ? AND (media.subtype & ?) <> 0
                    """,
                    [.integer(first.sourceID.rawValue), .text(first.parentDirectory),
                     .integer(Int64(MediaSubtype.livePhoto.rawValue))]
                ).map(CatalogRow.item)
                for companion in companions {
                    let stem = Self.foldedStem(companion.name)
                    if let still = siblings.first(where: { Self.foldedStem($0.name) == stem }) {
                        result[companion.id] = still.id
                    }
                }
            }
            index += chunk.count
        }
        return result
    }

    /// Which of these ids still belong to the album. Pruning an explicit selection against the album, rather
    /// than against the loaded page, is what keeps a reload from silently dropping off-page selections.
    public func ids(in album: AlbumKind, among ids: [MediaID]) throws -> Set<MediaID> {
        guard !ids.isEmpty else { return [] }
        let compiled = AlbumQuery.compile(album)
        var alive: Set<MediaID> = []
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + 500, ids.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let rows = try handle.query(
                "SELECT media.id FROM media LEFT JOIN favorite ON favorite.media_id = media.id WHERE \(compiled.whereSQL) AND media.id IN (\(placeholders))",
                compiled.arguments + chunk.map { .integer($0.rawValue) }
            )
            for row in rows {
                alive.insert(MediaID(rawValue: try row.int64(named: "id")))
            }
            index += chunk.count
        }
        return alive
    }

    /// Frozen at confirmation so the action cannot grow while the user reads the dialog.
    public func maxMediaID() throws -> MediaID? {
        guard let value = try handle.firstValue("SELECT MAX(media.id) FROM media"),
              case .integer(let id) = value, id > 0 else {
            return nil
        }
        return MediaID(rawValue: id)
    }

    /// Category shelf counts, with feedback applied exactly as the album query applies it.
    public func categoryCounts(minimumItems: Int = 1) throws -> [CategoryCount] {
        try handle.query(
            """
            SELECT CASE WHEN cf.verdict > 0 THEN cf.category ELSE media.category END AS category,
                   COUNT(*) AS count
            FROM media LEFT JOIN category_feedback AS cf ON cf.media_id = media.id
            WHERE media.trash = 0
              AND (cf.verdict > 0
                   OR (media.category <> 0 AND COALESCE(cf.verdict, 1) > 0))
            GROUP BY 1 HAVING COUNT(*) >= ?
            ORDER BY count DESC
            """,
            [.integer(Int64(minimumItems))]
        ).compactMap { row in
            guard let category = MediaCategory(rawValue: Int16(truncatingIfNeeded:
                try row.int64(named: "category"))) else { return nil }
            return CategoryCount(category: category, count: Int(try row.int64(named: "count")))
        }
    }

    /// The stored evidence for a row, for the inspector's reason chips.
    public func categoryEvidence(ids: [MediaID]) throws -> [MediaID: CategoryEvidence] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let rows = try handle.query(
            """
            SELECT media_id, version, revision, category, confidence, score, reasons_json, sampled_side,
                   has_alpha, transparent_ratio, color_count, flat_ratio, edge_ratio
            FROM media_category WHERE media_id IN (\(placeholders))
            """,
            ids.map { .integer($0.rawValue) }
        )
        var result: [MediaID: CategoryEvidence] = [:]
        for row in rows {
            let reasonsJSON = try row.optionalString(named: "reasons_json")
            let reasons = reasonsJSON.flatMap { text in
                try? JSONDecoder().decode([CategoryReason].self, from: Data(text.utf8))
            } ?? []
            let category = MediaCategory(rawValue: Int16(truncatingIfNeeded:
                try row.int64(named: "category"))) ?? .none
            result[MediaID(rawValue: try row.int64(named: "media_id"))] = CategoryEvidence(
                category: category,
                confidence: try row.double(named: "confidence"),
                score: try row.double(named: "score"),
                reasons: reasons,
                version: Int(try row.int64(named: "version")),
                revision: try row.string(named: "revision")
            )
        }
        return result
    }

    /// One classified row with everything a human reviewer needs to judge it: what the catalog shows, what
    /// the classifier recorded, and the user's feedback if any. This is the export the category plan's
    /// accuracy audit needs; it is a report, not a second source of truth.
    public struct CategoryAuditRow: Sendable, Hashable {
        public var mediaID: MediaID
        public var relativePath: String
        public var name: String
        public var storedCategory: MediaCategory
        public var storedConfidence: Double
        public var feedbackCategory: MediaCategory?
        public var feedbackVerdict: Int?
        public var evidence: CategoryEvidence?
        public var sampledSide: Int?
        public var version: Int?
        public var revision: String?

        public init(
            mediaID: MediaID, relativePath: String, name: String,
            storedCategory: MediaCategory, storedConfidence: Double,
            feedbackCategory: MediaCategory? = nil, feedbackVerdict: Int? = nil,
            evidence: CategoryEvidence? = nil, sampledSide: Int? = nil,
            version: Int? = nil, revision: String? = nil
        ) {
            self.mediaID = mediaID
            self.relativePath = relativePath
            self.name = name
            self.storedCategory = storedCategory
            self.storedConfidence = storedConfidence
            self.feedbackCategory = feedbackCategory
            self.feedbackVerdict = feedbackVerdict
            self.evidence = evidence
            self.sampledSide = sampledSide
            self.version = version
            self.revision = revision
        }

        /// What the shelves actually show, feedback folded in exactly as the album query folds it.
        public var effectiveCategory: MediaCategory {
            guard let verdict = feedbackVerdict, let category = feedbackCategory else {
                return storedCategory
            }
            if verdict > 0 { return category }
            if verdict < 0 { return MediaCategory.none }
            return storedCategory
        }
    }

    public func categoryAuditRows(limit: Int = 100_000) throws -> [CategoryAuditRow] {
        try handle.query(
            """
            SELECT media.id, media.rel_path, media.name, media.category, media.category_confidence,
                   cf.category AS feedback_category, cf.verdict AS feedback_verdict,
                   mc.version, mc.revision, mc.category AS evidence_category, mc.confidence,
                   mc.score, mc.reasons_json, mc.sampled_side
            FROM media
            LEFT JOIN media_category AS mc ON mc.media_id = media.id
            LEFT JOIN category_feedback AS cf ON cf.media_id = media.id
            WHERE media.trash = 0 AND media.kind = 0 AND media.category_stage = 2
            ORDER BY media.category, media.category_confidence DESC, media.id
            LIMIT ?
            """,
            [.integer(Int64(limit))]
        ).map { row in
            let reasonsJSON = try row.optionalString(named: "reasons_json")
            let reasons = reasonsJSON.flatMap { text in
                try? JSONDecoder().decode([CategoryReason].self, from: Data(text.utf8))
            } ?? []
            let evidenceCategory = MediaCategory(rawValue: Int16(truncatingIfNeeded:
                try row.int64(named: "evidence_category"))) ?? .none
            let evidence = try row.optionalInt64(named: "version").map { _ in
                CategoryEvidence(
                    category: evidenceCategory,
                    confidence: try row.double(named: "confidence"),
                    score: try row.double(named: "score"),
                    reasons: reasons,
                    version: Int(try row.int64(named: "version")),
                    revision: try row.string(named: "revision")
                )
            }
            return CategoryAuditRow(
                mediaID: MediaID(rawValue: try row.int64(named: "id")),
                relativePath: try row.string(named: "rel_path"),
                name: try row.string(named: "name"),
                storedCategory: MediaCategory(rawValue: Int16(truncatingIfNeeded:
                    try row.int64(named: "category"))) ?? .none,
                storedConfidence: try row.double(named: "category_confidence"),
                feedbackCategory: try row.optionalInt64(named: "feedback_category").map {
                    MediaCategory(rawValue: Int16(truncatingIfNeeded: $0)) ?? .none
                },
                feedbackVerdict: try row.optionalInt64(named: "feedback_verdict").map(Int.init),
                evidence: evidence,
                sampledSide: try row.optionalInt64(named: "sampled_side").map(Int.init),
                version: try row.optionalInt64(named: "version").map(Int.init),
                revision: try row.optionalString(named: "revision")
            )
        }
    }

    /// The perceptual hash the analysis pass stored for a still.
    public func dhash(for mediaID: MediaID) throws -> UInt64? {
        let value = try handle.firstValue(
            "SELECT dhash FROM media_analysis WHERE media_id = ?", [.integer(mediaID.rawValue)]
        )
        guard case .integer(let raw)? = value else { return nil }
        return UInt64(bitPattern: raw)
    }

    /// Visually similar stills by Hamming distance on the stored 64-bit hash, nearest first. A full scan of
    /// the hashes is a few megabytes and a trivial XOR loop; the alternative — an index on a bit pattern no
    /// SQLite operator understands — is a table nobody keeps in sync.
    public func similarIDs(
        to dhash: UInt64, maxDistance: Int = 6, limit: Int = 1_000, scanLimit: Int = 50_000
    ) throws -> [(id: MediaID, distance: Int)] {
        let rows = try handle.query(
            """
            SELECT media_analysis.media_id AS id, media_analysis.dhash AS dhash
            FROM media_analysis JOIN media ON media.id = media_analysis.media_id
            WHERE media.trash = 0 AND media.analysis_stage = 2 AND media_analysis.dhash IS NOT NULL
            ORDER BY media_analysis.analyzed_ns DESC LIMIT ?
            """,
            [.integer(Int64(scanLimit))]
        )
        var matches: [(MediaID, Int)] = []
        for row in rows {
            guard let raw = try row.optionalInt64(named: "dhash") else { continue }
            let distance = (dhash ^ UInt64(bitPattern: raw)).nonzeroBitCount
            if distance <= maxDistance {
                matches.append((MediaID(rawValue: try row.int64(named: "id")), distance))
            }
        }
        return matches.sorted { $0.1 < $1.1 }.prefix(limit).map { $0 }
    }

    /// The Live Photo partner of each still, when both halves are in the library. Pass A pairs by directory,
    /// stem and a two-second window; this re-derives the same rule for the rename planner, which must move
    /// both halves together or lose the pair.
    public func liveCompanions(of ids: [MediaID]) throws -> [MediaID: MediaID] {
        guard !ids.isEmpty else { return [:] }
        var result: [MediaID: MediaID] = [:]
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + 500, ids.count)])
            let rows = try items(ids: chunk)
            var folders: [String: [MediaItem]] = [:]
            for row in rows where row.subtype.contains(.livePhoto) {
                folders["\(row.sourceID.rawValue)|\(row.parentDirectory)", default: []].append(row)
            }
            for (_, stills) in folders {
                guard let first = stills.first else { continue }
                let siblings = try handle.query(
                    """
                    SELECT \(CatalogRow.itemSelectList) \(CatalogRow.itemFrom)
                    WHERE media.src_id = ? AND media.parent_rel = ? AND (media.subtype & ?) <> 0
                    """,
                    [.integer(first.sourceID.rawValue), .text(first.parentDirectory),
                     .integer(Int64(MediaSubtype.livePhotoCompanion.rawValue))]
                ).map(CatalogRow.item)
                for still in stills {
                    let stem = Self.foldedStem(still.name)
                    if let companion = siblings.first(where: { Self.foldedStem($0.name) == stem }) {
                        result[still.id] = companion.id
                    }
                }
            }
            index += chunk.count
        }
        return result
    }

    private static func foldedStem(_ name: String) -> String {
        (name as NSString).deletingPathExtension
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// What the selection bar and the aggregate inspector say about a whole-album selection.
    public func selectionSummary(album: AlbumKind) throws -> SelectionSummary {
        let compiled = AlbumQuery.compile(album)
        let rows = try handle.query(
            """
            SELECT COUNT(*) AS total,
                   COALESCE(SUM(CASE WHEN media.kind = 0 THEN 1 ELSE 0 END), 0) AS images,
                   COALESCE(SUM(CASE WHEN media.kind = 1 THEN 1 ELSE 0 END), 0) AS videos,
                   COALESCE(SUM(media.size_bytes), 0) AS bytes,
                   COALESCE(SUM(CASE WHEN favorite.media_id IS NULL THEN 0 ELSE 1 END), 0) AS favorites
            FROM media LEFT JOIN favorite ON favorite.media_id = media.id
            WHERE \(compiled.whereSQL)
            """,
            compiled.arguments
        )
        let row = rows.first
        return SelectionSummary(
            total: Int(try row?.int64(named: "total") ?? 0),
            images: Int(try row?.int64(named: "images") ?? 0),
            videos: Int(try row?.int64(named: "videos") ?? 0),
            byteSize: try row?.int64(named: "bytes") ?? 0,
            favorites: Int(try row?.int64(named: "favorites") ?? 0)
        )
    }

    /// One row per album, ordered the way the sidebar shows them. `COUNT(*)` here is the same predicate the
    /// grid will run, which is what makes a badge and a page agree by construction rather than by luck.
    public func albums(of kind: AlbumKind) throws -> [Album] {
        switch kind {
        case .folder(let sourceID):
            return try folderAlbums(sourceID: sourceID)
        case .all, .allPhotos, .allVideos:
            let compiled = AlbumQuery.compile(kind)
            let count = try handle.firstValue(
                "SELECT COUNT(*) \(CatalogRow.itemFrom) WHERE \(compiled.whereSQL)", compiled.arguments
            )?.int64OrZero ?? 0
            return [Album(
                id: AlbumID(rawValue: Album.syntheticID(for: kind)),
                kind: kind, title: AlbumTitles.title(for: kind),
                itemCount: Int(count), sortKey: 0
            )]
        default:
            return []
        }
    }

    /// Subfolder albums, one level deep per source, each with its cover taken from the highest-ranked item
    /// that already has a thumbnail rather than from whichever row the walker happened to reach first.
    private func folderAlbums(sourceID: SourceID) throws -> [Album] {
        try handle.query(
            """
            SELECT media.parent_rel AS path, COUNT(*) AS item_count,
                   (SELECT id FROM media AS inner_media
                     WHERE inner_media.src_id = media.src_id AND inner_media.parent_rel = media.parent_rel
                       AND inner_media.trash = 0 AND inner_media.stage = 3
                     ORDER BY inner_media.aesthetic DESC, inner_media.cap_utc DESC, inner_media.id DESC
                     LIMIT 1) AS cover_id
            FROM media
            WHERE media.src_id = ? AND media.trash = 0 AND media.parent_rel <> ''
            GROUP BY media.parent_rel
            ORDER BY media.parent_rel
            """,
            [.integer(sourceID.rawValue)]
        ).map { row in
            let path = try row.string(named: "path")
            let kind = AlbumKind.subfolder(sourceID, relativePath: path)
            return Album(
                id: AlbumID(rawValue: Album.syntheticID(for: kind)),
                kind: kind,
                title: URL(fileURLWithPath: path).lastPathComponent,
                coverMediaID: try row.optionalInt64(named: "cover_id").map(MediaID.init(rawValue:)),
                itemCount: Int(try row.int64(named: "item_count")),
                sortKey: 0
            )
        }
    }

    /// Date albums. The `HAVING` threshold is the difference between a ~400-row sidebar and a 9,000-row one
    /// on a real library: single-photo days are noise, and they are also the days most likely to be a
    /// corrupt-EXIF artifact.
    public func dateAlbums(minimumItems threshold: Int = 3) throws -> [Album] {
        let rows = try handle.query(
            """
            SELECT cap_day AS bucket, COUNT(*) AS item_count
            FROM media WHERE trash = 0 AND cap_day <> 0
            GROUP BY cap_day HAVING COUNT(*) >= ?
            ORDER BY cap_day DESC
            """,
            [.integer(Int64(threshold))]
        )
        return try rows.map { row in
            Album.day(Int32(truncatingIfNeeded: try row.int64(named: "bucket")),
                      count: Int(try row.int64(named: "item_count")))
        }
    }

    public func monthAlbums() throws -> [Album] {
        try handle.query(
            """
            SELECT cap_month AS bucket, COUNT(*) AS item_count
            FROM media WHERE trash = 0 AND cap_month <> 0
            GROUP BY cap_month ORDER BY cap_month DESC
            """
        ).map { row in
            Album.month(Int32(truncatingIfNeeded: try row.int64(named: "bucket")),
                        count: Int(try row.int64(named: "item_count")))
        }
    }

    public func locationAlbums() throws -> [Album] {
        try handle.query(LocationStatements.allClusters).map { row in
            let cluster = try CatalogRow.locationCluster(row)
            return Album(
                id: AlbumID(rawValue: Album.syntheticID(for: .location(cluster.id))),
                kind: .location(cluster.id),
                // A cluster that has not been geocoded yet is still an album: `title` falls back to the
                // coordinate label, which is what an offline library shows and the plan promises.
                title: cluster.title,
                subtitle: cluster.placemark?.country,
                itemCount: cluster.count,
                sortKey: -Int64(cluster.count)
            )
        }
    }

    /// Tag albums: one per curated slug that has enough photos to be a shelf row. The cover is the tag's
    /// highest-aesthetic member, which is one index seek thanks to `media_tag_slug`.
    public func tagAlbums(minimumItems threshold: Int = 3) throws -> [Album] {
        try handle.query(AnalysisStatements.tagAlbums, [.integer(Int64(threshold))]).map { row in
            let slug = try row.string(named: "slug")
            let kind = AlbumKind.tag(TagKey(slug: slug))
            return Album(
                id: AlbumID(rawValue: Album.syntheticID(for: kind)),
                kind: kind,
                title: TagVocabulary.title(for: slug),
                coverMediaID: try row.optionalInt64(named: "cover_id").map(MediaID.init(rawValue:)),
                itemCount: Int(try row.int64(named: "item_count")),
                sortKey: -Int64(try row.int64(named: "item_count"))
            )
        }
    }

    /// People, numbered until somebody names them. A name the user typed is never overwritten by a
    /// re-cluster, which is why the title reads the row rather than recomputing from the auto index.
    public func peopleAlbums(minimumFaces threshold: Int = 3) throws -> [Album] {
        try handle.query(AnalysisStatements.peopleAlbums, [.integer(Int64(threshold))]).map { row in
            let id = try row.int64(named: "id")
            let autoIndex = Int(try row.int64(named: "auto_index"))
            let kind = AlbumKind.person(PersonKey(stableID: id))
            return Album(
                id: AlbumID(rawValue: Album.syntheticID(for: kind)),
                kind: kind,
                title: try row.optionalString(named: "name") ?? "Person \(autoIndex)",
                coverMediaID: try row.optionalInt64(named: "cover_media_id").map(MediaID.init(rawValue:)),
                itemCount: Int(try row.int64(named: "face_count")),
                sortKey: -Int64(try row.int64(named: "face_count"))
            )
        }
    }

    /// The best shot of every duplicate set — what the grid badges while the Duplicates album is open.
    public func bestDuplicateIDs() throws -> [MediaID] {
        try handle.query(AnalysisStatements.duplicateBests).map { row in
            MediaID(rawValue: try row.int64(named: "best_id"))
        }
    }

    /// The set a photo belongs to, with the member the app would keep. Nil when the photo is not a duplicate.
    public func duplicateSet(containing mediaID: MediaID) throws -> (best: MediaID, members: [MediaID])? {
        guard let group = try handle
            .firstValue(AnalysisStatements.duplicateGroupOf, [.integer(mediaID.rawValue)])?
            .int64OrZero, group != 0 else { return nil }
        guard let best = try handle
            .firstValue("SELECT best_id FROM duplicate_group WHERE id = ?", [.integer(group)])?
            .int64OrZero, best != 0 else { return nil }
        let members = try handle.query(AnalysisStatements.membersOfDuplicateGroup, [.integer(group)])
            .map { MediaID(rawValue: try $0.int64(named: "media_id")) }
        return (MediaID(rawValue: best), members)
    }

    // MARK: - Search

    public func search(
        _ text: String,
        within album: AlbumKind? = nil,
        prefix: Bool = false,
        limit: Int = 200
    ) throws -> [SearchHit] {
        let match = SearchQuery.compile(text, prefix: prefix)
        guard let match else { return [] }

        var scope = CompiledQuery(whereSQL: "media.trash = 0", arguments: [])
        if let album { scope = scope.and(AlbumQuery.compile(album)) }

        // `MATCH` is a query-planning operator and cannot appear in a select list, so which column matched
        // is decided here rather than in SQL: `snippet` marks up only the terms that matched *its* column,
        // so the column carrying a marker is the column the user's words actually hit. A filename with a
        // literal bracket in it costs a preference, never a wrong row.
        //
        // Weights are positional: name 10, place 5, device 3, lens 2, search_text 1, tags 4, OCR 2,
        // title 12. A title is the one column a human wrote on purpose; a filename is usually a camera
        // serial, so the title sits above it. Appending the column keeps every earlier index unchanged.
        let rows = try handle.query(
            """
            SELECT \(CatalogRow.itemSelectList),
                   snippet(media_fts, 0, '[', ']', '…', 12) AS name_hit,
                   snippet(media_fts, 4, '[', ']', '…', 12) AS body_hit,
                   snippet(media_fts, 5, '[', ']', '…', 12) AS tag_hit,
                   snippet(media_fts, 6, '[', ']', '…', 12) AS text_hit,
                   snippet(media_fts, 7, '[', ']', '…', 12) AS title_hit,
                   bm25(media_fts, 10.0, 5.0, 3.0, 2.0, 1.0, 4.0, 2.0, 12.0) AS rank
            FROM media_fts
            JOIN media ON media.id = media_fts.rowid
            LEFT JOIN favorite ON favorite.media_id = media.id
            LEFT JOIN category_feedback AS cf ON cf.media_id = media.id
            WHERE media_fts MATCH ? AND \(scope.whereSQL)
            ORDER BY rank LIMIT ?
            """,
            [.text(match)] + scope.arguments + [.integer(Int64(limit))]
        )

        return try rows.map { row in
            let nameHit = try row.optionalString(named: "name_hit") ?? ""
            let bodyHit = try row.optionalString(named: "body_hit") ?? ""
            let tagHit = try row.optionalString(named: "tag_hit") ?? ""
            let textHit = try row.optionalString(named: "text_hit") ?? ""
            let titleHit = try row.optionalString(named: "title_hit") ?? ""
            // Title first (the words a person chose), then the name, then the recognised text, then the
            // tag, then the file's own vocabulary. The first column carrying a marker is the one that hit.
            let candidates: [(SearchColumn, String)] = [
                (.title, titleHit), (.name, nameHit), (.recognizedText, textHit), (.tag, tagHit),
                (.body, bodyHit),
            ]
            let hit = candidates.first { $0.1.contains("[") }
            return SearchHit(
                item: try CatalogRow.item(row),
                snippet: hit?.1 ?? nameHit,
                matched: hit?.0 ?? .name,
                rank: try row.double(named: "rank")
            )
        }
    }

    // MARK: - Source metadata for the UI

    public func sources() throws -> [FolderSource] {
        try handle.query("SELECT * FROM folder_source ORDER BY display_name COLLATE NOCASE")
            .map(CatalogRow.source)
    }

    public func source(id: SourceID) throws -> FolderSource? {
        try handle.query("SELECT * FROM folder_source WHERE id = ?", [.integer(id.rawValue)])
            .first.map(CatalogRow.source)
    }

    /// The URLs the grid needs for drag-out and the viewer needs for decoding — resolved here so the root
    /// path is joined in exactly one place, against the row the user is actually looking at.
    public func rootURLs() throws -> [SourceID: URL] {
        try sources().reduce(into: [:]) { result, source in
            result[source.id] = source.rootURL
        }
    }
}

/// Which column the query actually hit. A screenshot that matched on its recognised text and not its
/// filename is confusing without it — the row "IMG_4821.jpg" would otherwise look like a false positive.
public enum SearchColumn: String, Sendable, Hashable, Codable {
    case title
    case name
    case recognizedText
    case tag
    case body
}

public struct SearchHit: Sendable, Hashable {
    public var item: MediaItem
    public var snippet: String
    public var matched: SearchColumn
    public var rank: Double

    public init(item: MediaItem, snippet: String, matched: SearchColumn = .name, rank: Double) {
        self.item = item
        self.snippet = snippet
        self.matched = matched
        self.rank = rank
    }
}

enum AlbumTitles {
    static func title(for kind: AlbumKind) -> String {
        switch kind {
        case .all: "All Media"
        case .allPhotos: "Photos"
        case .allVideos: "Videos"
        case .favorites: "Favorites"
        case .screenshots: "Screenshots"
        case .raw: "RAW"
        case .livePhotos: "Live Photos"
        case .animated: "Animated"
        case .offline: "Not Downloaded"
        case .recentlyDeleted: "Recently Deleted"
        case .uncategorized: "Uncategorized"
        case .problems: "Problems"
        case .tag(let key): TagVocabulary.title(for: key.slug)
        case .person: "Person"
        case .duplicates: "Duplicates"
        case .duplicateGroup: "Duplicate Set"
        default: "Album"
        }
    }
}
