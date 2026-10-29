import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GalleryImaging

@Test func aFlatTransparentSquareProfilesAsAGraphic() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("profile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("icon.png")

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = try #require(CGContext(
        data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.clear(CGRect(x: 0, y: 0, width: 128, height: 128))
    context.setFillColor(CGColor(srgbRed: 0.1, green: 0.4, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 32, y: 32, width: 64, height: 64))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))

    let features = try #require(PixelProfile.sample(url: url))
    #expect(features.hasAlpha)
    #expect(features.transparentRatio > 0.5)
    #expect(features.colorCount <= 8)
    #expect(features.flatRatio > 0.9)
}

@Test func aNoisyImageHasManyColoursAndHardEdges() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("profile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("noise.png")

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let size = 128
    let context = try #require(CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> UInt8 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8(truncatingIfNeeded: seed >> 33)
    }
    for y in stride(from: 0, to: size, by: 4) {
        for x in stride(from: 0, to: size, by: 4) {
            context.setFillColor(CGColor(
                srgbRed: Double(next()) / 255, green: Double(next()) / 255,
                blue: Double(next()) / 255, alpha: 1
            ))
            context.fill(CGRect(x: x, y: y, width: 4, height: 4))
        }
    }
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))

    let features = try #require(PixelProfile.sample(url: url))
    #expect(!features.hasAlpha)
    #expect(features.colorCount > 100)
    #expect(features.flatRatio < 0.5)
    #expect(features.edgeRatio > 0.1)
}

