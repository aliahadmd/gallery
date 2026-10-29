import Foundation
import GalleryCatalog
import GalleryDomain

/// Assigns each new face to a person, or starts a new one.
///
/// An actor because assignment is order-dependent: two faces from two files being analysed at once still have
/// to see the centroids the earlier one produced. The arithmetic is trivial; the serialization is the point.
///
/// Clusters are created here, at analysis time, which is what makes the People shelf fill within a minute of
/// a scan finishing. Merging clusters that greedy assignment split is a separate, rarer job.
public actor FaceIndex {
    private let catalog: Catalog
    private let clusterer: FaceClusterer
    private let revision: Int64
    private var candidates: [FaceClusterer.Candidate] = []
    private var loaded = false

    /// `revision` pins the descriptor's revision: embeddings from two revisions are not comparable, so a
    /// change starts fresh clusters rather than silently mixing two vector spaces.
    public init(catalog: Catalog, revision: Int64, clusterer: FaceClusterer = FaceClusterer()) {
        self.catalog = catalog
        self.revision = revision
        self.clusterer = clusterer
    }

    /// The same faces, with `clusterID` filled in for every one that got an embedding.
    public func assign(_ faces: [DetectedFace], mediaID: MediaID) async -> [DetectedFace] {
        guard !faces.isEmpty else { return faces }
        await load()
        var assigned: [DetectedFace] = []
        assigned.reserveCapacity(faces.count)

        for (index, var face) in faces.enumerated() {
            let vector = clusterer.normalize(face.embedding)
            if let id = clusterer.match(vector, among: candidates),
               let position = candidates.firstIndex(where: { $0.id == id }) {
                let existing = candidates[position]
                let count = existing.count + 1
                let centroid = clusterer.centroid(merging: existing.centroid, count: existing.count,
                                                  with: vector)
                candidates[position] = .init(id: id, centroid: centroid, count: count)
                try? await catalog.updateFaceCluster(id: id, centroid: centroid, faceCount: count)
                face.clusterID = id
            } else {
                // Deterministic from the photo and the face's position in it: a re-analysis of the same file
                // does not create a second person, it lands on the same cluster id.
                let id = Int64(fnv1aID("face:\(mediaID.rawValue):\(index)"))
                candidates.append(.init(id: id, centroid: vector, count: 1))
                try? await catalog.insertFaceCluster(id: id, revision: revision, centroid: vector,
                                                     coverMediaID: mediaID)
                face.clusterID = id
            }
            assigned.append(face)
        }
        return assigned
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        let rows = (try? await catalog.faceClusters()) ?? []
        candidates = rows
            .filter { $0.revision == revision }
            .map { .init(id: $0.id, centroid: $0.centroid, count: $0.faceCount) }
    }
}
