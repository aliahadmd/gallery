import Foundation
import Testing
@testable import GalleryAnalysis
import GalleryCatalog
import GalleryDomain

@Suite("Duplicate matching")
struct DuplicateFinderTests {
    private func candidate(_ id: Int64, hash: UInt64, aspect: Double = 4.0 / 3.0,
                           parent: String = "roll-1", capture: Double = 1_000) -> DuplicateCandidate {
        DuplicateCandidate(mediaID: MediaID(rawValue: id), dhash: hash, dayBucket: 20240504,
                           parentDirectory: parent, captureUTC: capture, pixelWidth: 4000,
                           pixelHeight: 3000, aesthetic: 0, isUtility: false)
    }

    private func probe(_ hash: UInt64, parent: String = "roll-1", capture: Double = 1_000)
        -> DuplicateFinder.Probe {
        DuplicateFinder.Probe(dhash: hash, aspectRatio: 4.0 / 3.0, parentDirectory: parent,
                              captureUTC: capture)
    }

    @Test("An exact copy matches without corroboration")
    func exactCopy() {
        let finder = DuplicateFinder()
        let match = finder.match(probe(0xAAAA_AAAA_AAAA_AAAA),
                                 among: [candidate(1, hash: 0xAAAA_AAAA_AAAA_AAAA)])
        #expect(match?.candidate.mediaID == MediaID(rawValue: 1))
        #expect(match?.distance == 0)
    }

    @Test("A few bits apart still matches — that is a re-encode")
    func nearCopy() {
        let finder = DuplicateFinder()
        let match = finder.match(probe(0b1111),
                                 among: [candidate(1, hash: 0b1000)])
        #expect(match?.distance == 3)
    }

    @Test("The grey zone needs a matching shape and the same place or moment")
    func corroboration() {
        let finder = DuplicateFinder()
        // Eight bits apart: plausible only with corroboration.
        let hash: UInt64 = 0b1111_1111
        let other: UInt64 = 0b0000_0000
        #expect(finder.match(probe(hash), among: [candidate(1, hash: other)]) != nil,
                "same folder, same second")

        let elsewhere = candidate(2, hash: other, parent: "roll-2", capture: 90_000)
        #expect(finder.match(probe(hash), among: [elsewhere]) == nil,
                "unrelated pictures in unrelated folders do not become duplicates")
    }

    @Test("Far apart is not a duplicate at all")
    func unrelated() {
        let finder = DuplicateFinder()
        #expect(finder.match(probe(0xFFFF_FFFF_FFFF_FFFF),
                             among: [candidate(1, hash: 0)]) == nil)
    }
}
