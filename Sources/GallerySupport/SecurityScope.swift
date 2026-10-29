import Foundation
import Synchronization

public enum SecurityScopeError: Error, Equatable, Sendable {
    case tokenUnavailable(path: String)
}

public enum SecurityScope {
    private struct Balance {
        var depth: Int = 0
        var startedURL: URL?
    }

    private static let balances = Mutex<[URL: Balance]>([:])

    /// The balance is keyed on `standardizedFileURL` so callers can pair a `begin` made from one URL
    /// spelling with an `end` made from another, and the depth count keeps nested sections on the same
    /// folder from stopping access while an outer section still runs.
    ///
    /// A `false` result is NOT an error: `startAccessingSecurityScopedResource` answers false for URLs
    /// no security scope can cover at all, and app-container or temp-dir paths without a bookmark must
    /// still let the caller proceed. Strict callers opt into throwing via `withStrictAccess`.
    @discardableResult
    public static func begin(_ url: URL) -> Bool {
        let key = url.standardizedFileURL
        return balances.withLock { table in
            var balance = table[key] ?? Balance()
            if balance.depth == 0 {
                balance.startedURL = url.startAccessingSecurityScopedResource() ? url : nil
            }
            balance.depth += 1
            table[key] = balance
            return balance.startedURL != nil
        }
    }

    public static func end(_ url: URL) {
        let key = url.standardizedFileURL
        let stopped: URL? = balances.withLock { table in
            guard var balance = table[key], balance.depth > 0 else { return nil }
            balance.depth -= 1
            if balance.depth == 0 {
                table.removeValue(forKey: key)
                return balance.startedURL
            }
            table[key] = balance
            return nil
        }
        stopped?.stopAccessingSecurityScopedResource()
    }

    /// begin/end pairing survives a throwing or cancelled `body` because `end` runs from a `defer`,
    /// and async unwinding only happens by popping scopes at suspension points — a throw or a
    /// cancellation cannot skip the defer the way a manually placed `end` after `try await` could.
    public static func withAccess<T: Sendable>(to url: URL, _ body: () async throws -> T) async throws -> T {
        begin(url)
        defer { end(url) }
        return try await body()
    }

    public static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        begin(url)
        defer { end(url) }
        return try body()
    }

    public static func withStrictAccess<T: Sendable>(to url: URL, _ body: () async throws -> T) async throws -> T {
        let hasToken = begin(url)
        defer { end(url) }
        guard hasToken else { throw SecurityScopeError.tokenUnavailable(path: url.path) }
        return try await body()
    }

    public static func withStrictAccess<T>(to url: URL, _ body: () throws -> T) throws -> T {
        let hasToken = begin(url)
        defer { end(url) }
        guard hasToken else { throw SecurityScopeError.tokenUnavailable(path: url.path) }
        return try body()
    }

    static func depth(for url: URL) -> Int {
        balances.withLock { $0[url.standardizedFileURL]?.depth ?? 0 }
    }
}
