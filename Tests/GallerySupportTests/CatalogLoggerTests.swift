import Foundation
import Testing
@testable import GallerySupport

@Suite struct CatalogLoggerTests {
    @Test func allChannelsExistOnOneSubsystem() {
        #expect(!Log.subsystem.isEmpty)
        Log.indexing.debug("probe")
        Log.catalog.debug("probe")
        Log.imaging.debug("probe")
        Log.geo.debug("probe")
        Log.ui.debug("probe")
    }
}
