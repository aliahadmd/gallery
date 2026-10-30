import Foundation
import GalleryDomain
import GallerySQLite

/// One row the category worker is allowed to classify, with the analysis results already joined in.
public struct CategoryJob: Sendable {
    public var mediaID: MediaID
    public var sourceID: SourceID
    public var statHash: UInt64
    public var subtype: MediaSubtype
    public var name: String
    public var fileExtension: String
    public var typeIdentifier: String
    public var pixelSize: PixelSize?
    public var device: String?
    public var hasGPS: Bool
    public var hasCaptureDate: Bool
    /// Where the capture date came from. A filesystem date is not camera evidence; an EXIF date is.
    public var captureSource: CaptureSource?
    public var aesthetic: Double
    public var isUtility: Bool
    public var labelsJSON: String?
    public var ocrChars: Int
    public var ocrBlocks: Int
    public var ocrAccurate: Bool
    public var faceCount: Int
    public var dhash: Int64?

    public init(
        mediaID: MediaID, sourceID: SourceID, statHash: UInt64, subtype: MediaSubtype,
        name: String, fileExtension: String, typeIdentifier: String, pixelSize: PixelSize?,
        device: String?, hasGPS: Bool, hasCaptureDate: Bool, captureSource: CaptureSource?,
        aesthetic: Double, isUtility: Bool,
        labelsJSON: String?, ocrChars: Int, ocrBlocks: Int, ocrAccurate: Bool, faceCount: Int,
        dhash: Int64?
    ) {
        self.mediaID = mediaID
        self.sourceID = sourceID
        self.statHash = statHash
        self.subtype = subtype
        self.name = name
        self.fileExtension = fileExtension
        self.typeIdentifier = typeIdentifier
        self.pixelSize = pixelSize
        self.device = device
        self.hasGPS = hasGPS
        self.hasCaptureDate = hasCaptureDate
        self.captureSource = captureSource
        self.aesthetic = aesthetic
        self.isUtility = isUtility
        self.labelsJSON = labelsJSON
        self.ocrChars = ocrChars
        self.ocrBlocks = ocrBlocks
        self.ocrAccurate = ocrAccurate
        self.faceCount = faceCount
        self.dhash = dhash
    }
}

public struct CategoryResult: Sendable {
    public var mediaID: MediaID
    public var statHash: UInt64
    public var evidence: CategoryEvidence
    public var sampled: SampledFeatures?

    public init(mediaID: MediaID, statHash: UInt64, evidence: CategoryEvidence, sampled: SampledFeatures?) {
        self.mediaID = mediaID
        self.statHash = statHash
        self.evidence = evidence
        self.sampled = sampled
    }
}

extension Catalog {
    /// Claims a hop of stills whose analysis is done but whose category is not. The state transition is the
    /// claim, exactly like the analysis cursor.
    public func claimCategories(limit: Int, maximumAttempts: Int = 2) throws -> [CategoryJob] {
        try handle.write {
            let claimed = try handle.query(
                """
                UPDATE media SET category_stage = 1, category_attempts = category_attempts + 1
                WHERE id IN (
                  SELECT id FROM media
                  WHERE category_stage = 0 AND analysis_stage = 2 AND stage = 3 AND trash = 0
                    AND kind = 0 AND category_attempts < ?
                  ORDER BY cap_day DESC, id DESC LIMIT ?)
                RETURNING id, src_id, stat_hash, subtype, name, ext, uttype, px_w, px_h, device,
                          has_gps, cap_utc, cap_src, aesthetic, is_utility
                """,
                [.integer(Int64(maximumAttempts + 1)), .integer(Int64(limit))]
            )
            guard !claimed.isEmpty else { return [] }
            let ids = try claimed.map { try $0.int64(named: "id") }
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            var analysis: [Int64: (String?, Int, Int, Bool, Int, Int64?)] = [:]
            for row in try handle.query(
                """
                SELECT media_id, labels_json, ocr_chars, ocr_blocks, ocr_accurate, face_count, dhash
                FROM media_analysis WHERE media_id IN (\(placeholders))
                """,
                ids.map { .integer($0) }
            ) {
                analysis[try row.int64(named: "media_id")] = (
                    try row.optionalString(named: "labels_json"),
                    Int(try row.int64(named: "ocr_chars")),
                    Int(try row.int64(named: "ocr_blocks")),
                    try row.bool(named: "ocr_accurate"),
                    Int(try row.int64(named: "face_count")),
                    try row.optionalInt64(named: "dhash")
                )
            }
            return try claimed.map { row in
                let id = try row.int64(named: "id")
                let detail = analysis[id]
                let width = try row.optionalInt64(named: "px_w")
                let height = try row.optionalInt64(named: "px_h")
                return CategoryJob(
                    mediaID: MediaID(rawValue: id),
                    sourceID: SourceID(rawValue: try row.int64(named: "src_id")),
                    statHash: try row.int64(named: "stat_hash").statHashValue,
                    subtype: MediaSubtype(rawValue: Int32(truncatingIfNeeded: try row.int64(named: "subtype"))),
                    name: try row.string(named: "name"),
                    fileExtension: try row.optionalString(named: "ext") ?? "",
                    typeIdentifier: try row.string(named: "uttype"),
                    pixelSize: width != nil || height != nil
                        ? PixelSize(width: Int32(truncatingIfNeeded: width ?? 0),
                                    height: Int32(truncatingIfNeeded: height ?? 0))
                        : nil,
                    device: try row.optionalString(named: "device"),
                    hasGPS: try row.bool(named: "has_gps"),
                    hasCaptureDate: try row.double(named: "cap_utc") != 0,
                    captureSource: CaptureSource(rawValue: Int16(truncatingIfNeeded: try row.int64(named: "cap_src"))),
                    aesthetic: try row.double(named: "aesthetic"),
                    isUtility: try row.bool(named: "is_utility"),
                    labelsJSON: detail?.0,
                    ocrChars: detail?.1 ?? 0,
                    ocrBlocks: detail?.2 ?? 0,
                    ocrAccurate: detail?.3 ?? false,
                    faceCount: detail?.4 ?? 0,
                    dhash: detail?.5
                )
            }
        }
    }

