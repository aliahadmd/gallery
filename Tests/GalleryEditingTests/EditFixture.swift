import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import GalleryEditing

/// Real files with four flat-coloured quadrants, so an orientation or crop bug shows up as the wrong
/// colour at a known corner rather than as a picture that merely looks odd.
enum EditFixture {
    static let topLeft = RGBAColor(red: 0.90, green: 0.10, blue: 0.10)
    static let topRight = RGBAColor(red: 0.10, green: 0.75, blue: 0.15)
    static let bottomLeft = RGBAColor(red: 0.10, green: 0.20, blue: 0.85)
    static let bottomRight = RGBAColor(red: 0.95, green: 0.85, blue: 0.10)

    static func quadrantImage(width: Int = 400, height: Int = 300) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        let w = CGFloat(width), h = CGFloat(height)
        // Core Graphics space: bottom-left origin. Top-left quadrant is the upper half.
        context.setFillColor(ImageDraw.cgColor(topLeft))
        context.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
        context.setFillColor(ImageDraw.cgColor(topRight))
        context.fill(CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))
        context.setFillColor(ImageDraw.cgColor(bottomLeft))
        context.fill(CGRect(x: 0, y: 0, width: w / 2, height: h / 2))
        context.setFillColor(ImageDraw.cgColor(bottomRight))
        context.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))
        return context.makeImage()
    }

    @discardableResult
    static func write(
        _ image: CGImage,
        to url: URL,
        type: UTType = .jpeg,
        properties: [CFString: Any] = [:]
    ) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil
        ) else {
            return false
        }
        var merged = properties
        if type == .jpeg || type == .heic {
            merged[kCGImageDestinationLossyCompressionQuality] = 1.0
        }
        CGImageDestinationAddImage(destination, image, merged as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    static func color(_ image: CGImage, x: Int, y: Int) -> RGBAColor {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return .clear
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(
            x: CGFloat(-x), y: CGFloat(-(image.height - 1 - y)),
            width: CGFloat(image.width), height: CGFloat(image.height)
        ))
        return RGBAColor(
            red: Double(pixel[0]) / 255,
            green: Double(pixel[1]) / 255,
            blue: Double(pixel[2]) / 255
        )
    }

    static func sample(_ image: CGImage, _ fx: Double, _ fy: Double) -> RGBAColor {
        color(
            image,
            x: min(max(1, Int(Double(image.width) * fx)), image.width - 2),
            y: min(max(1, Int(Double(image.height) * fy)), image.height - 2)
        )
    }

    static func matches(_ lhs: RGBAColor, _ rhs: RGBAColor, tolerance: Double = 0.12) -> Bool {
        abs(lhs.red - rhs.red) <= tolerance
            && abs(lhs.green - rhs.green) <= tolerance
            && abs(lhs.blue - rhs.blue) <= tolerance
    }
}
