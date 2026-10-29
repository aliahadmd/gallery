import Foundation
import Testing
@testable import GallerySupport

@Suite struct BookmarkStoreTests {
    /// A fresh suite per test: suites land in the caller's defaults domain and must not leak
    /// across tests running in parallel.
    private func makeStore() throws -> (store: BookmarkStore, defaults: UserDefaults, suite: String) {
        let suite = "GallerySupportTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (BookmarkStore(defaults: defaults), defaults, suite)
    }

    private func makeTempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        return url
    }

    @Test func resolveWithoutStoredDataIsMissing() throws {
        let (store, _, suite) = try makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(store.resolve("absent") == .missing)
    }

    @Test func saveThenResolveRoundTripsToTheSameFile() throws {
        let (store, _, suite) = try makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        try store.save(file, forKey: "source")
        let resolution = store.resolve("source")
        guard case .valid(let resolved) = resolution else {
            Issue.record("expected .valid, got \(resolution)")
            return
        }
        #expect(resolved.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
    }

    /// Whether `.withSecurityScope` succeeds depends on the enclosing process, so the fallback branch
    /// is exercised directly here: a persistence-only bookmark must store, resolve, and match.
    @Test func fallbackBookmarkKindStoresAndResolvesDeterministically() throws {
        let (store, _, suite) = try makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        try store.save(file, forKey: "source")
        // Whatever kind `save` recorded, resolving must come back with the same location.
        let resolution = store.resolve("source")
        guard case .valid(let roundTripped) = resolution else {
            Issue.record("expected .valid, got \(resolution)")
            return
        }
        #expect(roundTripped.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())

        let (data, securityScoped) = try BookmarkStore.bookmark(for: file, securityScope: false)
        #expect(!securityScoped)
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: data,
            options: [.withoutMounting, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        #expect(!stale)
        #expect(resolved.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
    }

    @Test func deletedLocationResolvesAsStaleOrFailedButNeverValid() throws {
        let (store, _, suite) = try makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let file = try makeTempFile()

        try store.save(file, forKey: "source")
        try FileManager.default.removeItem(at: file)

        switch store.resolve("source") {
        case .valid: Issue.record("a deleted bookmark must not report .valid")
        case .stale, .failed, .missing: break
        }
    }

    @Test func corruptedDataFailsWithAReason() throws {
        let (store, defaults, suite) = try makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(Data([0xDE, 0xAD, 0xBE, 0xEF]), forKey: store.storageKey("source"))

        switch store.resolve("source") {
        case .failed(let reason): #expect(!reason.isEmpty)
        default: Issue.record("expected .failed for corrupt bookmark data")
        }
    }

    @Test func removeClearsDataAndFlagAndStoredKeys() throws {
        let (store, _, suite) = try makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        try store.save(file, forKey: "camera")
        try store.save(file, forKey: "downloads")
        #expect(store.storedKeys == ["camera", "downloads"])

        store.remove("camera")
        #expect(store.resolve("camera") == .missing)
        #expect(store.storedKeys == ["downloads"])
    }
}
