import Foundation

/// One coarse step of the indexing pipeline, reported to the HUD and to the source badge.
public enum IndexPhase: String, Sendable, Hashable, Codable, CaseIterable {
    case resolving
    case enumerating
    case sweeping
    case readingMetadata
    case deriving
    case thumbnailing
    /// The third pass: on-device analysis (tags, text, faces). Runs after the drain, never during it.
    case analyzing
    /// The cheap pass that turns stored signals into Smart-album categories. Runs after analysis.
    case categorizing
    case watching
    case finished
    case failed
}

/// Progress of a scan, aggregated per source. Values are counts, not fractions, so the HUD can say
/// "12,408 of 51,220" without a second query and survive a relaunch mid-scan.
public struct IndexProgress: Sendable, Hashable, Codable {
    public var sourceID: SourceID
    public var phase: IndexPhase
    public var discovered: Int
    public var metadataDone: Int
    public var thumbnailed: Int
    public var failed: Int
    public var queued: Int
    public var isPaused: Bool
    /// Rows the analyser has finished, when the frame comes from the third pass.
    public var analyzed: Int

    public init(
        sourceID: SourceID,
        phase: IndexPhase,
        discovered: Int = 0,
        metadataDone: Int = 0,
        thumbnailed: Int = 0,
        failed: Int = 0,
        queued: Int = 0,
        isPaused: Bool = false,
        analyzed: Int = 0
    ) {
        self.sourceID = sourceID
        self.phase = phase
        self.discovered = discovered
        self.metadataDone = metadataDone
        self.thumbnailed = thumbnailed
        self.failed = failed
        self.queued = queued
        self.isPaused = isPaused
        self.analyzed = analyzed
    }

    /// Pass A is done as soon as enumeration finishes — that is the moment the grid becomes honest, and it
    /// is reported separately from the much slower pass B so the HUD never claims to be finished when it
    /// is really still decoding.
    public var isListingComplete: Bool {
        switch phase {
        case .sweeping, .readingMetadata, .deriving, .thumbnailing, .analyzing, .categorizing,
             .watching, .finished: true
        case .resolving, .enumerating, .failed: false
        }
    }

    public var passBFraction: Double {
        guard discovered > 0 else { return 0 }
        return min(1, Double(thumbnailed) / Double(discovered))
    }

    /// The third pass gets its own fraction rather than reusing `thumbnailed`: a finished grid is not a
    /// half-analysed library, and a bar that says otherwise is a lie the user will notice.
    public var analysisFraction: Double {
        guard discovered > 0 else { return 0 }
        return min(1, Double(analyzed) / Double(discovered))
    }
}
