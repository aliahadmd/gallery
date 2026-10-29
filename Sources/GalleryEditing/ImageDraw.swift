import CoreGraphics
import Foundation

/// Drawing helpers shared by the renderer and the collage composer, in the context's own user space.
public enum ImageDraw {
    /// Aspect-fill into `frame`, clipping what falls outside it.
    public static func aspectFill(_ image: CGImage, in frame: CGRect, context: CGContext) {
        guard frame.width > 0, frame.height > 0, image.width > 0, image.height > 0 else { return }
        let scale = max(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let rect = CGRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        context.saveGState()
        context.clip(to: frame)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.restoreGState()
    }

    /// Aspect-fit into `frame`, centred, leaving the frame's background visible.
    public static func aspectFit(_ image: CGImage, in frame: CGRect, context: CGContext) {
        guard frame.width > 0, frame.height > 0, image.width > 0, image.height > 0 else { return }
        let scale = min(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let rect = CGRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.restoreGState()
    }

    public static func fill(_ frame: CGRect, with color: RGBAColor, in context: CGContext) {
        context.saveGState()
        context.setFillColor(cgColor(color))
        context.fill(frame)
        context.restoreGState()
    }

    public static func cgColor(_ color: RGBAColor) -> CGColor {
        CGColor(
            srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha
        )
    }
}
