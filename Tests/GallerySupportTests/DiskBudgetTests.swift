import Foundation
import Testing
@testable import GallerySupport

@Suite struct DiskBudgetTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    private func writeFile(in directory: URL, named name: String, size: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(count: size).write(to: url)
        return url
    }

    @Test func usedBytesCoversTheWholeTree() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeFile(in: dir, named: "a.bin", size: 100)
        _ = try writeFile(in: dir, named: "b.bin", size: 200)
        let sub = dir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try writeFile(in: sub, named: "c.bin", size: 300)

        let budget = DiskBudget(directory: dir, byteLimit: 10_000)
        #expect(budget.usedBytes() == 600)
    }

    @Test func evictsLeastRecentlyUsedFirstAndStopsUnderBudget() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldest = try writeFile(in: dir, named: "oldest.bin", size: 100)
        let middle = try writeFile(in: dir, named: "middle.bin", size: 200)
        let newest = try writeFile(in: dir, named: "newest.bin", size: 300)
        let dates: [String: Date] = [
            "oldest.bin": .init(timeIntervalSince1970: 1),
            "middle.bin": .init(timeIntervalSince1970: 2),
            "newest.bin": .init(timeIntervalSince1970: 3),
        ]

        // 600 used, limit 300: drop oldest (100) → 500, middle (200) → 300 ≤ 300, stop before newest.
        let budget = DiskBudget(directory: dir, byteLimit: 300)
        let report = budget.evict(untilUnderBudget: true) { url in dates[url.lastPathComponent] }
        #expect(report == DiskBudget.EvictionReport(removed: 2, freedBytes: 300))
        #expect(budget.usedBytes() == 300)
        #expect(!FileManager.default.fileExists(atPath: oldest.path))
        #expect(!FileManager.default.fileExists(atPath: middle.path))
        #expect(FileManager.default.fileExists(atPath: newest.path))
    }

    /// A file the catalog never dated cannot be *proven* cold, so every dated file is evicted before
    /// it — even if it sits under the budget line.
    @Test func undatedFilesAreEvictedLast() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dated1 = try writeFile(in: dir, named: "dated1.bin", size: 100)
        let dated2 = try writeFile(in: dir, named: "dated2.bin", size: 200)
        let dated3 = try writeFile(in: dir, named: "dated3.bin", size: 300)
        let orphan = try writeFile(in: dir, named: "orphan.bin", size: 50)
        let dates: [String: Date] = [
            "dated1.bin": .init(timeIntervalSince1970: 1),
            "dated2.bin": .init(timeIntervalSince1970: 2),
            "dated3.bin": .init(timeIntervalSince1970: 3),
        ]

        let budget = DiskBudget(directory: dir, byteLimit: 60)
        let report = budget.evict(untilUnderBudget: true) { url in dates[url.lastPathComponent] }
        // All three dated files must go before the unproven orphan: 650 → 550 → 350 → 50 ≤ 60.
        #expect(report == DiskBudget.EvictionReport(removed: 3, freedBytes: 600))
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        for gone in [dated1, dated2, dated3] {
            #expect(!FileManager.default.fileExists(atPath: gone.path))
        }
    }

    @Test func untilUnderBudgetFalseEmptiesTheTreeWithoutDeletingNeighbours() throws {
        let dir = try makeTempDirectory()
        let outside = try writeFile(in: FileManager.default.temporaryDirectory, named: "outside-\(UUID().uuidString).bin", size: 10)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outside)
        }
        _ = try writeFile(in: dir, named: "one.bin", size: 100)
        let sub = dir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try writeFile(in: sub, named: "two.bin", size: 100)

        let budget = DiskBudget(directory: dir, byteLimit: 10_000)
        let report = budget.evict(untilUnderBudget: false) { _ in nil }
        #expect(report == DiskBudget.EvictionReport(removed: 2, freedBytes: 200))
        #expect(budget.usedBytes() == 0)
        #expect(FileManager.default.fileExists(atPath: outside.path), "must never delete outside its directory")
        #expect(FileManager.default.fileExists(atPath: dir.path), "and never the directory root itself")
    }

    @Test func missingDirectoryIsHarmless() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("budget-\(UUID().uuidString)")
        let budget = DiskBudget(directory: dir, byteLimit: 100)
        #expect(budget.usedBytes() == 0)
        let report = budget.evict(untilUnderBudget: true) { _ in nil }
        #expect(report == DiskBudget.EvictionReport(removed: 0, freedBytes: 0))
    }

    @Test func alreadyUnderBudgetEvictsNothing() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeFile(in: dir, named: "small.bin", size: 10)

        let budget = DiskBudget(directory: dir, byteLimit: 100)
        let report = budget.evict(untilUnderBudget: true) { _ in nil }
        #expect(report == DiskBudget.EvictionReport(removed: 0, freedBytes: 0))
        #expect(budget.usedBytes() == 10)
    }
}
