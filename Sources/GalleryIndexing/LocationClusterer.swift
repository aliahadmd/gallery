import Foundation
import GalleryDomain

/// Turns a pile of GPS points into the places the sidebar calls albums.
///
/// Two steps, both deterministic: quantise each point into a cell of about five kilometres, then union the
/// cells that touch, because a beach that straddles a cell boundary is one place and not two. The result is
/// a partition of the points, each part carrying a centre, a radius and an id that survives a recompute —
/// the sidebar's selection is a cluster id, and an id that moved on every scan would move it with it.
///
/// Deliberately arithmetic, not DBSCAN-with-parameters: a library is a set of holidays, not a density
/// estimate, and a fixed cell means the same photos always produce the same albums.
public struct LocationClusterer: Sendable {
    public struct Result: Sendable, Hashable {
        public var id: ClusterID
        public var center: GPSPoint
        public var radiusMeters: Double
        public var members: [MediaID]

        public var count: Int { members.count }
    }

    /// A day with two photos at one place is not an album; three is the same threshold the date shelves use.
    public var minimumPhotos: Int
    /// About 5.5 km at the equator. Coarse enough that one holiday is one cluster, fine enough that two
    /// towns an hour apart stay apart.
    public var cellDegrees: Double

    public init(minimumPhotos: Int = 3, cellDegrees: Double = 0.05) {
        self.minimumPhotos = max(1, minimumPhotos)
        self.cellDegrees = max(0.001, cellDegrees)
    }

    private struct Cell: Hashable {
        var lat: Int32
        var lon: Int32
    }

    public func cluster(_ inputs: [GeotaggedPoint]) -> [Result] {
        var byCell: [Cell: [GeotaggedPoint]] = [:]
        for input in inputs where input.gps.isValid {
            byCell[cell(for: input.gps), default: []].append(input)
        }
        guard !byCell.isEmpty else { return [] }

        let parent = unions(of: byCell)

        var groups: [Cell: [GeotaggedPoint]] = [:] 
        for (cell, inputs) in byCell {
            let root = find(cell, parent: parent)
            groups[root, default: []].append(contentsOf: inputs)
        }

        return groups.compactMap { anchor, members -> Result? in
            guard members.count >= minimumPhotos else { return nil }
            let latitude = members.reduce(0.0) { $0 + $1.gps.latitude } / Double(members.count)
            let longitude = members.reduce(0.0) { $0 + $1.gps.longitude } / Double(members.count)
            let center = GPSPoint(latitude: latitude, longitude: longitude)
            let radius = members.reduce(0.0) { max($0, haversineKilometers(center, $1.gps) * 1000) }
            return Result(
                // The anchor cell, not the centre: a photo added at the edge of a holiday moves the mean
                // but rarely moves the smallest cell, and the sidebar's selection is this id.
                id: ClusterID(rawValue: fnv1aID("loc:\(anchor.lat),\(anchor.lon)")),
                center: center,
                radiusMeters: radius,
                members: members.map(\.mediaID).sorted { $0.rawValue < $1.rawValue }
            )
        }
        .sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.id.rawValue < rhs.id.rawValue : lhs.count > rhs.count
        }
    }

    private func cell(for gps: GPSPoint) -> Cell {
        Cell(lat: Int32((gps.latitude / cellDegrees).rounded(.down)),
             lon: Int32((gps.longitude / cellDegrees).rounded(.down)))
    }

    /// Eight-neighbour union over the occupied cells. Only occupied cells exist in the map, so a coast with
    /// a bay in the middle still merges along the land.
    private func unions(of cells: [Cell: [GeotaggedPoint]]) -> [Cell: Cell] {
        var parent: [Cell: Cell] = [:]
        for cell in cells.keys { parent[cell] = cell }

        for cell in cells.keys {
            for deltaLat in -1...1 {
                for deltaLon in -1...1 where !(deltaLat == 0 && deltaLon == 0) {
                    let neighbour = Cell(lat: cell.lat + Int32(deltaLat), lon: cell.lon + Int32(deltaLon))
                    guard cells[neighbour] != nil else { continue }
                    union(cell, neighbour, parent: &parent)
                }
            }
        }
        // Flatten once so every look-up after this is a single hop.
        for cell in Array(parent.keys) { parent[cell] = find(cell, parent: parent) }
        return parent
    }

    private func find(_ cell: Cell, parent: [Cell: Cell]) -> Cell {
        var current = cell
        while let next = parent[current], next != current { current = next }
        return current
    }

    private func union(_ a: Cell, _ b: Cell, parent: inout [Cell: Cell]) {
        let rootA = find(a, parent: parent)
        let rootB = find(b, parent: parent)
        guard rootA != rootB else { return }
        // The root is the lexicographically smaller cell, so the anchor — and therefore the cluster id —
        // depends on which cells are occupied and not on the order the walk produced them.
        if (rootB.lat, rootB.lon) < (rootA.lat, rootA.lon) {
            parent[rootA] = rootB
        } else {
            parent[rootB] = rootA
        }
    }
}
