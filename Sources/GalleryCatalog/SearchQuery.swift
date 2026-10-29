import Foundation
import GallerySQLite

/// Turns what the user typed into something `media_fts MATCH ?` can accept.
///
/// FTS5 has its own mini-language — bare `AND`/`OR`/`NOT`, `NEAR`, `col:term`, `{param}` — and most of it is
/// a syntax *error* when it arrives from a search field. A user typing `sunrise & clouds` or `Tokyo!'`
/// would otherwise get a thrown `stepFailed`, and the app would look broken. So every term leaves as a
/// quoted string literal, which makes FTS5 treat it as text and nothing else; the only live syntax is what
/// this file adds.
public enum SearchQuery {
    /// A search this long is not a search; bounding it keeps one stuck key from compiling a 500-term
    /// boolean expression against a 200k-row index.
    static let maximumTerms = 32

    /// `nil` means "nothing to search for", which the caller renders as an empty result set rather than an
    /// error — an empty field is the common case, not the exceptional one.
    public static func compile(_ rawText: String, prefix: Bool = false) -> String? {
        let terms = terms(in: rawText)
        guard !terms.isEmpty else { return nil }

        let compiled = terms.prefix(maximumTerms).map { term -> String in
            // `*` has to sit outside the quotes; inside them it is a literal asterisk.
            let literal = "\"\(term.text)\""
            return prefix && term.isWord ? "\(literal)*" : literal
        }
        return compiled.joined(separator: " AND ")
    }

    private struct Term {
        var text: String
        /// A quoted run matches as a phrase; a bare word is the one that may take the prefix extension.
        var isWord: Bool
    }

    /// Splits on whitespace, but a double-quoted run survives as one phrase, so `"golden gate"` cannot
    /// match a photo of some other bridge taken near some other gate.
    private static func terms(in text: String) -> [Term] {
        var terms: [Term] = []
        var current = ""
        var insideQuotes = false

        func flush() {
            guard !current.isEmpty else { return }
            terms.append(Term(text: current, isWord: !insideQuotes))
            current = ""
        }

        for character in text {
            switch character {
            case "\"":
                // A quote is a boundary, never content: `a"b` is two terms, not one with an escape in it.
                flush()
                insideQuotes.toggle()
            case " ", "\t", "\n", "\r":
                // Whitespace inside a phrase is content, not a separator.
                if insideQuotes { current.append(character) } else { flush() }
            default:
                current.append(character)
            }
        }
        if !current.isEmpty {
            terms.append(Term(text: current, isWord: !insideQuotes))
        }
        return terms
    }
}
