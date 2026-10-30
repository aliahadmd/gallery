import Foundation
import Testing
@testable import GalleryUI
import GalleryCatalog
import GalleryDomain

@Suite("Category audit")
struct CategoryAuditTests {
    @Test("CSV fields are quoted, doubled and kept on one line")
    func csvEscaping() {
        let evidence = CategoryEvidence(
            category: .screenshot, confidence: 0.9, score: 104,
            reasons: [CategoryReason(code: .uiLabels, weight: 12, detail: "a,b")],
            version: 1, revision: "signals-v1"
        )
        let rows = [
            CatalogReader.CategoryAuditRow(
                mediaID: MediaID(rawValue: 1),
                relativePath: "holiday/IMG,\"1\".png",
                name: "IMG, 1.png",
                storedCategory: .screenshot, storedConfidence: 0.9,
                evidence: evidence, sampledSide: 96, version: 1, revision: "signals-v1"
            ),
            CatalogReader.CategoryAuditRow(
                mediaID: MediaID(rawValue: 2), relativePath: "photo.jpg", name: "photo.jpg",
                storedCategory: .photo, storedConfidence: 0.2
            ),
        ]
        let csv = CategoryAudit.csv(rows)
        let lines = csv.split(separator: "\n")
        #expect(lines.count == 3, "header plus one line per row")
        #expect(csv.hasSuffix("\n"))
        #expect(csv.contains("\"holiday/IMG,\"\"1\"\".png\""))
        #expect(csv.contains("\"IMG, 1.png\""))
        #expect(csv.hasPrefix("path,name,stored_category"))
        #expect(lines[2].hasSuffix(","), "the review column is present and empty")
    }

    @Test("Feedback changes the effective category the audit reports")
    func feedbackIsFoldedIn() {
        var row = CatalogReader.CategoryAuditRow(
            mediaID: MediaID(rawValue: 1), relativePath: "a.png", name: "a.png",
            storedCategory: .screenshot, storedConfidence: 0.9
        )
        #expect(row.effectiveCategory == .screenshot)
        row.feedbackCategory = .screenshot
        row.feedbackVerdict = -1
        #expect(row.effectiveCategory == MediaCategory.none)
        row.feedbackCategory = .document
        row.feedbackVerdict = 1
        #expect(row.effectiveCategory == .document)
    }
}
