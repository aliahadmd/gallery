import Foundation

extension Date {
    /// Whole nanoseconds since the epoch. Stored as INTEGER because a millisecond truncation makes two
    /// files written seconds apart look identical to the change detector.
    ///
    /// Clamped rather than converted: a camera that stamps `0000-01-01` and a caller's `Date.distantPast`
    /// sentinel are both outside `Int64` nanoseconds, and the conversion traps. A stamp column is a poor
    /// reason to crash over a date that was never real — the row still sorts cold, which is what the
    /// caller with a sentinel wanted, and an impossible file date still gets a stable thumbnail name.
    public var nanoseconds: Int64 {
        let scaled = (timeIntervalSince1970 * 1_000_000_000).rounded()
        if scaled.isNaN { return 0 }
        if scaled >= Double(Int64.max) { return .max }
        if scaled <= Double(Int64.min) { return .min }
        return Int64(scaled)
    }

    public init(nanoseconds: Int64) {
        self.init(timeIntervalSince1970: Double(nanoseconds) / 1_000_000_000)
    }
}
