import SwiftUI
import AppKit
import GalleryEditing

/// The eight grips of a crop rectangle; edges move one side, corners move two.
enum CropHandle: CaseIterable {
    case topLeft, top, topRight, leading, trailing, bottomLeft, bottom, bottomRight

    var movesLeft: Bool { self == .topLeft || self == .leading || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .trailing || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }
}

/// Pure crop math in normalized coordinates, kept out of the view so the drags are a one-line call.
enum CropGeometry {
    static func moved(_ crop: CropRect, dx: Double, dy: Double) -> CropRect {
        CropRect(
            x: min(max(0, crop.x + dx), 1 - crop.width),
            y: min(max(0, crop.y + dy), 1 - crop.height),
            width: crop.width,
            height: crop.height
        )
    }

    /// `aspect` is normalized width/height — the locked pixel ratio divided by the picture's own pixel
    /// aspect — so a 1:1 lock produces a square in pixels even on a panoramic source.
    static func resized(
        _ crop: CropRect, handle: CropHandle, dx: Double, dy: Double, aspect: Double?
    ) -> CropRect {
        let minimum = 0.02
        var left = crop.x
        var top = crop.y
        var right = crop.x + crop.width
        var bottom = crop.y + crop.height

        if handle.movesLeft { left = min(max(0, left + dx), right - minimum) }
        if handle.movesRight { right = max(min(1, right + dx), left + minimum) }
        if handle.movesTop { top = min(max(0, top + dy), bottom - minimum) }
        if handle.movesBottom { bottom = max(min(1, bottom + dy), top + minimum) }

        guard let aspect, aspect > 0 else {
            return CropRect(x: left, y: top, width: right - left, height: bottom - top)
        }

        if handle.isCorner {
            let anchorX = handle.movesLeft ? right : left
            let anchorY = handle.movesTop ? bottom : top
            var width = right - left
            var height = bottom - top
            if width / max(height, 1e-9) > aspect {
                height = width / aspect
            } else {
                width = height * aspect
            }
            let maxWidth = handle.movesLeft ? anchorX : 1 - anchorX
            let maxHeight = handle.movesTop ? anchorY : 1 - anchorY
            let fit = min(1, min(maxWidth / max(width, 1e-9), maxHeight / max(height, 1e-9)))
            width = max(minimum, width * fit)
            height = max(minimum, height * fit)
            return CropRect(
                x: max(0, handle.movesLeft ? anchorX - width : anchorX),
                y: max(0, handle.movesTop ? anchorY - height : anchorY),
                width: width,
                height: height
            ).clamped()
        }

        // An edge drag keeps the opposite edge and grows the other dimension about the centre.
        let centreX = (left + right) / 2
        let centreY = (top + bottom) / 2
        if handle.movesLeft || handle.movesRight {
            var width = right - left
            var height = width / aspect
            let limit = 2 * min(centreY, 1 - centreY)
            if height > limit {
                height = limit
                width = height * aspect
                if handle.movesLeft { left = right - width } else { right = left + width }
            }
            top = centreY - height / 2
            bottom = centreY + height / 2
        } else {
            var width = (right - left) / aspect
            var height = bottom - top
            let limit = 2 * min(centreX, 1 - centreX)
            if width > limit {
                width = limit
                height = width / aspect
            }
            left = centreX - width / 2
            right = centreX + width / 2
            top = centreY - height / 2
            bottom = centreY + height / 2
        }
        return CropRect(x: left, y: top, width: max(minimum, right - left),
                        height: max(minimum, bottom - top)).clamped()
    }
}

struct EditorCanvas: View {
    let session: EditingSession

