import Foundation
import GalleryDomain

/// The judgements that sit between Vision's vocabulary and the app's.
///
/// Kept pure and separate from the framework so the rules can be tested exactly, and so a change in what
/// "food" means is a table edit rather than a code change inside a request handler.
public enum AnalysisRules {
    /// Classifier identifiers are long and nested ("food.pizza", "beverage.coffee"); the mapping is by
    /// containment so one entry covers a family, longest key first so "fast food" wins over "food".
    private static let labelMapping: [(key: String, slug: String)] = [
        ("fast food", "food"), ("food", "food"), ("meal", "food"), ("pizza", "food"),
        ("dessert", "food"), ("bakery", "food"), ("restaurant", "food"),
        ("beverage", "drinks"), ("drink", "drinks"), ("coffee", "drinks"), ("wine", "drinks"),
        ("cocktail", "drinks"), ("beer", "drinks"),
        ("document", "documents"), ("receipt", "documents"), ("invoice", "documents"),
        ("menu", "documents"), ("whiteboard", "documents"), ("business card", "documents"),
        ("paper", "documents"), ("book", "documents"),
        ("plant", "nature"), ("flower", "nature"), ("tree", "nature"), ("forest", "nature"),
        ("grass", "nature"), ("mountain", "nature"), ("landscape", "nature"),
        ("ocean", "water"), ("sea", "water"), ("beach", "water"), ("lake", "water"),
        ("river", "water"), ("waterfall", "water"), ("wave", "water"), ("swimming pool", "water"),
        ("building", "architecture"), ("architecture", "architecture"), ("house", "architecture"),
        ("bridge", "architecture"), ("tower", "architecture"), ("church", "architecture"),
        ("castle", "architecture"), ("cityscape", "architecture"),
        ("car", "vehicles"), ("vehicle", "vehicles"), ("automobile", "vehicles"),
        ("bicycle", "vehicles"), ("motorcycle", "vehicles"), ("train", "vehicles"),
        ("airplane", "vehicles"), ("boat", "vehicles"),
        ("dog", "pets"), ("cat", "pets"), ("puppy", "pets"), ("kitten", "pets"), ("pet", "pets"),
        ("bird", "wildlife"), ("animal", "wildlife"), ("insect", "wildlife"), ("wildlife", "wildlife"),
        ("person", "people"), ("people", "people"), ("selfie", "people"), ("portrait", "people"),
        ("art", "art"), ("painting", "art"), ("sculpture", "art"), ("drawing", "art"),
        ("graffiti", "art"),
        ("night", "night"), ("moon", "night"), ("star", "night"), ("aurora", "night"),
        ("sport", "sports"), ("basketball", "sports"), ("soccer", "sports"), ("tennis", "sports"),
        ("running", "sports"), ("ski", "sports"), ("surf", "sports"), ("skate", "sports"),
    ]

    private static let documentWords = ["document", "receipt", "invoice", "whiteboard", "text", "menu",
                                        "paper"]

    /// Curated slugs for one picture. Raw labels still go to search separately; these are the albums.
    public static func tags(from labels: [SceneLabel], ocrCharacters: Int,
                            confidence: Double = 0.35, limit: Int = 4) -> [String] {
        var slugs: [String] = []
        for label in labels.sorted(by: { $0.confidence > $1.confidence })
        where label.confidence >= confidence {
            let identifier = label.identifier.lowercased()
            guard let match = labelMapping.first(where: { identifier.contains($0.key) }) else { continue }
            if !slugs.contains(match.slug) { slugs.append(match.slug) }
            if slugs.count >= limit { return slugs }
        }
        if ocrCharacters >= 40, slugs.count < limit { slugs.append("text") }
        return slugs
    }

    /// A screenshot of a chat, a receipt, a whiteboard: worth OCR, never worth an album cover or a "best of".
    public static func isUtility(aesthetic: Double, ocrCharacters: Int, labels: [SceneLabel],
                                 subtype: MediaSubtype, modelSaidSo: Bool) -> Bool {
        if subtype.contains(.screenshot) { return true }
        if modelSaidSo { return true }
        if aesthetic < 0.05, ocrCharacters >= 40 { return true }
        return labels.contains { label in
            label.confidence >= 0.6
                && documentWords.contains { label.identifier.lowercased().contains($0) }
        }
    }

    /// Recognised lines, in reading order, on one line, capped on a word boundary. Newlines inside a
    /// `search_text` field are noise: FTS splits on any whitespace anyway, and the inspector shows one blob.
    public static func normalizedOCR(_ lines: [String], limit: Int = 4096) -> String? {
        let joined = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let collapsed = joined.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        let cut = collapsed.prefix(limit)
        if let lastSpace = cut.lastIndex(of: " ") {
            return String(cut[..<lastSpace])
        }
        return String(cut)
    }
}
