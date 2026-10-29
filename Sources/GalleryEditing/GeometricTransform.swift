import CoreGraphics
import GalleryDomain

/// The affine math of the editor, in top-left pixel coordinates — the space the canvas authors in and the
/// space every crop rect is expressed in.
///
/// Core Graphics' own space is bottom-left, and a y-flip applied in the wrong place is exactly how a
/// rotated photo ships sideways. So the flip happens in exactly one function (`coreGraphics`) and the
/// composition used everywhere else is spelled out (`composed`), because the parameter order of
/// `CGAffineTransform.concatenating` is the second most common way to get this wrong.
public enum FrameTransform {
    public static let identity = CGAffineTransform.identity

    public static func translation(x: Double, y: Double) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }

    public static func scale(_ factor: Double) -> CGAffineTransform {
        CGAffineTransform(a: factor, b: 0, c: 0, d: factor, tx: 0, ty: 0)
    }

    public static func flipX(_ width: Double) -> CGAffineTransform {
        CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
    }

    public static func flipY(_ height: Double) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }

    /// A clockwise quarter turn of a `width × height` canvas: stored (0, 0) lands at the new top-right.
    public static func rotation90(width: Double, height: Double) -> CGAffineTransform {
        CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
    }

    /// `outer` applied after `inner`. Spelled out rather than using `concatenating`, whose order is the
    /// single easiest thing to get backwards in this file.
    public static func composed(
        _ inner: CGAffineTransform,
        _ outer: CGAffineTransform
    ) -> CGAffineTransform {
        CGAffineTransform(
            a: inner.a * outer.a + inner.b * outer.c,
            b: inner.a * outer.b + inner.b * outer.d,
            c: inner.c * outer.a + inner.d * outer.c,
            d: inner.c * outer.b + inner.d * outer.d,
            tx: inner.tx * outer.a + inner.ty * outer.c + outer.tx,
            ty: inner.tx * outer.b + inner.ty * outer.d + outer.ty
        )
    }

    public static func apply(_ transform: CGAffineTransform, _ point: CGPoint) -> CGPoint {
        CGPoint(
            x: transform.a * point.x + transform.c * point.y + transform.tx,
            y: transform.b * point.x + transform.d * point.y + transform.ty
        )
    }

    /// Stored pixels to display pixels for an EXIF orientation, as flips followed by quarter turns. The
    /// table is a convenience; the eight-orientation quadrant test is the authority.
    public static func orientation(_ value: Int16, width: Double, height: Double) -> CGAffineTransform {
        let exif: (flipH: Bool, flipV: Bool, turns: Int) = switch value {
        case 2: (true, false, 0)
        case 3: (false, false, 2)
        case 4: (false, true, 0)
        case 5: (false, true, 1)
        case 6: (false, false, 1)
        case 7: (true, false, 1)
        case 8: (false, false, 3)
        default: (false, false, 0)
        }
        var transform = CGAffineTransform.identity
        var w = width
        var h = height
        if exif.flipH { transform = composed(transform, flipX(w)) }
        if exif.flipV { transform = composed(transform, flipY(h)) }
        for _ in 0..<exif.turns {
            transform = composed(transform, rotation90(width: w, height: h))
            (w, h) = (h, w)
        }
        return transform
    }

    public static func displaySize(stored: PixelSize, orientation: Int16) -> PixelSize {
        switch orientation {
        case 5, 6, 7, 8: PixelSize(width: stored.height, height: stored.width)
        default: stored
        }
    }

    /// The transform to hand to `CGContext.concatenate` when drawing the source image into the output
    /// bitmap: source CG → output CG, with the y-flip at each end. The caller draws the image in the rect
    /// `(0, 0, stored.width, stored.height)`.
    public static func coreGraphics(
        sourceToOutput: CGAffineTransform,
        storedHeight: Double,
        outputHeight: Double
    ) -> CGAffineTransform {
        composed(composed(flipY(storedHeight), sourceToOutput), flipY(outputHeight))
    }
}
