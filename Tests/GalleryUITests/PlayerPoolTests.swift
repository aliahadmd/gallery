import AVFoundation
import Foundation
import Testing
@testable import GalleryUI
import GalleryDomain
import GalleryIndexing
import GallerySupport

/// A resolver that hands every id a path in a temp directory. The files are never opened: the pool's job is
/// bookkeeping — which players exist, and which of them have been stopped — not decoding.
private struct TempResolver: MediaResolving {
    let root: URL

    func targets(for ids: [MediaID]) async -> [MediaID: MediaTarget] {
        ids.reduce(into: [MediaID: MediaTarget]()) { result, id in
            result[id] = MediaTarget(url: root.appendingPathComponent("\(id.rawValue).mov"))
        }
    }
}

private struct NowhereResolver: MediaResolving {
    func targets(for ids: [MediaID]) async -> [MediaID: MediaTarget] { [:] }
}

/// Gives each player an item so "stopped" is observable as `currentItem == nil` — the teardown the pool
/// promises on dismiss, and the one that is otherwise invisible until audio is still playing over a photo.
@MainActor
private final class PlayerFactory {
    private(set) var made: [AVPlayer] = []

    func make(_ url: URL) -> AVPlayer {
        let player = AVPlayer()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        made.append(player)
        return player
    }
}

private func clip(_ id: Int64) -> MediaItem {
    MediaItem(
        id: MediaID(rawValue: id),
        identity: FileIdentity(volumeID: "vol-1", documentID: nil, resourceID: nil,
                               statHash: UInt64(id)),
        sourceID: SourceID(rawValue: 1),
        relativePath: "clip_\(id).mov",
        parentDirectory: "",
        name: "clip_\(id).mov",
        fileExtension: "mov",
        kind: .video,
        uniformTypeIdentifier: "public.mpeg-4",
        byteSize: 1024,
        modificationDate: nil
    )
}

@MainActor
@Suite("Player pool")
struct PlayerPoolTests {
    private struct Harness {
        let pool: PlayerPool
        let factory: PlayerFactory
        let root: URL
    }

    private func makePool(capacity: Int = 2) throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallery-pool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = PlayerFactory()
        return Harness(pool: PlayerPool(resolver: TempResolver(root: root), capacity: capacity,
                                        makePlayer: factory.make),
                       factory: factory, root: root)
    }

    @Test("Asking twice is the same player, not a second decode")
    func reusesAPlayer() async throws {
        let harness = try makePool()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let first = try #require(await harness.pool.player(for: clip(1)))
        let again = try #require(await harness.pool.player(for: clip(1)))

        #expect(first.player === again.player)
        #expect(harness.factory.made.count == 1)
        #expect(harness.pool.openCount == 1)
    }

    @Test("The clip past capacity evicts the oldest, and eviction stops it")
    func capacityEvictsOldest() async throws {
        let harness = try makePool(capacity: 2)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let oldest = try #require(await harness.pool.player(for: clip(1)))
        let middle = try #require(await harness.pool.player(for: clip(2)))
        let newest = try #require(await harness.pool.player(for: clip(3)))

        #expect(harness.pool.openCount == 2, "two decoders, not one per arrow key")
        #expect(oldest.player.currentItem == nil, "the clip that left the window is torn down, not just dropped")
        #expect(middle.player.currentItem != nil)
        #expect(newest.player.currentItem != nil)
    }

    @Test("Stepping away stops every clip but the one on screen")
    func evictExceptKeepsOne() async throws {
        let harness = try makePool()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let leaving = try #require(await harness.pool.player(for: clip(1)))
        let staying = try #require(await harness.pool.player(for: clip(2)))

        harness.pool.evict(except: MediaID(rawValue: 2))

        #expect(harness.pool.openCount == 1)
        #expect(leaving.player.currentItem == nil, "a photo after a clip is a photo in silence")
        #expect(staying.player.currentItem != nil)
    }

    @Test("Closing the viewer tears every clip down")
    func stopAllTearsDown() async throws {
        let harness = try makePool()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let first = try #require(await harness.pool.player(for: clip(1)))
        let second = try #require(await harness.pool.player(for: clip(2)))

        harness.pool.stopAll()

        #expect(harness.pool.openCount == 0)
        #expect(first.player.currentItem == nil)
        #expect(second.player.currentItem == nil)
    }

    @Test("A file the catalog cannot place has no player")
    func unresolvedFileHasNoPlayer() async throws {
        let pool = PlayerPool(resolver: NowhereResolver())
        #expect(await pool.player(for: clip(1)) == nil)
        #expect(pool.openCount == 0)
    }
}
