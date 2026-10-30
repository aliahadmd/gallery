import Foundation
import GalleryDomain
import GallerySQLite

/// One claimed row, in the shape the analyser needs: identity, kind, and how far it has already got.
public struct AnalysisJob: Sendable, Hashable {
    public var mediaID: MediaID
    public var sourceID: SourceID
    public var kind: MediaKind
    public var subtype: MediaSubtype
    public var relativePath: String
    public var modificationDate: Date?
    public var dayBucket: Int32
    public var captureUTC: Double
    public var pixelWidth: Int32
    public var pixelHeight: Int32
    /// The file's stamp at claim time: what the analysis row records so a changed file can tell "same bytes"
    /// from "re-walked".
    public var statHash: UInt64
    /// Post-increment: the claim bumps `analysis_attempts`, and this is what the hop decides parking with.
    public var attempts: Int
}

/// How far a source's analysis has got. Counted from the same partial index the claim uses.
public struct AnalysisCounts: Sendable, Hashable {
    public var done: Int
    public var pending: Int
    public var parked: Int

    public var tracked: Int { done + pending + parked }

    public init(done: Int = 0, pending: Int = 0, parked: Int = 0) {
        self.done = done
        self.pending = pending
        self.parked = parked
    }
}

/// The SQL for the analysis pass. Claiming is a state transition on `media` rather than a queue row, so
/// there is nothing to keep in step with the table it describes — the column *is* the cursor.
enum AnalysisStatements {
    /// Newest first. Nothing on screen waits for analysis, and the files a user just imported are the ones
    /// they are most likely to look at; the partial index gives this order for free.
    ///
    /// Images and clips, minus Live Photo companions: the companion is the moving half of a picture that is
    /// already analysed, and treating it separately would double every Live Photo.
    static let claim = """
    UPDATE media SET analysis_stage = 1, analysis_attempts = analysis_attempts + 1
    WHERE id IN (
      SELECT id FROM media
      WHERE analysis_stage = 0 AND stage = 3 AND trash = 0
        AND (kind = ? OR (kind = ? AND (subtype & ?) = 0))
      ORDER BY cap_day DESC, id DESC
      LIMIT ?
    )
    RETURNING id, src_id, kind, subtype, rel_path, mtime_ns, cap_day, cap_utc, px_w, px_h, stat_hash,
              analysis_attempts
    """

    static let releaseClaims = "UPDATE media SET analysis_stage = 0 WHERE id IN (%@)"
    static let parkClaims = "UPDATE media SET analysis_stage = 3 WHERE id IN (%@)"
    /// A kill -9 leaves rows claimed. One consumer per process, like pass B, so a session reset is safe.
    static let resetStaleClaims = "UPDATE media SET analysis_stage = 0 WHERE analysis_stage = 1"

    static let counts = """
    SELECT
      COALESCE(SUM(CASE WHEN analysis_stage = 2 THEN 1 ELSE 0 END), 0) AS done,
      COALESCE(SUM(CASE WHEN analysis_stage < 2 THEN 1 ELSE 0 END), 0) AS pending,
      COALESCE(SUM(CASE WHEN analysis_stage = 3 THEN 1 ELSE 0 END), 0) AS parked
    FROM media
    WHERE stage = 3 AND trash = 0
      AND (kind = ? OR (kind = ? AND (subtype & ?) = 0))
      AND (? IS NULL OR src_id = ?)
    """

    /// `aesthetic` and `is_utility` are on `media` because the sort and the cover queries read them as plain
    /// columns; the tags and the recognised text are the two FTS sources.
    /// New analysis results invalidate the category verdict built on the old ones. The stage goes back to
    /// zero even on a re-analysis, because labels, OCR and faces are exactly the evidence the classifier
    /// consumes; leaving `category_stage = 2` would keep the shelf showing a decision nothing supports.
    static let finishRow = """
    UPDATE media SET analysis_stage = 2, aesthetic = ?, is_utility = ?, search_tags = ?, search_ocr = ?,
                     category = 0, category_confidence = 0, category_stage = 0, category_attempts = 0
    WHERE id = ?
    """

    static let clearDerivedText = """
    UPDATE media SET search_tags = NULL, search_ocr = NULL
    WHERE src_id = ? AND analysis_stage = 0 AND (search_tags IS NOT NULL OR search_ocr IS NOT NULL)
    """

