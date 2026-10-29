import Testing
import Foundation
import UniformTypeIdentifiers
import GalleryDomain
@testable import GalleryIndexing

/// What pass A decides about a file from its name, its extension, and whatever type the filesystem
/// already knew — without opening it.
@Suite("What a file is, before anyone reads it")
struct MediaTypeRulesTests {
    @Test("An extension alone is enough to make a JPEG a photo")
    func extensionOnly() {
        let result = MediaTypeRules.classify(name: "IMG_1234", fileExtension: "jpg", contentType: nil)
        #expect(result.isGalleryContent)
        #expect(result.kind == .image)
        #expect(result.uniformTypeIdentifier == "public.jpeg")
    }

    @Test("Uppercase and odd spellings of the same format land in the same album")
    func caseInsensitive() {
        for ext in ["JPG", "jpeg", "Heic"] {
            let result = MediaTypeRules.classify(name: "x", fileExtension: ext, contentType: nil)
            #expect(result.isGalleryContent, "\(ext) should be gallery content")
        }
    }

    @Test("A file the type database recognises as something else is not a photo")
    func namedNonMediaTypeLoses() {
        let liar = MediaTypeRules.classify(name: "notes", fileExtension: "jpg", contentType: .plainText)
        #expect(!liar.isGalleryContent)
        let archive = MediaTypeRules.classify(name: "backup", fileExtension: "mov", contentType: .zip)
        #expect(!archive.isGalleryContent)
    }

    @Test("A type the filesystem has no opinion about does not overrule the extension")
    func uninformativeTypeYields() {
        // This is the SMB-share and off-the-internet case: `public.data` means LaunchServices never
        // looked, and dropping the file would leave the user with a hole in their library and no reason.
        #expect(MediaTypeRules.isUninformative(.data))
        let raw = MediaTypeRules.classify(name: "IMG_0001", fileExtension: "cr2", contentType: .data)
        #expect(raw.isGalleryContent)
        #expect(raw.kind == .image)
        #expect(raw.subtype.contains(.raw))
    }

    @Test("The declared type decides image versus video when it actually knows")
    func declaredTypeDecides() {
        #expect(MediaTypeRules.classify(name: "clip", fileExtension: "mp4", contentType: .movie).kind == .video)
        // A `.mp4` that is really a still (rare, but it exists in exported slide decks) follows the type.
        let still = MediaTypeRules.classify(name: "poster", fileExtension: "mp4", contentType: .jpeg)
        #expect(still.kind == .image)
    }

    @Test("A RAW container stays a picture even when its type claims footage")
    func rawContainerIsAlwaysAnImage() {
        // Canon's Dual Pixel RAW files register as movies on some systems and carry a clip inside; the
        // still is the content the user took a photo of.
        let cr3 = MediaTypeRules.classify(name: "IMG_9", fileExtension: "cr3", contentType: .movie)
        #expect(cr3.kind == .image)
        let mov = MediaTypeRules.classify(name: "MOV_9", fileExtension: "mov", contentType: nil)
        #expect(mov.kind == .video)
    }

    @Test("Subtype bits are set from format and from naming convention")
    func subtypes() {
        let heic = MediaTypeRules.classify(name: "IMG_1", fileExtension: "heic", contentType: nil)
        #expect(heic.subtype.contains(.heic))
        let gif = MediaTypeRules.classify(name: "loop", fileExtension: "gif", contentType: nil)
        #expect(gif.subtype.contains(.gif))
        #expect(gif.subtype.contains(.animated))
        let shot = MediaTypeRules.classify(name: "Screenshot 2026-03-01 at 09.12.jpg",
                                          fileExtension: "jpg", contentType: nil)
        #expect(shot.subtype.contains(.screenshot))
        let plain = MediaTypeRules.classify(name: "IMG_1", fileExtension: "jpg", contentType: nil)
        #expect(plain.subtype.isEmpty)
    }

    @Test("Only gallery extensions ever reach the classifier")
    func nonMediaExtensions() {
        for ext in ["txt", "zip", "dmg", "pdf", ""] {
            #expect(!MediaTypeRules.classify(name: "f", fileExtension: ext, contentType: nil).isGalleryContent,
                    "\(ext) is not gallery content")
        }
    }

    @Test("A Live Photo is two files and only one of them is a video")
    func livePhotoPair() {
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        var entries = [
            entry("IMG_1.HEIC", kind: .image, modified: moment),
            entry("IMG_1.MOV", kind: .video, modified: moment.addingTimeInterval(0.4)),
        ]
        MediaTypeRules.markLivePhotoPairs(&entries)
        #expect(entries[0].subtype.contains(.livePhoto))
        #expect(entries[1].subtype.contains(.livePhotoCompanion))
    }

    @Test("A clip only joins a pair if it is the same moment")
    func pairingWindow() {
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        var entries = [
            entry("IMG_2.HEIC", kind: .image, modified: moment),
            entry("IMG_2.MOV", kind: .video, modified: moment.addingTimeInterval(45)),
        ]
        MediaTypeRules.markLivePhotoPairs(&entries)
        #expect(entries[1].subtype.contains(.livePhotoCompanion) == false)
        #expect(entries[0].subtype.contains(.livePhoto) == false)
    }

    @Test("An unrelated clip next to a photo stays a clip")
    func noSharedStem() {
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        var entries = [
            entry("IMG_3.HEIC", kind: .image, modified: moment),
            entry("VID_9.MOV", kind: .video, modified: moment),
        ]
        MediaTypeRules.markLivePhotoPairs(&entries)
        #expect(entries[1].subtype.isEmpty)
    }

    @Test("The stem is the pair key, whatever the case of either extension")
    func stems() {
        #expect(MediaTypeRules.stem("IMG_1234.HEIC") == "img_1234")
        #expect(MediaTypeRules.stem("IMG_1234.mov") == "img_1234")
        #expect(MediaTypeRules.stem("noextension") == "noextension")
        #expect(MediaTypeRules.stem("a.b.c.jpeg") == "a.b.c")
    }

    /// An entry as the walker produces one: `name` is the whole file name, extension included.
    private func entry(_ name: String, kind: MediaKind, modified: Date) -> ScannedEntry {
        ScannedEntry(
            relativePath: name, parentDirectory: "", name: name,
            fileExtension: (name as NSString).pathExtension,
            documentID: nil, resourceID: nil, byteSize: 1024,
            modificationDate: modified, creationDate: modified,
            kind: kind, uniformTypeIdentifier: kind == .image ? "public.heic" : "com.apple.quicktime-movie"
        )
    }
}
