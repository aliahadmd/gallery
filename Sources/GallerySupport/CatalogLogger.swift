import Foundation
import os

public enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "app.gallery"

    public static let indexing = Logger(subsystem: subsystem, category: "indexing")
    public static let catalog = Logger(subsystem: subsystem, category: "catalog")
    public static let imaging = Logger(subsystem: subsystem, category: "imaging")
    public static let geo = Logger(subsystem: subsystem, category: "geo")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    /// The third pass: what Vision found, what it cost, and what it skipped.
    public static let analysis = Logger(subsystem: subsystem, category: "analysis")
}
