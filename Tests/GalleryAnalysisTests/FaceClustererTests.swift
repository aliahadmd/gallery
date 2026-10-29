import Foundation
import Testing
@testable import GalleryAnalysis

@Suite("Face clustering")
struct FaceClustererTests {
    private let clusterer = FaceClusterer()

    @Test("Vectors are normalized, so a dot product is a cosine")
    func normalization() {
        let vector = clusterer.normalize([3, 4])
        #expect(abs(vector[0] - 0.6) < 0.0001)
        #expect(abs(vector[1] - 0.8) < 0.0001)
        #expect(abs(clusterer.cosine(vector, vector) - 1) < 0.0001)
    }

    @Test("A face near a person joins them; a different face starts a new cluster")
    func assignment() {
        let known = FaceClusterer.Candidate(id: 7, centroid: clusterer.normalize([1, 0, 0]), count: 4)
        #expect(clusterer.match(clusterer.normalize([1, 0.1, 0]), among: [known]) == 7)
        #expect(clusterer.match(clusterer.normalize([0, 1, 0]), among: [known]) == nil)
    }

    @Test("Two similar people are not merged into one — the margin decides")
    func margin() {
        let first = FaceClusterer.Candidate(id: 1, centroid: clusterer.normalize([1, 0, 0]), count: 3)
        let second = FaceClusterer.Candidate(id: 2, centroid: clusterer.normalize([0.95, 0.31, 0]), count: 3)
        let between = clusterer.normalize([0.98, 0.15, 0])
        // Both clusters are plausible and neither is convincingly closer: a new person, not a coin flip.
        #expect(clusterer.match(between, among: [first, second]) == nil)
    }

    @Test("A centroid is a running mean that stays a unit vector")
    func centroid() {
        let start = clusterer.normalize([1, 0, 0])
        let merged = clusterer.centroid(merging: start, count: 4, with: clusterer.normalize([0, 1, 0]))
        let magnitude = sqrt(merged.reduce(0) { $0 + $1 * $1 })
        #expect(abs(magnitude - 1) < 0.0001)
        #expect(merged[0] > 0 && merged[1] > 0)
    }

    @Test("An empty library takes the first face as a whole cluster")
    func firstFaceBecomesACluster() {
        #expect(clusterer.match(clusterer.normalize([0.5, 0.5]), among: []) == nil)
    }
}
