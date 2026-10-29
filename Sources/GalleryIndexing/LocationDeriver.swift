import Foundation
import GalleryCatalog
import GalleryDomain
import GallerySupport

/// Turns geotagged photos into place albums, and names them when the network allows.
///
/// The cluster tables are materialised rather than derived per query because clustering is geometry over the
/// whole library and because a cluster id is what the sidebar selects — an id that changed on every scan
/// would move the selection with it. Names are a *refinement*: the deriver always produces albums, and the
/// title falls back to a coordinate label, so an offline machine gets a usable sidebar instead of an error.
public actor LocationDeriver {
    public struct Configuration: Sendable {
        public var minimumPhotos: Int
        public var cellDegrees: Double
        /// Space between geocode calls. Apple rate-limits per app; a burst of places is a ban.
        public var throttle: Duration
        /// Names per run. A hundred-place library is named over a few scans rather than in one stall.
        public var maximumRequestsPerRun: Int
        /// How long a recorded failure is believed. A success is kept forever; a failure is a statement about
        /// the network at one moment, so it expires and the place is asked about again.
        public var failureRetryWindow: TimeInterval

        public init(minimumPhotos: Int = 3, cellDegrees: Double = 0.05,
                    throttle: Duration = .seconds(1), maximumRequestsPerRun: Int = 20,
                    failureRetryWindow: TimeInterval = 24 * 60 * 60) {
            self.minimumPhotos = max(1, minimumPhotos)
            self.cellDegrees = cellDegrees
            self.throttle = throttle
            self.maximumRequestsPerRun = max(0, maximumRequestsPerRun)
            self.failureRetryWindow = failureRetryWindow
        }
    }

    public struct Outcome: Sendable, Hashable {
        public var clusters = 0
        public var named = 0
        public var reused = 0
        public var cached = 0
        public var requests = 0
        public var failed = 0
        /// True when the service could not be reached, which is the airplane-mode answer.
        public var unavailable = false

        public init() {}
    }

    private let catalog: Catalog
    private let geocoder: any ReverseGeocoding
    private let configuration: Configuration
    private var isRunning = false

    public init(catalog: Catalog, geocoder: any ReverseGeocoding,
                configuration: Configuration = Configuration()) {
        self.catalog = catalog
        self.geocoder = geocoder
        self.configuration = configuration
    }

    /// Recompute the clusters, carry every name forward, then name what is left.
    ///
    /// Idempotent and safe to call after every drain: identical photos produce identical clusters, a name in
    /// either the previous run or the cache costs no request, and a recorded failure is not retried.
    public func refresh() async -> Outcome {
        guard !isRunning else { return Outcome() }
        isRunning = true
        defer { isRunning = false }

        var outcome = Outcome()
        let points = (try? await catalog.geotaggedPoints()) ?? []
        let previous = (try? await catalog.locationClusters()) ?? []
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })

        if points.isEmpty {
            if !previous.isEmpty { try? await catalog.replaceClusters([], membership: [:]) }
            return outcome
        }

        let clusters = LocationClusterer(minimumPhotos: configuration.minimumPhotos,
                                         cellDegrees: configuration.cellDegrees).cluster(points)
        var records: [LocationCluster] = []
        var membership: [ClusterID: [MediaID]] = [:]
        for cluster in clusters {
            var record = LocationCluster(id: cluster.id, center: cluster.center,
                                         radiusMeters: cluster.radiusMeters, count: cluster.count)
            if let known = previousByID[cluster.id], let placemark = known.placemark {
                record.placemark = placemark
                record.level = known.level
                outcome.reused += 1
            } else if let cached = try? await catalog.cachedGeocode(key: Self.cacheKey(for: cluster.center)),
                      let placemark = cached.placemark {
                record.placemark = placemark
                record.level = Self.level(for: placemark)
                outcome.cached += 1
            }
            records.append(record)
            membership[cluster.id] = cluster.members
        }
        try? await catalog.replaceClusters(records, membership: membership)
        outcome.clusters = records.count

        for record in records where record.placemark == nil {
            guard outcome.requests < configuration.maximumRequestsPerRun else { break }
            let key = Self.cacheKey(for: record.center)
            if let cached = try? await catalog.cachedGeocode(key: key), cached.didFail,
               Date().timeIntervalSince(cached.fetchedAt) < configuration.failureRetryWindow {
                // Tried recently and there was nothing there, or there was no network. Either way the answer
                // is known and repeating the question is how an offline machine burns a battery. Older than
                // the window, and it is a new question: Wi-Fi comes back.
                continue
            }
            if outcome.requests > 0 { try? await Task.sleep(for: configuration.throttle) }
            outcome.requests += 1
            do {
                let placemark = try await geocoder.placemark(for: record.center)
                try? await catalog.storeGeocode(key: key, placemark: placemark, didFail: false)
                try? await catalog.recordClusterGeocode(id: record.id, placemark: placemark,
                                                        level: Self.level(for: placemark), didFail: false)
                outcome.named += 1
            } catch GeocodeError.unavailable {
                try? await catalog.storeGeocode(key: key, placemark: nil, didFail: true)
                outcome.unavailable = true
                break
            } catch {
                try? await catalog.storeGeocode(key: key, placemark: nil, didFail: true)
                outcome.failed += 1
            }
        }
        if outcome.clusters > 0 {
            Log.indexing.info("places: \(outcome.clusters) clusters, \(outcome.named) named, \(outcome.reused) reused, \(outcome.cached) cached, \(outcome.requests) requests, \(outcome.failed) failed, offline \(outcome.unavailable)")
        }
        return outcome
    }

    /// One cell of about a kilometre, the same granularity `GPSPoint.coarseGridKey` documents: two clusters
    /// inside one cell are the same place and should cost one request.
    static func cacheKey(for gps: GPSPoint) -> String {
        let grid = gps.coarseGridKey
        return "\(grid.lat),\(grid.lon)"
    }

    static func level(for placemark: PlaceSummary) -> ClusterLevel {
        if placemark.name != nil { return .precise }
        if placemark.subLocality != nil { return .street }
        if placemark.locality != nil { return .city }
        if placemark.adminArea != nil || placemark.country != nil { return .country }
        return .grid
    }
}
