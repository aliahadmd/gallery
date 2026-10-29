import Foundation

/// The closed set of scene tags an album can be made of.
///
/// Vision's classifier speaks in 1,300 identifiers — "structure", "white", "indoor" — which is a fine signal
/// and a terrible sidebar. The analyser maps those labels onto these slugs, so a tag album is a curated
/// judgement ("Food", "Documents") rather than a vocabulary dump, while the raw labels still land in search.
public enum TagVocabulary {
    public struct Tag: Sendable, Hashable, Identifiable {
        public var slug: String
        public var title: String
        public var symbol: String

        public var id: String { slug }
    }

    public static let all: [Tag] = [
        Tag(slug: "food", title: "Food", symbol: "fork.knife"),
        Tag(slug: "drinks", title: "Drinks", symbol: "cup.and.saucer"),
        Tag(slug: "documents", title: "Documents", symbol: "doc.text"),
        Tag(slug: "text", title: "Text", symbol: "textformat"),
        Tag(slug: "nature", title: "Nature", symbol: "leaf"),
        Tag(slug: "water", title: "Water", symbol: "drop"),
        Tag(slug: "architecture", title: "Architecture", symbol: "building.2"),
        Tag(slug: "vehicles", title: "Vehicles", symbol: "car"),
        Tag(slug: "pets", title: "Pets", symbol: "pawprint"),
        Tag(slug: "wildlife", title: "Wildlife", symbol: "bird"),
        Tag(slug: "people", title: "People", symbol: "person.2"),
        Tag(slug: "art", title: "Art", symbol: "paintpalette"),
        Tag(slug: "night", title: "Night", symbol: "moon.stars"),
        Tag(slug: "sports", title: "Sports", symbol: "figure.run"),
    ]

    public static let slugs: Set<String> = Set(all.map(\.slug))

    public static func tag(for slug: String) -> Tag? { all.first { $0.slug == slug } }
    public static func title(for slug: String) -> String { tag(for: slug)?.title ?? slug.capitalized }
    public static func symbol(for slug: String) -> String { tag(for: slug)?.symbol ?? "tag" }
}
