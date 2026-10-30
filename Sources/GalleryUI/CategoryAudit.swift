import Foundation
import GalleryCatalog
import GalleryDomain

/// The category audit as a CSV a person can open in Numbers or a spreadsheet.
///
/// The classifier promises explainable verdicts; this is how that promise gets checked against a real
/// library. The `review` column is deliberately empty: a human fills it with the correct category, and the
/// difference between `effective_category` and `review` is the measured precision.
public enum CategoryAudit {
    public static let header = [
        "path", "name", "stored_category", "confidence", "effective_category", "verdict",
        "evidence_category", "evidence_confidence", "score", "sampled_side", "reasons", "review",
    ]

    public static func csv(_ rows: [CatalogReader.CategoryAuditRow]) -> String {
        var lines = [header.joined(separator: ",")]
        for row in rows {
            let reasons = row.evidence?.reasons
                .map { "\($0.code.rawValue):\($0.weight)" }
                .joined(separator: "|") ?? ""
            let fields: [String] = [
                row.relativePath,
                row.name,
                String(row.storedCategory.rawValue),
                number(row.storedConfidence),
                String(row.effectiveCategory.rawValue),
                row.feedbackVerdict.map(String.init) ?? "",
                row.evidence.map { String($0.category.rawValue) } ?? "",
                row.evidence.map { number($0.confidence) } ?? "",
                row.evidence.map { number($0.score) } ?? "",
                row.sampledSide.map(String.init) ?? "",
                reasons,
                "",
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `Double` description is locale-independent (always a dot), which a CSV must be.
    private static func number(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"")
                || field.contains("\n") || field.contains("\r") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
