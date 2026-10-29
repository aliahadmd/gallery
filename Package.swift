// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Gallery",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Gallery", targets: ["GalleryApp"])
    ],
    targets: [
        .target(name: "GalleryDomain"),
        .target(name: "GallerySupport", dependencies: ["GalleryDomain"]),
        .target(
            name: "GallerySQLite",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "GalleryCatalog",
            dependencies: ["GalleryDomain", "GallerySQLite"]
        ),
        .target(
            name: "GalleryImaging",
            dependencies: ["GalleryDomain", "GallerySupport"]
        ),
        .target(
            name: "GalleryIndexing",
            dependencies: ["GalleryDomain", "GallerySupport", "GalleryCatalog", "GalleryImaging"]
        ),
        .target(
            name: "GalleryUI",
            dependencies: ["GalleryDomain", "GallerySupport", "GalleryCatalog", "GalleryIndexing"]
        ),
        .executableTarget(
            name: "GalleryApp",
            dependencies: ["GalleryDomain", "GallerySupport", "GallerySQLite", "GalleryCatalog",
                           "GalleryImaging", "GalleryIndexing", "GalleryUI"],
            path: "App",
            exclude: ["Info.plist", "Gallery.entitlements"]
        ),
        .testTarget(name: "GallerySQLiteTests", dependencies: ["GallerySQLite"]),
        .testTarget(name: "GallerySupportTests", dependencies: ["GallerySupport"]),
        .testTarget(
            name: "GalleryCatalogTests",
            dependencies: ["GalleryCatalog", "GalleryDomain"]
        ),
        .testTarget(
            name: "GalleryImagingTests",
            dependencies: ["GalleryImaging", "GalleryDomain"]
        ),
        .testTarget(
            name: "GalleryIndexingTests",
            dependencies: ["GalleryIndexing", "GalleryCatalog", "GalleryDomain", "GalleryImaging",
                           "GallerySupport"]
        ),
        .testTarget(
            name: "GalleryUITests",
            dependencies: ["GalleryUI", "GalleryIndexing", "GalleryImaging", "GalleryCatalog",
                           "GalleryDomain", "GallerySupport"]
        )
    ]
)