    var body: some View {
        GeometryReader { proxy in
            let imageRect = fittedRect(in: proxy.size)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                if session.preview != nil {
                    if session.tool == .crop {
                        CropOverlay(session: session, imageSize: imageRect.size)
                            .position(x: imageRect.midX, y: imageRect.midY)
                    } else {
                        previewImage
                            .frame(width: imageRect.width, height: imageRect.height)
                            .position(x: imageRect.midX, y: imageRect.midY)
                    }
                    if session.isRendering {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                            .background(.regularMaterial, in: Circle())
                            .position(x: imageRect.maxX - 20, y: imageRect.minY + 20)
                    }
                } else if session.isRendering {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo").font(.system(size: 30, weight: .thin))
                        Text("This photo could not be rendered.").font(.callout)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(24)
    }

    @ViewBuilder private var previewImage: some View {
        if let preview = session.preview {
            Image(decorative: preview, scale: 1)
                .resizable()
                .interpolation(.high)
        }
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let aspect: Double
        if let preview = session.preview, preview.height > 0 {
            aspect = Double(preview.width) / Double(preview.height)
        } else {
            aspect = session.displayPixelAspect
        }
        var width = max(1, size.width)
        var height = width / max(aspect, 1e-6)
        if height > size.height {
            height = max(1, size.height)
            width = height * aspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }
}

private struct CropOverlay: View {
    let session: EditingSession
    let imageSize: CGSize

    @State private var dragOrigin: CropRect?

    private var crop: CropRect { session.recipe.crop }
    private var cropRect: CGRect {
        CGRect(x: crop.x * imageSize.width, y: crop.y * imageSize.height,
               width: crop.width * imageSize.width, height: crop.height * imageSize.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let preview = session.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: imageSize.width, height: imageSize.height)
            }

            Path { path in
                path.addRect(CGRect(origin: .zero, size: imageSize))
                path.addRect(cropRect)
            }
            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            thirds
            CropBorder(rect: cropRect)
            moveTarget
            ForEach(CropHandle.allCases, id: \.self) { handle in
                handleView(handle)
            }
        }
        .frame(width: imageSize.width, height: imageSize.height)
        .clipped()
    }

    private var thirds: some View {
        Path { path in
            for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                let x = cropRect.minX + cropRect.width * fraction
                path.move(to: CGPoint(x: x, y: cropRect.minY))
                path.addLine(to: CGPoint(x: x, y: cropRect.maxY))
                let y = cropRect.minY + cropRect.height * fraction
                path.move(to: CGPoint(x: cropRect.minX, y: y))
                path.addLine(to: CGPoint(x: cropRect.maxX, y: y))
            }
        }
        .stroke(.white.opacity(0.35), lineWidth: 0.75)
        .allowsHitTesting(false)
    }

    private var moveTarget: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .frame(width: max(0, cropRect.width - 20), height: max(0, cropRect.height - 20))
            .position(x: cropRect.midX, y: cropRect.midY)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        beginIfNeeded()
                        guard let origin = dragOrigin else { return }
                        session.updateCropDrag(CropGeometry.moved(
                            origin,
                            dx: value.translation.width / imageSize.width,
                            dy: value.translation.height / imageSize.height
                        ))
                    }
                    .onEnded { _ in finishDrag() }
            )
    }

    private func handleView(_ handle: CropHandle) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 0.5))
            .frame(width: 10, height: 10)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .position(point(for: handle))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        beginIfNeeded()
                        guard let origin = dragOrigin else { return }
                        let pixelAspect = session.cropAspect.ratio(
                            displayAspect: session.displayPixelAspect
                        )
                        let normalized = pixelAspect.map { $0 / session.displayPixelAspect }
                        session.updateCropDrag(CropGeometry.resized(
                            origin, handle: handle,
                            dx: value.translation.width / imageSize.width,
                            dy: value.translation.height / imageSize.height,
                            aspect: normalized
                        ))
                    }
                    .onEnded { _ in finishDrag() }
            )
    }

    private func beginIfNeeded() {
        guard dragOrigin == nil else { return }
        dragOrigin = session.recipe.crop
        session.beginCropDrag()
    }

    private func finishDrag() {
        dragOrigin = nil
        session.endCropDrag()
    }

    private func point(for handle: CropHandle) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: cropRect.minX, y: cropRect.minY)
        case .top: CGPoint(x: cropRect.midX, y: cropRect.minY)
        case .topRight: CGPoint(x: cropRect.maxX, y: cropRect.minY)
        case .leading: CGPoint(x: cropRect.minX, y: cropRect.midY)
        case .trailing: CGPoint(x: cropRect.maxX, y: cropRect.midY)
        case .bottomLeft: CGPoint(x: cropRect.minX, y: cropRect.maxY)
        case .bottom: CGPoint(x: cropRect.midX, y: cropRect.maxY)
        case .bottomRight: CGPoint(x: cropRect.maxX, y: cropRect.maxY)
        }
    }
}

private struct CropBorder: View {
    let rect: CGRect

    var body: some View {
        Rectangle()
            .strokeBorder(.white, lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }
}
