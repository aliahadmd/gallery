import Foundation
import Testing
@testable import GalleryIndexing
import GalleryDomain

private func point(_ id: Int64, _ latitude: Double, _ longitude: Double) -> GeotaggedPoint {
    GeotaggedPoint(mediaID: MediaID(rawValue: id),
                   gps: GPSPoint(latitude: latitude, longitude: longitude))
}

@Suite("Location clustering")
struct ClustererTests {
    @Test("One neighbourhood is one place")
    func oneNeighbourhood() {
        let clusters = LocationClusterer().cluster([
            point(1, 35.6812, 139.7671),
            point(2, 35.6815, 139.7675),
            point(3, 35.6809, 139.7668),
        ])

        #expect(clusters.count == 1)
        #expect(clusters.first?.members.count == 3)
        #expect((clusters.first?.radiusMeters ?? .infinity) < 500, "a walk around a block is not a trip")
    }

    @Test("Two cities are two places, and the busier one leads")
    func twoCities() {
        let kyoto = (0..<3).map { point(Int64(10 + $0), 35.0116, 135.7681) }
        let tokyo = (0..<4).map { point(Int64(20 + $0), 35.6812, 139.7671) }

        let clusters = LocationClusterer().cluster(kyoto + tokyo)

        #expect(clusters.count == 2)
        #expect(clusters[0].count == 4, "the sidebar shows the busiest place first")
        #expect(clusters[1].count == 3)
        #expect(Set(clusters.flatMap(\.members)).count == 7)
    }

    @Test("A beach that straddles a cell boundary is still one place")
    func straddlesBoundary() {
        // 0.05° cells put a boundary at exactly 35.65°N; these three photos sit either side of it.
        let clusters = LocationClusterer(minimumPhotos: 1).cluster([
            point(1, 35.6499, 139.7000),
            point(2, 35.6501, 139.7000),
            point(3, 35.6500, 139.7001),
        ])

        #expect(clusters.count == 1, "the cell boundary is an artefact of the grid, not of the place")
        #expect(clusters.first?.members.count == 3)
    }

    @Test("Two photos are not an album")
    func minimumPhotos() {
        let two = [point(1, 48.8584, 2.2945), point(2, 48.8585, 2.2946)]
        #expect(LocationClusterer().cluster(two).isEmpty)
        #expect(LocationClusterer().cluster(two + [point(3, 48.8583, 2.2944)]).count == 1)
    }

    @Test("A zero coordinate is not a place")
    func invalidPointsIgnored() {
        let clusters = LocationClusterer(minimumPhotos: 1).cluster([
            point(1, 0, 0),
            point(2, 91, 10),
            point(3, 10, 181),
        ])
        #expect(clusters.isEmpty)
    }

    @Test("The same photos produce the same ids in any order")
    func idsAreStable() {
        let photos = [
            point(1, 35.6812, 139.7671), point(2, 35.6815, 139.7675),
            point(3, 35.6809, 139.7668), point(4, 35.6820, 139.7660),
        ]
        let first = LocationClusterer().cluster(photos).map(\.id)
        let second = LocationClusterer().cluster(photos.reversed()).map(\.id)
        #expect(first == second, "a cluster id is what the sidebar has selected")
    }
}
