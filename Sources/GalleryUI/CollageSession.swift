import CoreGraphics
import Foundation
import Observation
import GalleryDomain
import GalleryEditing
import GalleryIndexing

/// The collage editor's state: a document, its members, and a preview.
///
/// The document is a pure `Codable` value and the renderer is pure geometry over it, so every control is a
/// value change followed by a debounced render — there is no layout state to keep in sync.
@MainActor
@Observable
public final class CollageSession {
    public private(set) var document: CollageDocument
    public private(set) var preview: CGImage?
    public private(set) var isRendering = false
    public let members: [MediaID: EditSource]
    public let sourceLongSides: [MediaID: Int]

    private let service: EditService
    private var renderTask: Task<Void, Never>?
    private static let previewLongSide = 1_400

    public init(
        document: CollageDocument,
        members: [MediaID: EditSource],
        sourceLongSides: [MediaID: Int],
        service: EditService
    ) {
        self.document = document
        self.members = members
        self.sourceLongSides = sourceLongSides
        self.service = service
    }

    public var layout: CollageLayout {
        CollageLayoutEngine.layout(document, sourceLongSides: sourceLongSides)
    }

    public var memberCount: Int { document.memberIDs.count }
    public var outputSize: PixelSize { layout.canvas }
    public var upscaleFactor: Double { layout.upscaleFactor }

    public func renderPreview() async {
        isRendering = true
        let image = await service.collagePreview(
            document,
            members: members,
            sourceLongSides: sourceLongSides,
            previewLongSide: Self.previewLongSide
        )
        preview = image
        isRendering = false
    }

    private func schedulePreview() {
        renderTask?.cancel()
        let document = document
        let members = members
        let sizes = sourceLongSides
        let service = service
        isRendering = true
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let image = await service.collagePreview(
                document, members: members, sourceLongSides: sizes,
                previewLongSide: Self.previewLongSide
            )
            guard !Task.isCancelled, let self, self.document == document else { return }
            self.preview = image
            self.isRendering = false
        }
    }

    public func cancel() {
        renderTask?.cancel()
        renderTask = nil
    }

    // MARK: - Controls

    public func setTemplate(_ template: CollageTemplate) {
        guard template != document.template else { return }
        document.template = template
        schedulePreview()
    }

    public func setAspect(_ aspect: CollageAspect) {
        guard aspect != document.aspect else { return }
        document.aspect = aspect
        schedulePreview()
    }

    public func setLongSide(_ value: Int) {
        let clamped = min(max(value, 800), 8192)
        guard clamped != document.longSide else { return }
        document.longSide = clamped
        schedulePreview()
    }

    public func setGutter(_ fraction: Double) {
        document.gutterFraction = min(max(fraction, 0), 0.05)
        schedulePreview()
    }

    public func setMargin(_ fraction: Double) {
        document.marginFraction = min(max(fraction, 0), 0.1)
        schedulePreview()
    }

    public func setTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? nil : title
        guard value != document.title else { return }
        document.title = value
        schedulePreview()
    }

    public func setFormat(_ kind: OutputFormat.Kind) {
        guard OutputFormats.isWritable(kind), kind != document.format.kind else { return }
        document.format.kind = kind
        schedulePreview()
    }

    public func setBackground(_ color: RGBAColor) {
        guard color != document.background else { return }
        document.background = color
        schedulePreview()
    }
}
