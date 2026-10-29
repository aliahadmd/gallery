import Foundation
import Testing
@testable import GallerySupport

@Suite struct VolumeIdentityTests {
    private var tempDirectory: URL { FileManager.default.temporaryDirectory.standardizedFileURL }

    @Test func identifierIsStableAcrossPathsOnOneVolume() throws {
        let parent = tempDirectory
        let child = parent.appendingPathComponent("volume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: child) }

        let parentID = try #require(VolumeIdentity.identifier(for: parent))
        let childID = try #require(VolumeIdentity.identifier(for: child))
        #expect(parentID == childID)
    }

    @Test func identifierIsNilForPathsThatDoNotExist() {
        let ghost = tempDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        #expect(VolumeIdentity.identifier(for: ghost) == nil)
    }

    @Test func storedRootRelativePathRebindsToTheCurrentMount() throws {
        let root = URL(fileURLWithPath: "/")
        let volumeID = try #require(VolumeIdentity.identifier(for: root))
        let resolution = VolumeIdentity.resolve(volumeID: volumeID, relativePath: "System")
        #expect(resolution == .mounted(URL(fileURLWithPath: "/System")))
    }

    @Test func relativePathIsStrippedOfLeadingSlashesAndStillResolves() throws {
        let root = URL(fileURLWithPath: "/")
        let volumeID = try #require(VolumeIdentity.identifier(for: root))
        let resolution = VolumeIdentity.resolve(volumeID: volumeID, relativePath: "/System")
        guard case .mounted(let url) = resolution else {
            Issue.record("expected .mounted, got \(resolution)")
            return
        }
        #expect(url.path == "/System")
    }

    @Test func unknownVolumeIsNotMounted() {
        let resolution = VolumeIdentity.resolve(
            volumeID: "uuid:00000000-1111-2222-3333-444444444444",
            relativePath: "photos"
        )
        #expect(resolution == .notMounted)
    }

    @Test func missingPathOnAMountedVolumeIsInaccessible() throws {
        let volumeID = try #require(VolumeIdentity.identifier(for: tempDirectory))
        let resolution = VolumeIdentity.resolve(
            volumeID: volumeID,
            relativePath: "no-such-gallery-path-\(UUID().uuidString)"
        )
        guard case .inaccessible = resolution else {
            Issue.record("expected .inaccessible, got \(resolution)")
            return
        }
    }

    @Test func temporaryDirectoryLooksLikeAnOrdinaryLocalVolume() throws {
        // The identity helpers must answer for plain local storage before any exotic mount is asked
        // of them; a wrong flag here would silently disable FSEvents or allow eviction on read-only
        // media.
        let url = tempDirectory
        #expect(VolumeIdentity.isRemovable(url) == false)
        #expect(VolumeIdentity.isReadOnly(url) == false)
        #expect(VolumeIdentity.isNetworkMounted(url) == false)
    }
}
