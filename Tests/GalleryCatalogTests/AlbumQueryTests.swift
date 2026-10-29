import Foundation
import Testing
@testable import GalleryCatalog
import GalleryDomain
import GallerySQLite

@Suite("Album predicates compile to indexed SQL")
struct AlbumQueryTests {
    @Test("A folder album is one equality on an indexed column")
    func folder() {
        let compiled = AlbumQuery.compile(.folder(SourceID(rawValue: 7)))
        #expect(compiled.whereSQL.contains("media.src_id = ?"))
        #expect(compiled.arguments == [.integer(7)])
    }

    @Test("A subfolder album covers its own files and its descendants")
    func subfolder() {
        let compiled = AlbumQuery.compile(.subfolder(SourceID(rawValue: 1), relativePath: "DCIM/100APPLE"))
        #expect(compiled.whereSQL.contains("media.parent_rel = ?"))
        #expect(compiled.whereSQL.contains("media.parent_rel LIKE ?"))
        #expect(compiled.arguments == [.integer(1), .text("DCIM/100APPLE"), .text("DCIM/100APPLE/%")])
    }

    @Test("Every album keeps trashed rows out except the one built to show them")
    func trashConjunction() {
        let visible: [AlbumKind] = [.all, .allPhotos, .favorites, .day(20240605), .month(202406)]
        for kind in visible {
            #expect(AlbumQuery.compile(kind).whereSQL.contains("media.trash = 0"), "\(kind)")
        }
        #expect(AlbumQuery.compile(.recentlyDeleted).whereSQL == "media.trash = ?")
        #expect(AlbumQuery.compile(.recentlyDeleted).arguments == [.integer(1)])
        #expect(!AlbumQuery.compile(.problems).whereSQL.contains("trash"))
    }

    @Test("A date album reads the precomputed bucket, never a date function")
    func dayAndMonth() {
        #expect(AlbumQuery.compile(.day(20240605)).arguments == [.integer(20240605)])
        #expect(AlbumQuery.compile(.month(202406)).arguments == [.integer(202406)])
    }

    @Test("Combining an album with a filter nests both sides")
    func composition() {
        let combined = AlbumQuery.compile(.allVideos).and(CompiledQuery(whereSQL: "media.is_offline = 1", arguments: []))
        #expect(combined.whereSQL.hasPrefix("("))
        #expect(combined.whereSQL.contains(") AND ("))
    }

    @Test("A smart rule keeps AND, OR and NOT distinct")
    func ruleShapes() {
        let rule = SmartRule(
            name: "Long videos",
            all: [SmartPredicate(.kindEquals, .integer(Int64(MediaKind.video.rawValue)))],
            any: [SmartPredicate(.minDurationSeconds, .real(60)),
                  SmartPredicate(.byteSizeAtLeast, .integer(50_000_000))],
            none: [SmartPredicate(.subtypeIncludes, .integer(Int64(MediaSubtype.screenshot.rawValue)))]
        )
        let compiled = AlbumQuery.compile(rule: rule)
        #expect(compiled.whereSQL.contains("media.kind = ?"))
        #expect(compiled.whereSQL.contains("(media.duration_us >= ? OR media.size_bytes >= ?)"))
        #expect(compiled.whereSQL.contains("NOT ((media.subtype & ?) <> 0)"))
        #expect(compiled.arguments == [.integer(1), .integer(60_000_000), .integer(50_000_000), .integer(1)])
    }

    @Test("An empty rule shows everything rather than nothing")
    func emptyRule() {
        let compiled = AlbumQuery.compile(rule: SmartRule(name: "Unfinished"))
        #expect(compiled.whereSQL == "1")
        #expect(compiled.arguments.isEmpty)
    }

    /// The injection defence is the whitelist: a rule payload can only ever arrive as a bound value, so a
    /// saved rule written by a hostile or compromised older build cannot change the shape of the SQL.
    @Test("Rule text reaches SQL only as a parameter")
    func valuesAreNeverInterpolated() {
        let hostile = "'; DROP TABLE media; --"
        let compiled = AlbumQuery.compile(rule: SmartRule(
            name: "evil",
            all: [SmartPredicate(.nameContains, .text(hostile)),
                  SmartPredicate(.parentRelHasPrefix, .text(hostile)),
                  SmartPredicate(.placeKeyEquals, .text(hostile))]
        ))
        #expect(!compiled.whereSQL.contains("DROP"))
        #expect(compiled.whereSQL.filter { $0 == "?" }.count == 3)
        #expect(compiled.arguments.contains(.text("%" + hostile + "%")))
    }

