import Foundation

/// How the grid's selection is represented. A set of ids is the small case; "the whole album minus a few"
/// is what makes a thousand-row cleanup possible without loading a thousand rows.
public enum SelectionMode: Sendable, Hashable {
    case none
    case explicit(Set<MediaID>)
    case wholeAlbum(except: Set<MediaID>)
}

/// The selection the grid is showing, and the album it belongs to.
///
/// Pure and value-typed: every gesture is a transition here, so the click/marquee/select-all rules are
/// tested exactly instead of being inferred from what the grid did.
public struct MediaSelection: Sendable, Hashable {
    public private(set) var album: AlbumKind
    public private(set) var search: String?
    public private(set) var mode: SelectionMode
    /// The row a ⇧-click extends from: the last row clicked without ⇧.
    public private(set) var anchor: MediaID?
    /// The row the inspector and Return describe. Always a row the user clicked.
    public private(set) var primary: MediaID?

    public init(album: AlbumKind = .all, search: String? = nil) {
        self.album = album
        self.search = search
        self.mode = .none
    }

    /// A whole-album selection is non-empty by construction; the count is what the UI shows, and an empty
    /// album makes `count` zero and `batchSelection` nil.
    public var isEmpty: Bool {
        switch mode {
        case .none: true
        case .explicit(let ids): ids.isEmpty
        case .wholeAlbum: false
        }
    }

    public var isWholeAlbum: Bool {
        if case .wholeAlbum = mode { return true }
        return false
    }

    /// Nil for a whole-album selection (the ids are the query's business, not the selection's).
    public var explicitIDs: Set<MediaID>? {
        if case .explicit(let ids) = mode { return ids }
        return nil
    }

    public var excludedIDs: Set<MediaID> {
        if case .wholeAlbum(let excluded) = mode { return excluded }
        return []
    }

    public func contains(_ id: MediaID) -> Bool {
        switch mode {
        case .none: false
        case .explicit(let ids): ids.contains(id)
        case .wholeAlbum(let excluded): !excluded.contains(id)
        }
    }

    /// What the UI should say, given how many rows the album currently holds.
    public func count(rowCount: Int) -> Int {
        switch mode {
        case .none: 0
        case .explicit(let ids): ids.count
        case .wholeAlbum(let excluded): max(0, rowCount - excluded.count)
        }
    }

    /// The ids in grid order: the page's order first, then the off-page ids by id. Rename uses this so a
    /// sequence follows what the user sees.
    public func orderedExplicit(page: [MediaID]) -> [MediaID] {
        guard case .explicit(let ids) = mode else { return [] }
        var ordered = page.filter { ids.contains($0) }
        let seen = Set(ordered)
        ordered.append(contentsOf: ids.subtracting(seen).sorted { $0.rawValue < $1.rawValue })
        return ordered
    }

    // MARK: - Transitions

    public mutating func reset(album: AlbumKind, search: String?) {
        self.album = album
        self.search = search
        mode = .none
        anchor = nil
        primary = nil
    }

    public mutating func selectOnly(_ id: MediaID) {
        mode = .explicit([id])
        anchor = id
        primary = id
    }

    public mutating func deselectAll() {
        mode = .none
        anchor = nil
        primary = nil
    }

    public mutating func setPrimary(_ id: MediaID?) {
        primary = id
    }

    /// A plain click replaces, ⌘ toggles, ⇧ selects the page-order range from the anchor.
    public mutating func click(_ id: MediaID, page: [MediaID], command: Bool, shift: Bool) {
        if shift, let anchor, let start = page.firstIndex(of: anchor), let end = page.firstIndex(of: id) {
            let bounds = start <= end ? start...end : end...start
            mode = .explicit(Set(page[bounds]))
            primary = id
            return
        }
        if command {
            var wasSelected: Bool
            switch mode {
            case .none:
                mode = .explicit([id])
                wasSelected = false
            case .explicit(var ids):
                wasSelected = ids.contains(id)
                if wasSelected { ids.remove(id) } else { ids.insert(id) }
                mode = ids.isEmpty ? .none : .explicit(ids)
            case .wholeAlbum(var excluded):
                wasSelected = !excluded.contains(id)
                if wasSelected { excluded.insert(id) } else { excluded.remove(id) }
                mode = .wholeAlbum(except: excluded)
            }
            anchor = id
            if wasSelected {
                primary = page.last { contains($0) }
            } else {
                primary = id
            }
            return
        }
        mode = .explicit([id])
        anchor = id
        primary = id
    }

