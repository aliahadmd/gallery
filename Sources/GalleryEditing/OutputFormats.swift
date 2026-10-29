import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Which containers this machine can actually write, probed once.
///
/// The picker offers only what the encoder can produce — WebP decodes here but does not encode, and a
/// user who chooses HEIC and receives a JPEG has been lied to, so there is no fallback anywhere below.
public enum OutputFormats {
    private static let writable: [OutputFormat.Kind: Bool] = {
        var table: [OutputFormat.Kind: Bool] = [:]
        for kind in OutputFormat.Kind.allCases {
            let probe = NSMutableData()
            table[kind] = CGImageDestinationCreateWithData(
                probe, utType(kind).identifier as CFString, 1, nil
            ) != nil
        }
        return table
    }()

    public static func isWritable(_ kind: OutputFormat.Kind) -> Bool {
        writable[kind] ?? false
    }

    public static var available: [OutputFormat.Kind] {
        OutputFormat.Kind.allCases.filter(isWritable)
    }

    public static func utType(_ kind: OutputFormat.Kind) -> UTType {
        switch kind {
        case .jpeg: .jpeg
        case .png: .png
        case .tiff: .tiff
        case .heic: .heic
        case .avif: UTType("public.avif") ?? .heic
        }
    }

    /// The output kind that matches a source file, or nil when the container is not one we can write.
    /// Used only for the identity shortcut, so an unknown container simply takes the render path.
    public static func kind(for url: URL) -> OutputFormat.Kind? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe": .jpeg
        case "png": .png
        case "tif", "tiff": .tiff
        case "heic", "heif": .heic
        case "avif": .avif
        default: nil
        }
    }
}
