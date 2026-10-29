import Foundation
import GalleryCatalog
import GalleryImaging

/// Decides whether two photographs are the same picture, from their perceptual hashes.
///
/// The hash alone is treated with suspicion in its grey zone. A distance of four or less is a copy; five to
/// ten needs corroboration — the same shape, and either the same folder or the same second — because two
/// unrelated flat walls can hash within ten of each other, and a "duplicate" the user disagrees with is worse
/// than one they never see.
public struct DuplicateFinder: Sendable {
    public struct Configuration: Sendable {
        /// A copy, re-encoded or resized: no corroboration needed.
        public var certainDistance: Int
        /// Plausible only with matching shape and time or place.
        public var corroboratedDistance: Int
        /// Aspect ratios within this fraction count as the same shape.
        public var aspectTolerance: Double
        /// Two frames of one burst are seconds apart.
        public var burstSeconds: Double

        public init(certainDistance: Int = 4, corroboratedDistance: Int = 10,
                    aspectTolerance: Double = 0.01, burstSeconds: Double = 3) {
            self.certainDistance = max(0, certainDistance)
            self.corroboratedDistance = max(self.certainDistance, corroboratedDistance)
            self.aspectTolerance = max(0, aspectTolerance)
            self.burstSeconds = max(0, burstSeconds)
        }
    }

    public struct Probe: Sendable, Hashable {
        public var dhash: UInt64
        public var aspectRatio: Double
        public var parentDirectory: String
        public var captureUTC: Double

        public init(dhash: UInt64, aspectRatio: Double, parentDirectory: String, captureUTC: Double) {
            self.dhash = dhash
            self.aspectRatio = aspectRatio
            self.parentDirectory = parentDirectory
            self.captureUTC = captureUTC
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The nearest plausible duplicate, with the distance that justified it.
    public func match(_ probe: Probe,
                      among candidates: [DuplicateCandidate]) -> (candidate: DuplicateCandidate,
                                                                  distance: Int)? {
        var best: (candidate: DuplicateCandidate, distance: Int)?
        for candidate in candidates {
            let distance = DHash.distance(probe.dhash, candidate.dhash)
            guard distance <= configuration.corroboratedDistance else { continue }
            if distance <= configuration.certainDistance {
                if best == nil || distance < best!.distance { best = (candidate, distance) }
                continue
            }
            let sameShape = probe.aspectRatio > 0
                && abs(candidate.aspectRatio - probe.aspectRatio) <= configuration.aspectTolerance
            let sameFolder = candidate.parentDirectory == probe.parentDirectory
            let sameMoment = abs(candidate.captureUTC - probe.captureUTC) < configuration.burstSeconds
            if sameShape, sameFolder || sameMoment, best == nil {
                best = (candidate, distance)
            }
        }
        return best
    }
}
