import Foundation
import Testing
@testable import GalleryDomain

private let page: [MediaID] = (1...10).map { MediaID(rawValue: Int64($0)) }
private func id(_ n: Int) -> MediaID { MediaID(rawValue: Int64(n)) }

@Test func plainAndModifiedClicksFollowTheTable() {
    var selection = MediaSelection(album: .all)
    selection.click(id(3), page: page, command: false, shift: false)
    #expect(selection.explicitIDs == [id(3)])
    #expect(selection.primary == id(3))
    #expect(selection.anchor == id(3))

    selection.click(id(5), page: page, command: true, shift: false)
    #expect(selection.explicitIDs == [id(3), id(5)])
    #expect(selection.primary == id(5))
    #expect(selection.anchor == id(5))

    selection.click(id(3), page: page, command: true, shift: false)
    #expect(selection.explicitIDs == [id(5)])
    #expect(selection.primary == id(5), "deselecting a non-primary keeps the primary")

    selection.click(id(2), page: page, command: false, shift: false)
    selection.click(id(6), page: page, command: false, shift: true)
    #expect(selection.explicitIDs == Set((2...6).map(id)))
    #expect(selection.primary == id(6))
    #expect(selection.anchor == id(2), "shift-click does not move the anchor")

    selection.click(id(9), page: page, command: false, shift: true)
    #expect(selection.explicitIDs == Set((2...9).map(id)),
            "a second shift-click extends from the same anchor, like an AppKit table")
}

@Test func commandClickTogglesInsideAWholeAlbumSelection() {
    var selection = MediaSelection(album: .all)
    selection.selectAllInAlbum()
    #expect(selection.isWholeAlbum)
    #expect(selection.contains(id(4)))
    #expect(selection.count(rowCount: 100) == 100)

    selection.click(id(4), page: page, command: true, shift: false)
    #expect(selection.isWholeAlbum)
    #expect(!selection.contains(id(4)))
    #expect(selection.count(rowCount: 100) == 99)

    selection.click(id(4), page: page, command: true, shift: false)
    #expect(selection.contains(id(4)))
    #expect(selection.count(rowCount: 100) == 100)
}

@Test func selectAllAndInvert() {
    var selection = MediaSelection(album: .all)
    selection.selectAllInAlbum()
    #expect(selection.count(rowCount: 10) == 10)

    selection.invert()
    #expect(selection.isEmpty, "inverting everything selects nothing")

    selection.selectOnly(id(2))
    selection.invert()
    #expect(selection.isWholeAlbum)
    #expect(selection.excludedIDs == [id(2)])
    #expect(selection.count(rowCount: 10) == 9)

    selection.invert()
    #expect(selection.explicitIDs == [id(2)], "inverting an all-but-one selection yields the one")
}

@Test func selectAllLoadedIsExplicit() {
    var selection = MediaSelection(album: .all, search: "kyoto")
    selection.selectAllLoaded(page)
    #expect(selection.explicitIDs == Set(page))
    #expect(selection.count(rowCount: 10) == 10)
    #expect(selection.batchSelection(rowCount: 10)?.explicit?.count == 10)
}

@Test func marqueeModes() {
    var selection = MediaSelection(album: .all)
    selection.marquee([id(1), id(2)], command: false, shift: false)
    #expect(selection.explicitIDs == [id(1), id(2)])

    selection.marquee([id(4)], command: false, shift: true)
    #expect(selection.explicitIDs == [id(1), id(2), id(4)])

    selection.marquee([id(2), id(4)], command: true, shift: false)
    #expect(selection.explicitIDs == [id(1)])

    selection.selectAllInAlbum()
    selection.marquee([id(1), id(2)], command: true, shift: false)
    #expect(selection.excludedIDs == [id(1), id(2)])
    #expect(selection.count(rowCount: 10) == 8)
}

@Test func subtractAndKeepPruneWithoutChangingTheMode() {
    var selection = MediaSelection(album: .all)
    selection.selectAllInAlbum()
    selection.subtract([id(1)])
    #expect(selection.isWholeAlbum)
    #expect(selection.count(rowCount: 10) == 9)

    selection.selectAllLoaded(page)
    selection.keep(only: [id(2), id(3), id(42)])
    #expect(selection.explicitIDs == [id(2), id(3)])

    selection.subtract([id(2), id(3)])
    #expect(selection.isEmpty)
    #expect(selection.primary == nil)
}

@Test func batchSelectionFreezesTheShape() {
    var selection = MediaSelection(album: .screenshots, search: nil)
    selection.selectAllInAlbum()
    let batch = selection.batchSelection(rowCount: 4_120, frozenAt: Date(timeIntervalSince1970: 10))
    #expect(batch?.explicit == nil)
    #expect(batch?.count == 4_120)
    #expect(batch?.album == .screenshots)
    let frozen = batch?.frozen(upperBound: id(9_999))
    #expect(frozen?.upperBound == id(9_999))

    selection.selectOnly(id(3))
    let explicit = selection.batchSelection(rowCount: 100)
    #expect(explicit?.explicit == [id(3)])
    #expect(explicit?.count == 1)

    selection.deselectAll()
    #expect(selection.batchSelection(rowCount: 100) == nil)
}

@Test func orderedExplicitPrefersTheGridOrder() {
    var selection = MediaSelection(album: .all)
    selection.marquee([id(8), id(2), id(5)], command: false, shift: false)
    #expect(selection.orderedExplicit(page: page) == [id(2), id(5), id(8)])

    selection.marquee([id(8), id(77)], command: false, shift: false)
    #expect(selection.orderedExplicit(page: page) == [id(8), id(77)],
            "off-page ids follow in id order")
}

@Test func resetClearsEveryPart() {
    var selection = MediaSelection(album: .all)
    selection.selectOnly(id(4))
    selection.setPrimary(id(4))
    selection.reset(album: .favorites, search: nil)
    #expect(selection.isEmpty)
    #expect(selection.primary == nil)
    #expect(selection.anchor == nil)
    #expect(selection.album == .favorites)
}
