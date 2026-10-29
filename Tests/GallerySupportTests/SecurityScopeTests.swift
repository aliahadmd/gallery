import Foundation
import Testing
@testable import GallerySupport

@Suite struct SecurityScopeTests {
    private func uniqueTempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("scope-\(UUID().uuidString)")
    }

    // Swift Testing runs tests concurrently and SecurityScope keeps one process-wide balance table,
    // so each test touching `depth` must use a URL no other test shares.
    private func uniqueRemoteURL() -> URL {
        URL(string: "https://example.com/photo-\(UUID().uuidString).jpg")!
    }

    @Test func syncWithAccessReturnsValueAndBalances() throws {
        let url = uniqueTempURL()
        let value = try SecurityScope.withAccess(to: url) { 42 }
        #expect(value == 42)
        #expect(SecurityScope.depth(for: url) == 0)
    }

    @Test func throwingBodyStillEndsAccess() {
        struct Boom: Error {}
        let url = uniqueTempURL()
        #expect(throws: Boom.self) {
            try SecurityScope.withAccess(to: url) { throw Boom() }
        }
        #expect(SecurityScope.depth(for: url) == 0)
    }

    @Test func asyncBodyStillEndsAccess() async throws {
        let url = uniqueTempURL()
        let value = try await SecurityScope.withAccess(to: url) { "ok" }
        #expect(value == "ok")
        #expect(SecurityScope.depth(for: url) == 0)
    }

    /// `begin` answers false for a URL the process cannot even read (non-file schemes qualify in an
    /// unsandboxed test run) — and a non-strict section must still run; the balance, not the token,
    /// is what the pairing guarantees.
    @Test func nestedSectionsKeepTheBalanceUntilTheOutermostEnds() throws {
        let url = uniqueTempURL()
        _ = SecurityScope.begin(url)
        #expect(SecurityScope.depth(for: url) == 1)

        let innerResult = SecurityScope.withAccess(to: url) { SecurityScope.depth(for: url) }
        #expect(innerResult == 2)
        #expect(SecurityScope.depth(for: url) == 1, "the inner end must not stop the outer section")

        SecurityScope.end(url)
        #expect(SecurityScope.depth(for: url) == 0)

        // An unbalanced extra end is a no-op, not a crash or a negative depth.
        SecurityScope.end(url)
        #expect(SecurityScope.depth(for: url) == 0)
    }

    @Test func nonFileURLStillRunsNonStrictSectionsButFailsStrictOnes() throws {
        let remote = uniqueRemoteURL()
        let tokenEstablished = SecurityScope.begin(remote)
        #expect(tokenEstablished == false, "no security scope for a non-file URL")
        SecurityScope.end(remote)
        #expect(SecurityScope.depth(for: remote) == 0)

        // Without a token the body must still proceed (the path is public over HTTP anyway).
        let value = try SecurityScope.withAccess(to: remote) { 7 }
        #expect(value == 7)
    }

    @Test func differentlySpelledURLsShareOneBalance() {
        let url = uniqueTempURL()
        let spelledDifferently = url
            .deletingLastPathComponent()
            .appendingPathComponent(".")
            .appendingPathComponent(url.lastPathComponent)
        _ = SecurityScope.begin(url)
        #expect(SecurityScope.depth(for: spelledDifferently) == 1)
        SecurityScope.end(spelledDifferently)
        #expect(SecurityScope.depth(for: url) == 0)
    }

    @Test func cancelledAsyncBodyStillEndsAccess() async throws {
        let url = uniqueTempURL()
        let task = Task {
            try await SecurityScope.withAccess(to: url) {
                try await Task.sleep(for: .seconds(30))
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected the sleeping body to throw on cancellation")
        } catch {
            // expected CancellationError
        }
        #expect(SecurityScope.depth(for: url) == 0)
    }

    @Test func strictAccessRefusesURLsWithoutAProvenToken() async {
        // A non-file URL cannot yield a security scope token in an unsandboxed test process.
        let url = uniqueRemoteURL()
        await #expect(throws: SecurityScopeError.self) {
            try await SecurityScope.withStrictAccess(to: url) { 1 }
        }
        #expect(SecurityScope.depth(for: url) == 0)

        #expect(throws: SecurityScopeError.self) {
            try SecurityScope.withStrictAccess(to: url) { 1 }
        }
        #expect(SecurityScope.depth(for: url) == 0)
    }

    @Test func concurrentSectionsOnDifferentURLsBalanceIndependently() async throws {
        let urls = (0..<8).map { _ in uniqueTempURL() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                for url in urls {
                    group.addTask {
                        try await SecurityScope.withAccess(to: url) {
                            try await Task.sleep(for: .microseconds(50))
                        }
                    }
                }
            }
        }
        for url in urls {
            #expect(SecurityScope.depth(for: url) == 0)
        }
    }
}
