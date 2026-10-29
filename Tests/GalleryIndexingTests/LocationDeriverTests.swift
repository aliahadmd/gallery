import Foundation
import Testing
@testable import GalleryIndexing
import GalleryCatalog
import GalleryDomain

/// Counts the questions it is asked and answers from a closure, so a test can be offline, wrong, or precise
/// without a network.
private actor FakeGeocoder: ReverseGeocoding {
    private(set) var calls = 0
    private let respond: @Sendable (GPSPoint) throws -> PlaceSummary

    init(_ respond: @escaping @Sendable (GPSPoint) throws -> PlaceSummary) {
        self.respond = respond
    }

    func placemark(for point: GPSPoint) async throws -> PlaceSummary {
        calls += 1
        return try respond(point)
    }
}

/// Two cities, four photos each, on a real catalog. The photos are real JPEGs because pass B's metadata is
/// what the deriver reads, and a row hand-written with `has_gps = 1` would not prove the same thing.
private struct LocationFixture {
    let library: ServiceFixture

    init() async throws { library = try await ServiceFixture() }

    var catalog: Catalog { library.catalog }
    var reader: CatalogReader { library.reader }

    func tearDown() { library.tearDown() }

    @discardableResult
    func photo(_ name: String, latitude: Double, longitude: Double) async throws -> MediaItem {
        var item = try await library.photo(name)
        item.gps = GPSPoint(latitude: latitude, longitude: longitude)
        item.stage = .metadata
        try await library.catalog.recordMetadata([item])
        return item
    }

    func seedTwoCities() async throws {
        for index in 0..<4 {
            try await photo("kyoto_\(index).jpg", latitude: 35.0116 + Double(index) * 0.0001,
                            longitude: 135.7681)
            try await photo("tokyo_\(index).jpg", latitude: 35.6812 + Double(index) * 0.0001,
                            longitude: 139.7671)
        }
    }
}

private func named(_ name: String) -> @Sendable (GPSPoint) throws -> PlaceSummary {
    { _ in PlaceSummary(name: name, locality: name, country: "Japan") }
}

private func deriver(_ library: ServiceFixture, _ geocoder: FakeGeocoder) -> LocationDeriver {
    LocationDeriver(catalog: library.catalog, geocoder: geocoder,
                    configuration: .init(throttle: .zero, maximumRequestsPerRun: 20))
}

@Suite("Location albums")
struct LocationDeriverTests {
    @Test("Geotagged photos become named place albums, and the rows know their place")
    func clustersBecomeAlbums() async throws {
        let fixture = try await LocationFixture()
        defer { fixture.tearDown() }
        var kyotoPhotos: [MediaItem] = []
        for index in 0..<4 {
            kyotoPhotos.append(try await fixture.photo("kyoto_\(index).jpg",
                                                       latitude: 35.0116 + Double(index) * 0.0001,
                                                       longitude: 135.7681))
            try await fixture.photo("tokyo_\(index).jpg",
                                    latitude: 35.6812 + Double(index) * 0.0001, longitude: 139.7671)
        }
        let geocoder = FakeGeocoder { point in
            point.latitude > 35.5 ? PlaceSummary(name: "Tokyo", country: "Japan")
                                  : PlaceSummary(name: "Kyoto", country: "Japan")
        }

        let outcome = await deriver(fixture.library, geocoder).refresh()
        #expect(outcome.clusters == 2)
        #expect(outcome.named == 2)
        #expect(await geocoder.calls == 2)

        let albums = try await fixture.reader.locationAlbums()
        #expect(albums.count == 2)
        #expect(albums.map(\.title) == ["Tokyo", "Kyoto"], "busiest first, and actually named")
        #expect(albums.map(\.itemCount) == [4, 4])

        let stored = try #require(try await fixture.reader.item(id: kyotoPhotos[0].id))
        #expect(stored.clusterID != nil, "the photo points at the album it belongs to")
        #expect(stored.placeKey?.contains("Kyoto") == true)
    }

    @Test("The second run is answered by the cache, not by Apple")
    func cacheAnswersTheSecondRun() async throws {
        let fixture = try await LocationFixture()
        defer { fixture.tearDown() }
        try await fixture.seedTwoCities()
        let geocoder = FakeGeocoder(named("Somewhere"))
        let locations = deriver(fixture.library, geocoder)

        _ = await locations.refresh()
        let callsAfterFirst = await geocoder.calls
        let second = await locations.refresh()

        #expect(callsAfterFirst == 2)
        #expect(second.requests == 0, "a name already known is not a question")
        #expect(second.reused == 2)
        #expect(await geocoder.calls == callsAfterFirst)
        #expect(try await fixture.reader.locationAlbums().count == 2)

        // The cache is written too, and it is what answers when the cluster tables are rebuilt from scratch.
        let cluster = try #require(try await fixture.catalog.locationClusters().first)
        let cached = try await fixture.catalog.cachedGeocode(key: LocationDeriver.cacheKey(for: cluster.center))
        #expect(cached?.placemark?.name == "Somewhere")
    }

    @Test("Offline still produces albums, titled by coordinate")
    func offlineStillNamesByGrid() async throws {
        let fixture = try await LocationFixture()
        defer { fixture.tearDown() }
        try await fixture.seedTwoCities()
        let geocoder = FakeGeocoder { _ in throw GeocodeError.unavailable }

        let outcome = await deriver(fixture.library, geocoder).refresh()

        #expect(outcome.unavailable)
        #expect(await geocoder.calls == 1, "one unreachable request is the answer; twenty more are not")
        let albums = try await fixture.reader.locationAlbums()
        #expect(albums.count == 2, "the photos are still grouped")
        #expect(albums.allSatisfy { $0.title.hasPrefix("Near ") },
                "an offline library says where it is, in degrees")
    }

    @Test("A coordinate with no place is recorded and not asked again")
    func noResultIsNotRetried() async throws {
        let fixture = try await LocationFixture()
        defer { fixture.tearDown() }
        try await fixture.seedTwoCities()
        let geocoder = FakeGeocoder { _ in throw GeocodeError.noResult }
        let locations = deriver(fixture.library, geocoder)

        let first = await locations.refresh()
        #expect(first.failed == 2)
        #expect(first.named == 0)

        // The failure is a dated cache entry, and the next run inside the window trusts it.
        let cluster = try #require(try await fixture.catalog.locationClusters().first)
        let entry = try await fixture.catalog.cachedGeocode(
            key: LocationDeriver.cacheKey(for: cluster.center)
        )
        #expect(entry?.didFail == true, "the failure was not recorded: \(String(describing: entry))")

        let second = await locations.refresh()
        #expect(second.requests == 0, "the ocean does not move")
        #expect(await geocoder.calls == 2)
        #expect(try await fixture.reader.locationAlbums().count == 2)
    }

    @Test("A failure older than the retry window is asked again")
    func failedGeocodeExpires() async throws {
        let fixture = try await LocationFixture()
        defer { fixture.tearDown() }
        try await fixture.seedTwoCities()
        let geocoder = FakeGeocoder { _ in throw GeocodeError.noResult }
        // A window of zero means every run is a new question — the machine that was offline an hour ago.
        let locations = LocationDeriver(catalog: fixture.library.catalog, geocoder: geocoder,
                                        configuration: .init(throttle: .zero, failureRetryWindow: 0))

        _ = await locations.refresh()
        let firstRound = await geocoder.calls
        _ = await locations.refresh()

        #expect(firstRound == 2)
        #expect(await geocoder.calls == 4, "an expired failure is a new question")
    }
}
