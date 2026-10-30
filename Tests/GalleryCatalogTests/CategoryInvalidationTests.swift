import Foundation
import Testing
@testable import GalleryCatalog
import GalleryDomain

/// A category is a verdict about bytes. Everything that changes those bytes — a rescan, a re-analysis,
/// an edit, a rename — must send the row back through the classifier instead of leaving the shelf showing
/// evidence that no longer applies.
@Suite("Category invalidation")
struct CategoryInvalidationTests {
    private func evidence(_ category: MediaCategory = .screenshot) -> CategoryEvidence {
        CategoryEvidence(
            category: category, confidence: 0.9, score: 100,
            reasons: [CategoryReason(code: .deviceDimensions, weight: 40, detail: "1170 × 2532")],
            version: 1, revision: "test"
        )
    }

    private func classify(_ fixture: CatalogFixture, _ id: MediaID, statHash: UInt64 = 1) async throws {
        try await fixture.catalog.recordCategories([
            CategoryResult(mediaID: id, statHash: statHash, evidence: evidence(), sampled: nil)
        ])
    }

    @Test("A rescan that sees new bytes loses the category and puts the row back in the queue")
    func aChangedFileLosesItsCategory() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let item = makeItem("Screenshot 2026-10-29.png", documentID: 1, sourceID: source.id,
                            stage: .thumbnailed, size: 1024)
        let id = try await fixture.record([item]).first!

        try await fixture.catalog.recordAnalysis([
            MediaAnalysisResult(mediaID: id, statHash: item.identity.statHash, version: 1,
                                revision: "test", labels: [SceneLabel(identifier: "user interface",
                                                                     confidence: 0.9)])
        ])
        try await classify(fixture, id, statHash: item.identity.statHash)
        #expect(try await fixture.reader.item(id: id)?.category == .screenshot)
        #expect(try await fixture.catalog.claimCategories(limit: 10).isEmpty)

        var changed = item
        changed.byteSize = 2048
        changed.identity.statHash = statHash(size: 2048, modificationDate: nil, creationDate: nil)
        try await fixture.record([changed])

        let after = try #require(try await fixture.reader.item(id: id))
        #expect(after.category == MediaCategory.none, "a verdict about the old bytes is gone")
        #expect(after.identity.statHash == changed.identity.statHash)

