import Foundation

/// One classifier label and how sure the model was.
public struct SceneLabel: Sendable, Hashable, Codable {
    public var identifier: String
    public var confidence: Double

    public init(identifier: String, confidence: Double) {
        self.identifier = identifier
        self.confidence = confidence
    }
}

/// One face, in normalized coordinates (Vision's origin is bottom-left), with the embedding the clusterer
/// compares. `clusterID` is filled in by the worker before the row is written.
public struct DetectedFace: Sendable, Hashable {
    public var frame: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var confidence: Double
    public var quality: Double
    public var embedding: [Float]
    public var clusterID: Int64?

    public init(frame: Int = 0, x: Double, y: Double, width: Double, height: Double,
                confidence: Double, quality: Double, embedding: [Float], clusterID: Int64? = nil) {
        self.frame = frame
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.confidence = confidence
        self.quality = quality
        self.embedding = embedding
        self.clusterID = clusterID
    }

    public var area: Double { width * height }
}

/// Everything the analysis pass learned about one file, in the shape the catalog writes.
///
/// One value rather than a shopping list of setters: a hop writes all of it in one transaction, so a row
/// never has a score without its dHash, or a tag without the analysis row that explains it.
public struct MediaAnalysisResult: Sendable {
    public var mediaID: MediaID
    /// The stamp the file had when it was read. Stored so a later row can tell "same bytes" from "re-walked".
    public var statHash: UInt64
    public var version: Int
    public var revision: String
    public var analyzedAt: Date
    public var labels: [SceneLabel]
    public var ocrText: String?
    public var ocrBlockCount: Int
    public var ocrWasAccurate: Bool
    public var aesthetic: Double
    public var isUtility: Bool
    public var tags: [String]
    public var dhash: UInt64?
    public var featurePrint: [Float]?
    public var faces: [DetectedFace]
    public var frameCount: Int

    public init(mediaID: MediaID, statHash: UInt64, version: Int, revision: String,
                analyzedAt: Date = Date(), labels: [SceneLabel] = [], ocrText: String? = nil,
                ocrBlockCount: Int = 0, ocrWasAccurate: Bool = false, aesthetic: Double = 0,
                isUtility: Bool = false, tags: [String] = [], dhash: UInt64? = nil,
                featurePrint: [Float]? = nil, faces: [DetectedFace] = [], frameCount: Int = 0) {
        self.mediaID = mediaID
        self.statHash = statHash
        self.version = version
        self.revision = revision
        self.analyzedAt = analyzedAt
        self.labels = labels
        self.ocrText = ocrText
        self.ocrBlockCount = ocrBlockCount
        self.ocrWasAccurate = ocrWasAccurate
        self.aesthetic = aesthetic
        self.isUtility = isUtility
        self.tags = tags
        self.dhash = dhash
        self.featurePrint = featurePrint
        self.faces = faces
        self.frameCount = frameCount
    }
}
