import Foundation

/// Where a capture date came from. Persisted, because "which date did we trust" is the first question
/// to ask when a day album looks wrong, and because it decides whether a re-bucket is safe.
public enum CaptureSource: Int16, Sendable, Hashable, Codable, CaseIterable {
    case exifOffsetTimeOriginal = 0
    case exifDateTimeOriginal = 1
    case exifDateTimeDigitized = 2
    case assetCreationDate = 3
    case fileSystem = 4
    case unknown = 5

    /// Only an `OffsetTimeOriginal` reading actually knows its time zone; everything below it is a guess
    /// that a travel photo can get wrong by a day.
    public var isZoneAware: Bool { self == .exifOffsetTimeOriginal }
    public var isAuthoritative: Bool { rawValue <= CaptureSource.exifDateTimeDigitized.rawValue }
}

public struct CaptureMoment: Sendable, Hashable, Codable {
    public var instant: Date
    public var wallClock: Date
    public var timeZone: TimeZone?
    public var source: CaptureSource

    public init(instant: Date, wallClock: Date, timeZone: TimeZone?, source: CaptureSource) {
        self.instant = instant
        self.wallClock = wallClock
        self.timeZone = timeZone
        self.source = source
    }

    /// `yyyymmdd` in the capture time zone. Precomputed and indexed because grouping a 100k library by
    /// day would otherwise run calendar arithmetic per row, per query.
    public var dayBucket: Int32 { CaptureMoment.dayBucket(of: instant, timeZone: effectiveZone) }
    public var monthBucket: Int32 { CaptureMoment.monthBucket(of: instant, timeZone: effectiveZone) }

    public var effectiveZone: TimeZone { timeZone ?? .current }

    public func isSameDay(as other: CaptureMoment) -> Bool { dayBucket == other.dayBucket }

    /// Whole calendar days between two captures, counted in this moment's own zone — a photo taken at
    /// 23:00 JST and one at 01:00 JST eight hours later are the same day even though UTC says otherwise.
    public func daysSince(_ other: CaptureMoment) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = effectiveZone
        let start = calendar.startOfDay(for: other.instant)
        let end = calendar.startOfDay(for: instant)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    public static let utc = TimeZone(secondsFromGMT: 0) ?? .gmt

    public static func dayBucket(of date: Date, timeZone: TimeZone) -> Int32 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = max(0, parts.year ?? 1970)
        return Int32(year * 10_000 + (parts.month ?? 1) * 100 + (parts.day ?? 1))
    }

    public static func monthBucket(of date: Date, timeZone: TimeZone) -> Int32 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month], from: date)
        return Int32(max(0, parts.year ?? 1970) * 100 + (parts.month ?? 1))
    }

    public static func date(forDayBucket bucket: Int32, timeZone: TimeZone = CaptureMoment.utc) -> Date? {
        let year = Int(bucket) / 10_000
        let month = (Int(bucket) / 100) % 100
        let day = Int(bucket) % 100
        guard year > 0, (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    /// A wall-clock EXIF reading with no zone information is turned into an absolute date by assuming it
    /// was taken in `assumedZone`; the assumption is recorded so it can be undone later.
    ///
    /// `wallClock` is always the naive reading — the digits off the film, parsed as if they were UTC — and
    /// `instant` is that reading shifted back by whatever zone we settled on. Getting the direction of that
    /// shift wrong is the travel-photo bug: a 20:00 JST frame bucketed as if it were 20:00 UTC lands in
    /// tomorrow's album in every machine's local time.
    public static func resolving(
        wallClock: Date,
        offsetSeconds: Int?,
        assumedZone: TimeZone = .current,
        source: CaptureSource
    ) -> CaptureMoment {
        // A source that is supposed to know its zone and arrived without one is read as UTC rather than as
        // the viewer's local time, so the day bucket at least stays the same on two machines.
        let zone: TimeZone
        if let offsetSeconds {
            zone = TimeZone(secondsFromGMT: offsetSeconds) ?? Self.utc
        } else {
            zone = source.isZoneAware ? Self.utc : assumedZone
        }
        let offset = zone.secondsFromGMT(for: wallClock)
        return CaptureMoment(
            instant: wallClock.addingTimeInterval(-Double(offset)),
            wallClock: wallClock,
            timeZone: zone,
            source: source
        )
    }
}

public struct GPSPoint: Sendable, Hashable, Codable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var accuracyMeters: Double?
    public var speedMetersPerSecond: Double?
    public var direction: Double?
    public var timestamp: Date?

    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        accuracyMeters: Double? = nil,
        speedMetersPerSecond: Double? = nil,
        direction: Double? = nil,
        timestamp: Date? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.accuracyMeters = accuracyMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.direction = direction
        self.timestamp = timestamp
    }

    public var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && !(latitude == 0 && longitude == 0)
    }

    /// ~1.1 km cells, which is the grid the clusterer seeds from and the offline naming fallback.
    public var coarseGridKey: (lat: Int32, lon: Int32) {
        (Int32((latitude * 100).rounded()), Int32((longitude * 100).rounded()))
    }

    public var offlinePlaceLabel: String {
        String(format: "Near %.1f°%@, %.1f°%@", abs(latitude), latitude >= 0 ? "N" : "S",
               abs(longitude), longitude >= 0 ? "E" : "W")
    }
}

/// Great-circle distance. Kept in the domain so both the location clusterer and the event heuristic
/// measure the same way.
public func haversineKilometers(_ a: GPSPoint, _ b: GPSPoint) -> Double {
    let earthRadiusKM = 6371.0088
    let lat1 = a.latitude * .pi / 180
    let lat2 = b.latitude * .pi / 180
    let dLat = lat2 - lat1
    let dLon = (b.longitude - a.longitude) * .pi / 180
    let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * earthRadiusKM * asin(min(1, sqrt(h)))
}
