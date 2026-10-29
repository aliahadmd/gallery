import Foundation

public enum BookmarkResolution: Sendable, Equatable {
    case valid(URL)
    case stale(URL)
    case missing
    case failed(String)
}

// UserDefaults is documented thread-safe but ships un-annotated, so the compiler cannot check the
// conformance for us.
public struct BookmarkStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String
    private static let scopeFlagSuffix = ".security-scoped"

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "gallery.source.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func save(_ url: URL, forKey key: String) throws {
        let (data, securityScoped) = try Self.bookmark(for: url)
        // UserDefaults only — a bookmark written into the picked folder would be visible to (and
        // deletable by) the user's own file operations.
        defaults.set(data, forKey: storageKey(key))
        defaults.set(securityScoped, forKey: storageKey(key) + Self.scopeFlagSuffix)
    }

    public func resolve(_ key: String) -> BookmarkResolution {
        guard let data = defaults.data(forKey: storageKey(key)) else { return .missing }
        var options: URL.BookmarkResolutionOptions = [.withoutMounting, .withoutUI]
        if storesSecurityScope(forKey: key) { options.insert(.withSecurityScope) }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            return .failed(error.localizedDescription)
        }
        // The stale flag only fires for scope-tracked moves; a path that no longer resolves to a
        // reachable item is equally unconfirmed and must go back to the user.
        let reachable = (try? url.checkResourceIsReachable()) ?? false
        return stale || !reachable ? .stale(url) : .valid(url)
    }

    public func remove(_ key: String) {
        defaults.removeObject(forKey: storageKey(key))
        defaults.removeObject(forKey: storageKey(key) + Self.scopeFlagSuffix)
    }

    public var storedKeys: [String] {
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(keyPrefix) && !$0.hasSuffix(Self.scopeFlagSuffix) }
            .map { String($0.dropFirst(keyPrefix.count)) }
            .sorted()
    }

    /// `.withSecurityScope` only succeeds inside a sandbox; in an unsandboxed process (every unit
    /// test) it throws, so fall back to a persistence-only bookmark and record which kind was stored —
    /// `resolve` must never ask for a scope that was never saved.
    static func bookmark(for url: URL, securityScope: Bool = true) throws -> (data: Data, securityScoped: Bool) {
        if securityScope, let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            return (data, true)
        }
        return (try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), false)
    }

    func storesSecurityScope(forKey key: String) -> Bool {
        defaults.bool(forKey: storageKey(key) + Self.scopeFlagSuffix)
    }

    func storageKey(_ key: String) -> String { keyPrefix + key }
}
