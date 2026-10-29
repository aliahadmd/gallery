import Foundation

public enum VolumeResolution: Sendable, Equatable {
    case mounted(URL)
    case notMounted
    case inaccessible(URL)
}

public enum VolumeIdentity {
    private static let volumeKeys: Set<URLResourceKey> = [
        .volumeUUIDStringKey, .volumeIdentifierKey, .volumeNameKey, .volumeIsRemovableKey,
        .volumeIsReadOnlyKey, .volumeIsBrowsableKey, .volumeIsLocalKey,
    ]

    private static func values(for url: URL) -> URLResourceValues? {
        try? url.resourceValues(forKeys: volumeKeys)
    }

    public static func identifier(for url: URL) -> String? {
        guard let values = values(for: url) else { return nil }
        if let uuid = values.volumeUUIDString, !uuid.isEmpty { return "uuid:\(uuid)" }
        if let id = values.volumeIdentifier as? Data, !id.isEmpty {
            return "vol:" + id.map { String(format: "%02x", $0) }.joined()
        }
        // Filesystems exposing neither form: the volume name is the last stable handle — it survives
        // a remount at a different `/Volumes/...` path, which is what `resolve` needs.
        guard let name = values.volumeName, !name.isEmpty else { return nil }
        return "name:\(name)"
    }

    /// Matching is by volume identifier, never by stored path: a card that comes back as
    /// `/Volumes/SD 1` rebinds because it carries the same volume ID.
    public static func resolve(volumeID: String, relativePath: String) -> VolumeResolution {
        var path = Substring(relativePath)
        while path.hasPrefix("/") { path = path.dropFirst() }
        let mounts = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(volumeKeys),
            options: .skipHiddenVolumes
        ) ?? []
        for mount in mounts where identifier(for: mount) == volumeID {
            let candidate = mount.appendingPathComponent(String(path)).standardizedFileURL
            if (try? candidate.checkResourceIsReachable()) == true { return .mounted(candidate) }
            return .inaccessible(candidate)
        }
        return .notMounted
    }

    public static func isRemovable(_ url: URL) -> Bool {
        values(for: url)?.volumeIsRemovable ?? false
    }

    public static func isReadOnly(_ url: URL) -> Bool {
        values(for: url)?.volumeIsReadOnly ?? false
    }

    /// SMB/AFP mounts are not covered by FSEvents, so callers fall back to timed rescans.
    public static func isNetworkMounted(_ url: URL) -> Bool {
        guard let local = values(for: url)?.volumeIsLocal else { return false }
        return !local
    }
}