    @Test("Unknown predicate values fail closed, not open")
    func coercionFailureIsNotAMatchAll() {
        // `.text` where an integer belongs: `intValue` is nil, and the fallback must not be a wildcard.
        let compiled = AlbumQuery.compile(rule: SmartRule(name: "mixed", all: [
            SmartPredicate(.kindEquals, .text("not a number")),
        ]))
        #expect(compiled.arguments == [.integer(-1)])
        #expect(!compiled.whereSQL.contains("not a number"))
    }

    @Test("Album identity is a function of the kind, so selection survives a relaunch")
    func stableIDs() {
        let kind = AlbumKind.subfolder(SourceID(rawValue: 3), relativePath: "Holiday")
        #expect(Album.syntheticID(for: kind) == Album.syntheticID(for: kind))
        #expect(Album.syntheticID(for: kind) != Album.syntheticID(for: .subfolder(SourceID(rawValue: 3),
                                                                                  relativePath: "Work")))
        #expect(Album.day(20240605, count: 4).id == Album.day(20240605, count: 9).id)
    }

    @Test("Sorting is a closed set of expressions")
    func sortWhitelist() {
        for field in SortField.allCases {
            #expect(!field.columnSQL.contains(";"))
            #expect(!field.columnSQL.contains("--"))
        }
        #expect(MediaSort.default.orderBySQL == "cap_utc DESC, id DESC")
        #expect(MediaSort(field: .pixelCount, order: .ascending).keysetPredicateSQL
                == "(COALESCE(px_w, 0) * COALESCE(px_h, 0), id) > (?, ?)")
    }
}

@Suite("Search text compiles to an FTS5 query")
struct SearchQueryTests {
    @Test("Words become quoted terms joined by AND")
    func words() {
        #expect(SearchQuery.compile("kyoto 2024") == "\"kyoto\" AND \"2024\"")
    }

    @Test("A quoted run stays one phrase and keeps its inner spaces")
    func phrases() {
        #expect(SearchQuery.compile("\"golden gate\" bridge") == "\"golden gate\" AND \"bridge\"")
    }

    @Test("Prefix matching extends bare words only")
    func prefix() {
        #expect(SearchQuery.compile("kyo", prefix: true) == "\"kyo\"*")
        #expect(SearchQuery.compile("\"golden gat\"", prefix: true) == "\"golden gat\"")
    }

    @Test("FTS operators and punctuation are content, not syntax")
    func operatorsAreLiteral() {
        #expect(SearchQuery.compile("AND OR NOT") == "\"AND\" AND \"OR\" AND \"NOT\"")
        #expect(SearchQuery.compile("a b NEAR (c, d)") == "\"a\" AND \"b\" AND \"NEAR\" AND \"(c,\" AND \"d)\"")
        #expect(SearchQuery.compile("cols:term") == "\"cols:term\"")
        #expect(SearchQuery.compile("{param}") == "\"{param}\"")
    }

    @Test("An embedded quote is a term boundary, not a syntax hole")
    func quoteEscaping() {
        #expect(SearchQuery.compile("say \"hi\"") == "\"say\" AND \"hi\"")
        #expect(SearchQuery.compile("a\"b") == "\"a\" AND \"b\"")
        #expect(SearchQuery.compile("\"unterminated") == "\"unterminated\"")
    }

    @Test("Nothing to search for is not an error")
    func empty() {
        #expect(SearchQuery.compile("") == nil)
        #expect(SearchQuery.compile("   \t ") == nil)
        #expect(SearchQuery.compile("\"\"") == nil)
    }

    @Test("A stuck key cannot build an unbounded query")
    func termCap() throws {
        let long = (0...80).map { _ in "word" }.joined(separator: " ")
        let compiled = try #require(SearchQuery.compile(long))
        #expect(compiled.components(separatedBy: " AND ").count == SearchQuery.maximumTerms)
    }
}