        // The analysis has to run again first; once it has, the category pass sees the row again.
        try await fixture.catalog.recordAnalysis([
            MediaAnalysisResult(mediaID: id, statHash: changed.identity.statHash, version: 1,
                                revision: "test")
        ])
        let claimed = try await fixture.catalog.claimCategories(limit: 10)
        #expect(claimed.map(\.mediaID) == [id], "a re-walked file is classified again")
    }

    @Test("New analysis results invalidate the category built on the old ones")
    func finishingAnalysisInvalidatesTheVerdict() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let item = makeItem("Screenshot 2026-10-29.png", documentID: 1, sourceID: source.id,
                            stage: .thumbnailed)
        let id = try await fixture.record([item]).first!

        try await fixture.catalog.recordAnalysis([
            MediaAnalysisResult(mediaID: id, statHash: item.identity.statHash, version: 1, revision: "test")
        ])
        try await classify(fixture, id, statHash: item.identity.statHash)
        #expect(try await fixture.reader.item(id: id)?.category == .screenshot)

        // A revision bump re-analysis writes a new verdict-less row; the old category may not survive it.
        try await fixture.catalog.recordAnalysis([
            MediaAnalysisResult(mediaID: id, statHash: item.identity.statHash, version: 2, revision: "v2")
        ])
        let after = try #require(try await fixture.reader.item(id: id))
        #expect(after.category == MediaCategory.none)
        #expect(try await fixture.catalog.claimCategories(limit: 10).map(\.mediaID) == [id])
    }

    @Test("Writing metadata into a file invalidates its category")
    func aMetadataEditInvalidatesTheVerdict() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let item = makeItem("IMG_0001.JPG", documentID: 1, sourceID: source.id, stage: .thumbnailed)
        let id = try await fixture.record([item]).first!

        try await fixture.catalog.recordAnalysis([
            MediaAnalysisResult(mediaID: id, statHash: item.identity.statHash, version: 1, revision: "test")
        ])
        try await classify(fixture, id, statHash: item.identity.statHash)

        let newStat = FileStat(
            size: item.byteSize,
            modificationDate: Date(),
            creationDate: nil,
            inode: 1,
            statHash: statHash(size: item.byteSize, modificationDate: nil, creationDate: nil)
        )
        let committed = try await fixture.catalog.commitEdit(MediaEditCommit(
            mediaID: id, expectedStatHash: item.identity.statHash, stat: newStat,
            pixelsChanged: false,
            projection: EditProjection(title: "Holiday", capture: nil, gps: nil)
        ))
        try #require(committed)
        let after = try #require(try await fixture.reader.item(id: id))
        #expect(after.category == MediaCategory.none)
        #expect(try await fixture.catalog.claimCategories(limit: 10).map(\.mediaID) == [id])
    }

    @Test("Renaming a file invalidates its category")
    func aRenameInvalidatesTheVerdict() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let item = makeItem("IMG_0001.JPG", documentID: 1, sourceID: source.id, stage: .thumbnailed)
        let id = try await fixture.record([item]).first!

        try await fixture.catalog.recordAnalysis([
            MediaAnalysisResult(mediaID: id, statHash: item.identity.statHash, version: 1, revision: "test")
        ])
        try await classify(fixture, id, statHash: item.identity.statHash)

        let stat = FileStat(
            size: item.byteSize, modificationDate: Date(), creationDate: nil, inode: 1,
            statHash: item.identity.statHash
        )
        let outcome = try await fixture.catalog.applyRenames([MediaRename(
            mediaID: id, expectedStatHash: item.identity.statHash,
            fromRelativePath: item.relativePath, toRelativePath: "Screenshot 2026-10-29.JPG",
            parentRelativePath: "", name: "Screenshot 2026-10-29.JPG", fileExtension: "JPG",
            subtype: [], searchText: nil, stat: stat
        )])
        #expect(outcome.applied == [id])

        let after = try #require(try await fixture.reader.item(id: id))
        #expect(after.category == MediaCategory.none, "the new name is new evidence")
        #expect(try await fixture.catalog.claimCategories(limit: 10).map(\.mediaID) == [id])
    }

    @Test("The category claim counts its own attempts, not the analysis pass's")
    func categoryClaimsUseTheirOwnAttemptCounter() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let item = makeItem("IMG_0001.JPG", documentID: 1, sourceID: source.id, stage: .thumbnailed)
        let id = try await fixture.record([item]).first!
        try await fixture.catalog.recordAnalysis([
            MediaAnalysisResult(mediaID: id, statHash: item.identity.statHash, version: 1, revision: "test")
        ])

        // One allowed attempt, but the analysis row's own counter must not be consulted: the first claim
        // and the retry both succeed, and the third is refused.
        #expect(try await fixture.catalog.claimCategories(limit: 10, maximumAttempts: 1).count == 1)
        try await fixture.catalog.resetStaleCategoryClaims()
        #expect(try await fixture.catalog.claimCategories(limit: 10, maximumAttempts: 1).count == 1)
        try await fixture.catalog.resetStaleCategoryClaims()
        #expect(try await fixture.catalog.claimCategories(limit: 10, maximumAttempts: 1).isEmpty)
    }

    @Test("The audit export lists classified rows with their evidence and folds feedback in")
    func auditRowsCarryEvidence() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let item = makeItem("Screenshot 2026-10-29.png", documentID: 1, sourceID: source.id,
                            stage: .thumbnailed)
        let id = try await fixture.record([item]).first!
        try await fixture.catalog.recordAnalysis([
            MediaAnalysisResult(mediaID: id, statHash: item.identity.statHash, version: 1, revision: "test")
        ])
        try await classify(fixture, id, statHash: item.identity.statHash)

        let rows = try await fixture.reader.categoryAuditRows()
        let row = try #require(rows.first)
        #expect(row.mediaID == id)
        #expect(row.effectiveCategory == .screenshot)
        #expect(row.evidence?.category == .screenshot)
        #expect(row.evidence?.reasons.isEmpty == false)

        try await fixture.catalog.setCategoryFeedback(mediaID: id, category: .screenshot, verdict: -1)
        let excluded = try #require(try await fixture.reader.categoryAuditRows().first)
        #expect(excluded.effectiveCategory == MediaCategory.none)
        #expect(excluded.feedbackVerdict == -1)
        #expect(excluded.storedCategory == .screenshot, "the audit keeps what the classifier said")
    }

    @Test("A failed category hop can release its claims and retry without a relaunch")
    func failedHopsCanReleaseClaims() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let item = makeItem("IMG_0001.JPG", documentID: 1, sourceID: source.id, stage: .thumbnailed)
        let id = try await fixture.record([item]).first!
        try await fixture.catalog.recordAnalysis([
            MediaAnalysisResult(mediaID: id, statHash: item.identity.statHash, version: 1, revision: "test")
        ])

        let claimed = try await fixture.catalog.claimCategories(limit: 10)
        #expect(claimed.map(\.mediaID) == [id])
        try await fixture.catalog.releaseCategoryClaims([id])
        #expect(try await fixture.catalog.claimCategories(limit: 10).map(\.mediaID) == [id],
                "the released row is claimable again in the same session")
    }

    @Test("A backup that was restored, failed or purged is never offered as a previous version")
    func retiredBackupsAreNotOffered() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let id = try await fixture.record([
            makeItem("IMG_0001.JPG", documentID: 1, sourceID: source.id)
        ]).first!

        func makeBackup() async throws -> TrashLedgerEntry {
            let ledgerID = try await fixture.catalog.beginBackup(TrashLedgerEntry(
                mediaID: id, sourceID: source.id, fromRelativePath: "IMG_0001.JPG",
                fromVolumeID: "vol-1", mode: .editBackup, byteSize: 1024
            ))
            try await fixture.catalog.recordBackupDestination(
                ledgerID: ledgerID, path: "versions/\(ledgerID)/IMG_0001.JPG"
            )
            try await fixture.catalog.completeBackup(ledgerID: ledgerID, resultStatHash: 42)
            return try #require(try await fixture.catalog.latestBackup(mediaID: id))
        }

        let restored = try await makeBackup()
        try await fixture.catalog.recordBackupRestored(ledgerID: restored.id)
        #expect(try await fixture.catalog.latestBackup(mediaID: id) == nil,
                "reverting to bytes that are already on disk is not an offer")

        let failed = try await makeBackup()
        try await fixture.catalog.failBackup(ledgerID: failed.id, error: "disk full")
        #expect(try await fixture.catalog.latestBackup(mediaID: id) == nil)

        let live = try await makeBackup()
        #expect(try await fixture.catalog.latestBackup(mediaID: id)?.id == live.id)
        try #require(try await fixture.catalog.pendingBackups().isEmpty)
    }
}