    public func recordCategories(_ results: [CategoryResult]) throws {
        guard !results.isEmpty else { return }
        let encoder = JSONEncoder()
        try handle.write {
            for result in results {
                let evidence = result.evidence
                let reasons = try? encoder.encode(evidence.reasons)
                let reasonsJSON = reasons.map { String(decoding: $0, as: UTF8.self) }
                try handle.exec(
                    """
                    INSERT INTO media_category (media_id, stat_hash, version, revision, category, confidence,
                                                score, reasons_json, sampled_side, has_alpha,
                                                transparent_ratio, color_count, flat_ratio, edge_ratio,
                                                classified_ns)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(media_id) DO UPDATE SET
                      stat_hash = excluded.stat_hash, version = excluded.version,
                      revision = excluded.revision, category = excluded.category,
                      confidence = excluded.confidence, score = excluded.score,
                      reasons_json = excluded.reasons_json, sampled_side = excluded.sampled_side,
                      has_alpha = excluded.has_alpha, transparent_ratio = excluded.transparent_ratio,
                      color_count = excluded.color_count, flat_ratio = excluded.flat_ratio,
                      edge_ratio = excluded.edge_ratio, classified_ns = excluded.classified_ns
                    """,
                    [.integer(result.mediaID.rawValue), .integer(Int64(bitPattern: result.statHash)),
                     .integer(Int64(evidence.version)), .text(evidence.revision),
                     .integer(Int64(evidence.category.rawValue)), .real(evidence.confidence),
                     .real(evidence.score), reasonsJSON.map(Value.text) ?? .null,
                     result.sampled.map { .integer(Int64($0.side)) } ?? .null,
                     result.sampled.map { .integer($0.hasAlpha ? 1 : 0) } ?? .null,
                     result.sampled.map { .real($0.transparentRatio) } ?? .null,
                     result.sampled.map { .integer(Int64($0.colorCount)) } ?? .null,
                     result.sampled.map { .real($0.flatRatio) } ?? .null,
                     result.sampled.map { .real($0.edgeRatio) } ?? .null,
                     .integer(Date().nanoseconds)]
                )
                try handle.exec(
                    "UPDATE media SET category = ?, category_confidence = ?, category_stage = 2 WHERE id = ?",
                    [.integer(Int64(evidence.category.rawValue)), .real(evidence.confidence),
                     .integer(result.mediaID.rawValue)]
                )
            }
        }
    }

    /// A crash can leave rows claimed; at start they go back into the queue.
    public func resetStaleCategoryClaims() throws {
        try handle.exec("UPDATE media SET category_stage = 0 WHERE category_stage = 1")
    }

    /// A failed write must not strand the rows it claimed until the next launch. Releasing only this hop's
    /// ids leaves any other claim alone and makes the next pass retry them (until the attempt limit).
    public func releaseCategoryClaims(_ ids: [MediaID]) throws {
        guard !ids.isEmpty else { return }
        try handle.write {
            var index = 0
            while index < ids.count {
                let chunk = ids[index..<min(index + 500, ids.count)]
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                try handle.exec(
                    "UPDATE media SET category_stage = 0 WHERE category_stage = 1 AND id IN (\(placeholders))",
                    chunk.map { .integer($0.rawValue) }
                )
                index += chunk.count
            }
        }
    }

    /// Re-runs the classifier everywhere without re-running Vision. Feedback survives.
    public func resetCategories() throws {
        try handle.write {
            try handle.exec("DELETE FROM media_category")
            try handle.exec(
                "UPDATE media SET category = 0, category_confidence = 0, category_stage = 0, category_attempts = 0"
            )
        }
    }

    public func setCategoryFeedback(mediaID: MediaID, category: MediaCategory, verdict: Int) throws {
        try handle.write {
            try handle.exec(
                """
                INSERT INTO category_feedback (media_id, category, verdict, created_ns)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(media_id) DO UPDATE SET
                  category = excluded.category, verdict = excluded.verdict,
                  created_ns = excluded.created_ns
                """,
                [.integer(mediaID.rawValue), .integer(Int64(category.rawValue)),
                 .integer(Int64(verdict)), .integer(Date().nanoseconds)]
            )
        }
    }

    public func clearCategoryFeedback(mediaID: MediaID) throws {
        try handle.exec("DELETE FROM category_feedback WHERE media_id = ?", [.integer(mediaID.rawValue)])
    }

    public func categoryProgress() throws -> (pending: Int, done: Int) {
        let pending = try handle.firstValue(
            "SELECT COUNT(*) FROM media WHERE category_stage = 0 AND analysis_stage = 2 AND stage = 3 AND trash = 0 AND kind = 0"
        )?.int64OrZero ?? 0
        let done = try handle.firstValue("SELECT COUNT(*) FROM media WHERE category_stage = 2")?.int64OrZero ?? 0
        return (Int(pending), Int(done))
    }
}
