import Foundation

/// The numbers the user can run into, in one place.
///
/// A limit a person can hit — "the first 500 matches", "at most 12 photos", "kept for 30 days" — should be
/// named once so the UI, the executor and the release notes cannot drift apart. Internal tuning constants
/// (batch sizes, thumbnail budgets) stay next to the code they tune; these are the promises.
public enum Limits {
    /// Search stops here. The UI says "first N matches" instead of pretending the result is complete.
    public static let searchHits = 500
    /// The most rows one confirmed batch action loads and processes. Larger selections are reported as
    /// truncated rather than silently half-done.
    public static let batchRows = 20_000
    /// A collage beyond this many slots stops being a collage and becomes a contact sheet.
    public static let collageMembers = 12
    public static let trashRetentionDays = 30
    public static let trashRetention: TimeInterval = TimeInterval(trashRetentionDays) * 24 * 60 * 60
    /// Watcher suppression after the app writes a file itself.
    public static let selfWriteWindow: TimeInterval = 5
    /// HFS+/APFS filename limit with room for the extension.
    public static let filenameBytes = 250
    public static let pageRows = 200
    public static let categorySampleSide: Int32 = 96
    public static let categorySamplesPerHop = 32
}