    static let upsert = """
    INSERT INTO media_analysis (media_id, stat_hash, version, revision, analyzed_ns, labels_json,
                                ocr_chars, ocr_blocks, ocr_accurate, dhash, print_revision, print_dims,
                                print_data, face_count, frames)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(media_id) DO UPDATE SET
      stat_hash = excluded.stat_hash, version = excluded.version, revision = excluded.revision,
      analyzed_ns = excluded.analyzed_ns, labels_json = excluded.labels_json,
      ocr_chars = excluded.ocr_chars, ocr_blocks = excluded.ocr_blocks,
      ocr_accurate = excluded.ocr_accurate, dhash = excluded.dhash,
      print_revision = excluded.print_revision, print_dims = excluded.print_dims,
      print_data = excluded.print_data, face_count = excluded.face_count, frames = excluded.frames
    """

    static let deleteTags = "DELETE FROM media_tag WHERE media_id = ?"
    static let insertTag = "INSERT OR REPLACE INTO media_tag (media_id, slug, aesthetic) VALUES (?, ?, ?)"

    static let deleteFaces = "DELETE FROM face WHERE media_id = ?"
    static let insertFace = """
    INSERT INTO face (media_id, frame, x, y, w, h, confidence, quality, embedding, dims, cluster_id,
                      detected_ns)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    /// The whole library, which is what "Analyze Library Again" means. Re-analysing one folder is the reset
    /// with a `src_id` predicate, added when the UI asks for it.
    static let resetMedia = """
    UPDATE media SET analysis_stage = 0, analysis_attempts = 0, aesthetic = 0, is_utility = 0,
                     search_tags = NULL, search_ocr = NULL
    """
    static let wipeAnalysis = "DELETE FROM media_analysis"
    static let wipeTags = "DELETE FROM media_tag"
    static let wipeFaces = "DELETE FROM face"
    static let wipeDuplicateMembers = "DELETE FROM duplicate_member"
    static let wipeDuplicateGroups = "DELETE FROM duplicate_group"
    static let wipeClusters = "DELETE FROM face_cluster"

    static let tagAlbums = """
    SELECT t.slug AS slug, COUNT(*) AS item_count,
           (SELECT media_id FROM media_tag AS inner_tag
             WHERE inner_tag.slug = t.slug
             ORDER BY inner_tag.aesthetic DESC, inner_tag.media_id LIMIT 1) AS cover_id
    FROM media_tag AS t
    GROUP BY t.slug
    HAVING COUNT(*) >= ?
    ORDER BY item_count DESC, t.slug
    """

    static let peopleAlbums = """
    SELECT id, name, auto_index, face_count, cover_media_id
    FROM face_cluster
    WHERE hidden = 0 AND face_count >= ?
    ORDER BY face_count DESC, id
    """

    static let renameCluster = "UPDATE face_cluster SET name = ?, named_ns = ? WHERE id = ?"
    static let hideCluster = "UPDATE face_cluster SET hidden = ? WHERE id = ?"

    static let faceClusters = """
    SELECT id, revision, centroid, dims, face_count FROM face_cluster WHERE hidden = 0
    """

    /// `OR IGNORE` because a face id is derived from (media, face index): a re-analysis of the same photo
    /// lands on the same cluster instead of duplicating a person.
    static let insertCluster = """
    INSERT OR IGNORE INTO face_cluster (id, revision, centroid, dims, face_count, cover_media_id,
                                        created_ns)
    VALUES (?, ?, ?, ?, 1, ?, ?)
    """

    static let updateCluster = """
    UPDATE face_cluster SET centroid = ?, face_count = ? WHERE id = ?
    """

    // MARK: - Duplicates

    static let duplicateGroupOf = "SELECT group_id FROM duplicate_member WHERE media_id = ?"

    static let insertDuplicateGroup = """
    INSERT OR IGNORE INTO duplicate_group (id, member_count, created_ns, updated_ns) VALUES (?, 0, ?, ?)
    """

    static let insertDuplicateMember = """
    INSERT OR IGNORE INTO duplicate_member (group_id, media_id, distance) VALUES (?, ?, ?)
    """

    /// Count and best are recomputed in the same transaction as the insert, so the album and the "best"
    /// badge can never disagree about a group. A utility shot (a receipt, a screenshot) is never the best.
    static let refreshDuplicateGroup = """
    UPDATE duplicate_group SET
      member_count = (SELECT COUNT(*) FROM duplicate_member WHERE group_id = ?),
      best_id = (SELECT member.media_id
                 FROM duplicate_member AS member JOIN media ON media.id = member.media_id
                 WHERE member.group_id = ?
                 ORDER BY (media.is_utility = 1), media.aesthetic DESC,
                          (COALESCE(media.px_w, 0) * COALESCE(media.px_h, 0)) DESC, media.id DESC
                 LIMIT 1),
      updated_ns = ?
    WHERE id = ?
    """

    static let pruneDuplicateGroups = """
    UPDATE duplicate_group SET member_count = (
      SELECT COUNT(*) FROM duplicate_member WHERE group_id = duplicate_group.id
    );
    DELETE FROM duplicate_group WHERE member_count < 2;
    """

    static let duplicateBests = "SELECT best_id FROM duplicate_group WHERE best_id IS NOT NULL"

    static let membersOfDuplicateGroup = """
    SELECT media_id FROM duplicate_member WHERE group_id = ?
    """

    static let duplicateCandidates = """
    SELECT m.id, a.dhash, m.cap_day, m.parent_rel, m.cap_utc, m.px_w, m.px_h, m.aesthetic, m.is_utility
    FROM media AS m JOIN media_analysis AS a ON a.media_id = m.id
    WHERE m.cap_day IN (%@) AND m.trash = 0 AND a.dhash IS NOT NULL %@
    ORDER BY m.cap_day DESC, m.id DESC LIMIT ?
    """
}

/// One stored person, as the index loads it.
public struct FaceClusterRow: Sendable, Hashable {
    public var id: Int64
    public var revision: Int64
    public var centroid: [Float]
    public var dims: Int
    public var faceCount: Int
}

/// A photo that could be the same picture as the one being analysed.
public struct DuplicateCandidate: Sendable, Hashable {
    public var mediaID: MediaID
    public var dhash: UInt64
    public var dayBucket: Int32
    public var parentDirectory: String
    public var captureUTC: Double
    public var pixelWidth: Int32
    public var pixelHeight: Int32
    public var aesthetic: Double
    public var isUtility: Bool

    public init(mediaID: MediaID, dhash: UInt64, dayBucket: Int32, parentDirectory: String,
                captureUTC: Double, pixelWidth: Int32, pixelHeight: Int32, aesthetic: Double,
                isUtility: Bool) {
        self.mediaID = mediaID
        self.dhash = dhash
        self.dayBucket = dayBucket
        self.parentDirectory = parentDirectory
        self.captureUTC = captureUTC
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.aesthetic = aesthetic
        self.isUtility = isUtility
    }

    public var aspectRatio: Double {
        pixelHeight > 0 ? Double(pixelWidth) / Double(pixelHeight) : 0
    }
}

extension Catalog {
    /// Claims up to `limit` rows and marks them in flight. Rows that are not finished by this session are
    /// released by `releaseClaims` or reset by `beginSession` on the next launch.
    public func claimAnalysis(limit: Int) throws -> [AnalysisJob] {
        try handle.write {
            try handle.query(AnalysisStatements.claim, [
                .integer(Int64(MediaKind.image.rawValue)),
                .integer(Int64(MediaKind.video.rawValue)),
                .integer(Int64(MediaSubtype.livePhotoCompanion.rawValue)),
                .integer(Int64(limit)),
            ]).map(CatalogRow.analysisJob)
        }
    }

    public func releaseClaims(_ ids: [MediaID]) throws {
        try setAnalysisStage(ids, statement: AnalysisStatements.releaseClaims)
    }

    public func parkClaims(_ ids: [MediaID]) throws {
        try setAnalysisStage(ids, statement: AnalysisStatements.parkClaims)
    }

    private func setAnalysisStage(_ ids: [MediaID], statement: String) throws {
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        try handle.write {
            try handle.exec(String(format: statement, placeholders), ids.map { .integer($0.rawValue) })
        }
    }

    /// One transaction for a hop: the row's derived columns, its analysis record, its tags and its faces.
    public func recordAnalysis(_ results: [MediaAnalysisResult]) throws {
        guard !results.isEmpty else { return }
        let encoder = JSONEncoder()
        try handle.write {
            for result in results {
                let tags = result.tags.isEmpty ? nil : result.tags.joined(separator: " ")
                let ocr = result.ocrText.flatMap { $0.isEmpty ? nil : $0 }
                try handle.exec(AnalysisStatements.finishRow, [
                    .real(result.aesthetic),
                    .integer(result.isUtility ? 1 : 0),
                    tags.map(Value.text) ?? .null,
                    ocr.map(Value.text) ?? .null,
                    .integer(result.mediaID.rawValue),
                ])
                try handle.exec(AnalysisStatements.upsert, [
                    .integer(result.mediaID.rawValue),
                    .integer(Int64(bitPattern: result.statHash)),
                    .integer(Int64(result.version)),
                    .text(result.revision),
                    .integer(result.analyzedAt.nanoseconds),
                    result.labels.isEmpty ? .null
                        : .text(String(decoding: (try? encoder.encode(result.labels)) ?? Data(), as: UTF8.self)),
                    .integer(Int64(result.ocrText?.count ?? 0)),
                    .integer(Int64(result.ocrBlockCount)),
                    .integer(result.ocrWasAccurate ? 1 : 0),
                    result.dhash.map { .integer(Int64(bitPattern: $0)) } ?? .null,
                    result.featurePrint.map { _ in .integer(Int64(result.version)) } ?? .null,
                    result.featurePrint.map { .integer(Int64($0.count)) } ?? .null,
                    result.featurePrint.map { Self.blob(of: $0) } ?? .null,
                    .integer(Int64(result.faces.count)),
                    .integer(Int64(result.frameCount)),
                ])
                try handle.exec(AnalysisStatements.deleteTags, [.integer(result.mediaID.rawValue)])
                for slug in result.tags {
                    try handle.exec(AnalysisStatements.insertTag, [
                        .integer(result.mediaID.rawValue), .text(slug), .real(result.aesthetic),
                    ])
                }
                try handle.exec(AnalysisStatements.deleteFaces, [.integer(result.mediaID.rawValue)])
                let detected = result.analyzedAt.nanoseconds
                for face in result.faces {
                    try handle.exec(AnalysisStatements.insertFace, [
                        .integer(result.mediaID.rawValue),
                        .integer(Int64(face.frame)),
                        .real(face.x), .real(face.y), .real(face.width), .real(face.height),
                        .real(face.confidence), .real(face.quality),
                        Self.blob(of: face.embedding),
                        .integer(Int64(face.embedding.count)),
                        face.clusterID.map(Value.integer) ?? .null,
                        .integer(detected),
                    ])
                }
            }
        }
    }

    public func beginAnalysisSession() throws {
        try handle.write { try handle.exec(AnalysisStatements.resetStaleClaims) }
    }

    public func analysisCounts(sourceID: SourceID? = nil) throws -> AnalysisCounts {
        let id = sourceID.map { Value.integer($0.rawValue) } ?? .null
        guard let row = try handle.firstRow(AnalysisStatements.counts, [
            .integer(Int64(MediaKind.image.rawValue)),
            .integer(Int64(MediaKind.video.rawValue)),
            .integer(Int64(MediaSubtype.livePhotoCompanion.rawValue)),
            id, id,
        ]) else {
            return AnalysisCounts()
        }
        return AnalysisCounts(
            done: Int(try row.int64(named: "done")),
            pending: Int(try row.int64(named: "pending")),
            parked: Int(try row.int64(named: "parked"))
        )
    }

    /// A file whose bytes changed keeps its old OCR until this runs, which is why the analysis reset in the
    /// enumeration upsert and this clear are a pair: one marks the row, this removes what the mark invalidates.
    public func clearStaleSearchText(sourceID: SourceID) throws {
        try handle.write {
            try handle.exec(AnalysisStatements.clearDerivedText, [.integer(sourceID.rawValue)])
        }
    }

    /// "Analyze Library Again": forget everything the analyser derived and let the cursor walk the library.
    public func resetAnalysis() throws {
        try handle.write {
            try handle.exec(AnalysisStatements.wipeDuplicateMembers)
            try handle.exec(AnalysisStatements.wipeDuplicateGroups)
            try handle.exec(AnalysisStatements.wipeFaces)
            try handle.exec(AnalysisStatements.wipeClusters)
            try handle.exec(AnalysisStatements.wipeTags)
            try handle.exec(AnalysisStatements.wipeAnalysis)
            try handle.exec(AnalysisStatements.resetMedia)
        }
    }

    public func renameFaceCluster(id: Int64, name: String?) throws {        try handle.write {
            try handle.exec(AnalysisStatements.renameCluster,
                            [name.map(Value.text) ?? .null, .integer(Date().nanoseconds), .integer(id)])
        }
    }

    public func setFaceClusterHidden(id: Int64, hidden: Bool) throws {
        try handle.write {
            try handle.exec(AnalysisStatements.hideCluster, [.integer(hidden ? 1 : 0), .integer(id)])
        }
    }

    public func faceClusters() throws -> [FaceClusterRow] {
        try handle.query(AnalysisStatements.faceClusters).map { row in
            FaceClusterRow(
                id: try row.int64(named: "id"),
                revision: try row.int64(named: "revision"),
                centroid: Self.floats(from: try row.blob(named: "centroid") ?? []),
                dims: Int(try row.int64(named: "dims")),
                faceCount: Int(try row.int64(named: "face_count"))
            )
        }
    }

    public func insertFaceCluster(id: Int64, revision: Int64, centroid: [Float],
                                  coverMediaID: MediaID?) throws {
        try handle.write {
            try handle.exec(AnalysisStatements.insertCluster, [
                .integer(id),
                .integer(revision),
                Self.blob(of: centroid),
                .integer(Int64(centroid.count)),
                coverMediaID.map { .integer($0.rawValue) } ?? .null,
                .integer(Date().nanoseconds),
            ])
        }
    }

    public func updateFaceCluster(id: Int64, centroid: [Float], faceCount: Int) throws {
        try handle.write {
            try handle.exec(AnalysisStatements.updateCluster, [
                Self.blob(of: centroid), .integer(Int64(faceCount)), .integer(id),
            ])
        }
    }

    static func floats(from blob: [UInt8]) -> [Float] {
        var values: [Float] = []
        values.reserveCapacity(blob.count / 4)
        var index = 0
        while index + 4 <= blob.count {
            let bits = UInt32(blob[index]) | UInt32(blob[index + 1]) << 8
                | UInt32(blob[index + 2]) << 16 | UInt32(blob[index + 3]) << 24
            values.append(Float(bitPattern: bits))
            index += 4
        }
        return values
    }

    /// Float32 little-endian, the format Vision produces and the clusterer reads back.
    static func blob(of vector: [Float]) -> Value {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return .blob([UInt8](data))
    }

    // MARK: - Duplicates

    /// Candidates are the same days as the batch, not the whole library: a global Hamming scan is ten billion
    /// comparisons, and two photographs of the same thing are almost always taken on the same day.
    public func duplicateCandidates(days: Set<Int32>, excluding: [MediaID],
                                    limit: Int = 2_000) throws -> [DuplicateCandidate] {
        guard !days.isEmpty else { return [] }
        let dayList = Array(days).sorted()
        let dayPlaceholders = Array(repeating: "?", count: dayList.count).joined(separator: ", ")
        let exclusion = excluding.isEmpty
            ? ""
            : "AND m.id NOT IN (\(Array(repeating: "?", count: excluding.count).joined(separator: ", ")))"
        let sql = String(format: AnalysisStatements.duplicateCandidates, dayPlaceholders, exclusion)
        var arguments: [Value] = dayList.map { .integer(Int64($0)) }
        arguments.append(contentsOf: excluding.map { .integer($0.rawValue) })
        arguments.append(.integer(Int64(limit)))
        return try handle.query(sql, arguments).map(CatalogRow.duplicateCandidate)
    }

    public func duplicateGroupID(for mediaID: MediaID) throws -> Int64? {
        (try handle.firstValue(AnalysisStatements.duplicateGroupOf, [.integer(mediaID.rawValue)])?
            .int64OrZero).flatMap { $0 == 0 ? nil : $0 }
    }

    /// Join (or start) a group. Count and best are recomputed here so the album and the badge cannot drift.
    public func addToDuplicateGroup(groupID: Int64, mediaID: MediaID, distance: Int) throws {
        let now = Date().nanoseconds
        try handle.write {
            try handle.exec(AnalysisStatements.insertDuplicateGroup,
                            [.integer(groupID), .integer(now), .integer(now)])
            try handle.exec(AnalysisStatements.insertDuplicateMember,
                            [.integer(groupID), .integer(mediaID.rawValue), .integer(Int64(distance))])
            try handle.exec(AnalysisStatements.refreshDuplicateGroup,
                            [.integer(groupID), .integer(groupID), .integer(now), .integer(groupID)])
        }
    }

    /// Called at launch: a group whose members were trashed has a stale count, and a group with one member
    /// left is not a duplicate set.
    public func pruneDuplicateGroups() throws {
        try handle.write { try handle.exec(AnalysisStatements.pruneDuplicateGroups) }
    }
}