    /// A rubber band. A plain drag replaces, ⌘ toggles the swept ids, ⇧ adds them.
    public mutating func marquee(_ ids: [MediaID], command: Bool, shift: Bool) {
        guard !ids.isEmpty else { return }
        let swept = Set(ids)
        if command {
            switch mode {
            case .none:
                mode = .explicit(swept)
            case .explicit(var current):
                let already = swept.intersection(current)
                current.subtract(already)
                current.formUnion(swept.subtracting(already))
                mode = current.isEmpty ? .none : .explicit(current)
            case .wholeAlbum(var excluded):
                excluded.formUnion(swept)
                mode = .wholeAlbum(except: excluded)
            }
        } else if shift {
            switch mode {
            case .wholeAlbum:
                // Adding to "everything" changes nothing.
                break
            case .none, .explicit:
                var current = explicitIDs ?? []
                current.formUnion(swept)
                mode = .explicit(current)
            }
        } else {
            mode = .explicit(swept)
        }
        primary = ids.first
        if !shift { anchor = ids.first }
    }

    /// ⌘A. The whole album (or the loaded hits while a search is on, because search is capped at 500).
    public mutating func selectAllInAlbum() {
        mode = .wholeAlbum(except: [])
        anchor = nil
        primary = nil
    }

    public mutating func selectAllLoaded(_ page: [MediaID]) {
        guard !page.isEmpty else { return }
        mode = .explicit(Set(page))
        anchor = page.first
        primary = page.first
    }

    public mutating func invert() {
        let previous = mode
        switch previous {
        case .none:
            mode = .wholeAlbum(except: [])
        case .explicit(let ids):
            mode = .wholeAlbum(except: ids)
        case .wholeAlbum(let excluded):
            mode = excluded.isEmpty ? .none : .explicit(excluded)
        }
        anchor = nil
        primary = nil
    }

    /// Removes rows an action just consumed (they left the album).
    public mutating func subtract(_ ids: [MediaID]) {
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        switch mode {
        case .none:
            break
        case .explicit(var current):
            current.subtract(gone)
            mode = current.isEmpty ? .none : .explicit(current)
        case .wholeAlbum(var excluded):
            excluded.formUnion(gone)
            mode = .wholeAlbum(except: excluded)
        }
        if let primary, gone.contains(primary) { self.primary = nil }
        if let anchor, gone.contains(anchor) { self.anchor = nil }
    }

    /// Drops explicit ids the album no longer holds. Whole-album selections are defined by the predicate, so
    /// only stale exclusions are pruned.
    public mutating func keep(only alive: Set<MediaID>) {
        switch mode {
        case .none:
            break
        case .explicit(var current):
            current.formIntersection(alive)
            mode = current.isEmpty ? .none : .explicit(current)
        case .wholeAlbum(var excluded):
            excluded.formIntersection(alive)
            mode = .wholeAlbum(except: excluded)
        }
        if let primary, !isWholeAlbum, !alive.contains(primary) { self.primary = nil }
    }

    /// What an action consumes: a frozen value, never the live selection.
    public func batchSelection(rowCount: Int, frozenAt: Date = Date()) -> BatchSelection? {
        switch mode {
        case .none:
            return nil
        case .explicit(let ids):
            guard !ids.isEmpty else { return nil }
            return BatchSelection(
                album: album, search: search,
                explicit: ids.sorted { $0.rawValue < $1.rawValue },
                excluded: [], upperBound: nil, count: ids.count, frozenAt: frozenAt
            )
        case .wholeAlbum(let excluded):
            let total = max(0, rowCount - excluded.count)
            guard total > 0 else { return nil }
            return BatchSelection(
                album: album, search: search, explicit: nil, excluded: excluded,
                upperBound: nil, count: total, frozenAt: frozenAt
            )
        }
    }
}

/// A selection frozen for an action: the count the user was told, the boundary the rows were counted at, and
/// the rows to skip. Actions resolve this in chunks rather than holding every row.
public struct BatchSelection: Sendable, Hashable {
    public var album: AlbumKind
    public var search: String?
    /// Nil means "every row of the album", resolved by paging.
    public var explicit: [MediaID]?
    public var excluded: Set<MediaID>
    /// Frozen at confirmation: rows scanned later are not swept into the action.
    public var upperBound: MediaID?
    public var count: Int
    public var frozenAt: Date

    public init(
        album: AlbumKind, search: String? = nil, explicit: [MediaID]?, excluded: Set<MediaID> = [],
        upperBound: MediaID? = nil, count: Int, frozenAt: Date = Date()
    ) {
        self.album = album
        self.search = search
        self.explicit = explicit
        self.excluded = excluded
        self.upperBound = upperBound
        self.count = count
        self.frozenAt = frozenAt
    }

    public var isWholeAlbum: Bool { explicit == nil }

    public func frozen(upperBound: MediaID?) -> BatchSelection {
        var copy = self
        copy.upperBound = upperBound
        return copy
    }
}
