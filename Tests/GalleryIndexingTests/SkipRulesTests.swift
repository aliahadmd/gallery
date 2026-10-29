import Testing
import Foundation
@testable import GalleryIndexing

/// The skip rules are the difference between "a gallery of my photos" and "40,000 rows of somebody
/// else's cache", so each rule gets its own case — including the ones that must *not* fire.
@Suite("What the walk refuses to enter")
struct SkipRulesTests {
    let rules = SkipRules.default

    @Test("A bundle is not a folder of photos, by flag or by name")
    func packages() {
        #expect(rules.reasonToSkipDirectory(name: "Raw Files", pathExtension: "", isPackage: false,
                                           isSymbolicLink: false, isAlias: false, depth: 1) == nil)
        #expect(rules.reasonToSkipDirectory(name: "Photos Library.photoslibrary",
                                            pathExtension: "photoslibrary", isPackage: false,
                                            isSymbolicLink: false, isAlias: false, depth: 1) == .package,
                "LaunchServices has not looked inside yet, so the name has to be enough")
        #expect(rules.reasonToSkipDirectory(name: "Whatever", pathExtension: "", isPackage: true,
                                           isSymbolicLink: false, isAlias: false, depth: 1) == .package)
    }

    @Test("A symlinked folder would be walked twice")
    func links() {
        #expect(rules.reasonToSkipDirectory(name: "Archive", pathExtension: "", isPackage: false,
                                           isSymbolicLink: true, isAlias: false, depth: 1) == .symbolicLink)
        #expect(rules.reasonToSkipDirectory(name: "Archive", pathExtension: "", isPackage: false,
                                           isSymbolicLink: false, isAlias: true, depth: 1) == .symbolicLink)
    }

    @Test("System, recycle and VCS directories never hold a gallery")
    func namedDirectories() {
        for name in [".Trash", ".trash", "$RECYCLE.BIN", "node_modules", ".git", ".DocumentRevisions-V100",
                     "@eaDir", ".Spotlight-V100"] {
            #expect(rules.reasonToSkipDirectory(name: name, pathExtension: "", isPackage: false,
                                                isSymbolicLink: false, isAlias: false, depth: 1) == .excludedName,
                    "\(name) must never be entered")
        }
        // Any other dot-folder is nobody's album, but a normal one is.
        #expect(rules.reasonToSkipDirectory(name: ".cache2", pathExtension: "", isPackage: false,
                                           isSymbolicLink: false, isAlias: false, depth: 1) == .excludedName)
        #expect(rules.reasonToSkipDirectory(name: "Wedding", pathExtension: "", isPackage: false,
                                           isSymbolicLink: false, isAlias: false, depth: 1) == nil)
    }

    @Test("Depth is capped, and the cap is generous enough for DCIM")
    func depth() {
        let deep = SkipRules(maximumDepth: 3)
        #expect(deep.reasonToSkipDirectory(name: "Deeper", pathExtension: "", isPackage: false,
                                          isSymbolicLink: false, isAlias: false, depth: 4) == .depthLimit)
        #expect(rules.reasonToSkipDirectory(name: "102APPLE", pathExtension: "", isPackage: false,
                                           isSymbolicLink: false, isAlias: false, depth: 4) == nil)
    }

    @Test("Only photo and video extensions earn a row")
    func fileExtensions() {
        func skip(_ name: String, _ ext: String, size: Int64 = 512) -> SkipRule? {
            rules.reasonToSkipFile(name: name, fileExtension: ext, isHidden: false, isAlias: false,
                                   byteSize: size)
        }
        #expect(skip("IMG_1", "jpg") == nil)
        #expect(skip("IMG_1", "JPG") == nil, "an exFAT card shouts its extensions")
        #expect(skip("CLIP_1", "mov") == nil)
        #expect(skip("notes", "txt") == .notMedia)
        #expect(skip("archive", "zip") == .notMedia)
        #expect(skip("tool", "dmg") == .notMedia)
    }

    @Test("Dot-files are skipped until asked for, and .DS_Store always is")
    func hidden() {
        #expect(rules.reasonToSkipFile(name: ".secret.jpg", fileExtension: "jpg", isHidden: true,
                                      isAlias: false, byteSize: 512) == .hiddenFile)
        #expect(SkipRules(includesHiddenFiles: true)
            .reasonToSkipFile(name: ".secret.jpg", fileExtension: "jpg", isHidden: true,
                              isAlias: false, byteSize: 512) == nil)
        #expect(SkipRules(includesHiddenFiles: true)
            .reasonToSkipFile(name: ".DS_Store", fileExtension: "store", isHidden: true,
                              isAlias: false, byteSize: 512) == .excludedName)
    }

    @Test("A file too big to decode keeps its row and says why")
    func tooLarge() {
        let capped = SkipRules(maximumFileBytes: 1024)
        #expect(capped.reasonToSkipFile(name: "huge", fileExtension: "tif", isHidden: false,
                                       isAlias: false, byteSize: 4096) == .tooLarge)
        #expect(capped.reasonToSkipFile(name: "small", fileExtension: "tif", isHidden: false,
                                       isAlias: false, byteSize: 512) == nil)
    }

    @Test("An alias is a pointer, not a picture")
    func alias() {
        #expect(rules.reasonToSkipFile(name: "IMG_1.jpg", fileExtension: "jpg", isHidden: false,
                                      isAlias: true, byteSize: 512) == .aliasFile)
    }
}
