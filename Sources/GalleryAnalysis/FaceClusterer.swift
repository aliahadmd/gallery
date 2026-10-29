import Foundation

/// Decides whether a face is somebody the library already knows.
///
/// Pure arithmetic over normalized vectors, so the thresholds can be tested with synthetic embeddings instead
/// of photographs of people. The margin is the load-bearing part: without it every new face is absorbed by
/// whichever cluster happened to be nearest, and the People shelf slowly becomes one person who is everyone.
public struct FaceClusterer: Sendable {
    public struct Candidate: Sendable, Hashable {
        public var id: Int64
        public var centroid: [Float]
        public var count: Int

        public init(id: Int64, centroid: [Float], count: Int) {
            self.id = id
            self.centroid = centroid
            self.count = count
        }
    }

    public struct Configuration: Sendable {
        /// Cosine similarity a face must reach to join an existing cluster.
        public var assignThreshold: Float
        /// How much better the winner must be than the runner-up. Two people who look alike should start
        /// two clusters rather than merge into one.
        public var margin: Float

        public init(assignThreshold: Float = 0.55, margin: Float = 0.05) {
            self.assignThreshold = assignThreshold
            self.margin = margin
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Unit length, so a dot product is a cosine and a running mean stays comparable across re-clusters.
    public func normalize(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    public func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var sum: Float = 0
        for index in lhs.indices { sum += lhs[index] * rhs[index] }
        return sum
    }

    /// The cluster this face belongs to, or nil when it is somebody new.
    public func match(_ vector: [Float], among candidates: [Candidate]) -> Int64? {
        guard !candidates.isEmpty else { return nil }
        var best: (id: Int64, score: Float) = (0, -1)
        var second: Float = -1
        for candidate in candidates {
            let score = cosine(vector, candidate.centroid)
            if score > best.score {
                second = best.score
                best = (candidate.id, score)
            } else if score > second {
                second = score
            }
        }
        guard best.score >= configuration.assignThreshold else { return nil }
        // A single candidate has no runner-up; the margin then only has to beat the threshold.
        if candidates.count > 1, best.score - second < configuration.margin { return nil }
        return best.id
    }

    /// The new centroid of a cluster that just gained a face: a running mean, normalized so it stays a
    /// unit vector and the next comparison is still a cosine.
    public func centroid(merging existing: [Float], count: Int, with vector: [Float]) -> [Float] {
        guard !existing.isEmpty, existing.count == vector.count else { return normalize(vector) }
        let total = Float(max(1, count))
        let blended = zip(existing, vector).map { ($0 * total + $1) / (total + 1) }
        return normalize(blended)
    }
}
