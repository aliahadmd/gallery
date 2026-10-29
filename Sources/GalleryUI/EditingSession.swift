import CoreGraphics
import Foundation
import Observation
import GalleryDomain
import GalleryEditing
import GalleryIndexing

public enum EditorTool: String, CaseIterable, Sendable {
    case crop
    case size
    case format
    case mark
    case metadata

    public var title: String {
        switch self {
        case .crop: "Crop"
        case .size: "Size"
        case .format: "Format"
        case .mark: "Mark"
        case .metadata: "Metadata"
        }
    }

    public var symbol: String {
        switch self {
        case .crop: "crop"
        case .size: "arrow.up.left.and.arrow.down.right"
        case .format: "doc.badge.gearshape"
        case .mark: "textformat"
        case .metadata: "info.circle"
        }
    }
}

public enum CropAspect: String, CaseIterable, Sendable, Hashable {
    case original
    case square
    case portrait4x5
    case landscape3x2
    case wide16x9
    case free

    public var title: String {
        switch self {
        case .original: "Original"
        case .square: "1:1"
        case .portrait4x5: "4:5"
        case .landscape3x2: "3:2"
        case .wide16x9: "16:9"
        case .free: "Free"
        }
    }

    /// Pixel width / height, or nil for a free crop.
    public func ratio(displayAspect: Double) -> Double? {
        switch self {
        case .original: displayAspect
        case .square: 1
        case .portrait4x5: 4.0 / 5.0
        case .landscape3x2: 3.0 / 2.0
        case .wide16x9: 16.0 / 9.0
        case .free: nil
        }
    }
}

/// The editor's state for one photo: the recipe (a pure value), the undo stack of recipes, and the preview
/// the canvas draws.
///
/// Preview renders are debounced and latest-wins. A crop drag does not re-render at all — the scrim already
/// shows the result — and pushes one undo step when the drag ends, so ⌘Z undoes a gesture rather than a
/// pixel of mouse travel.
@MainActor
@Observable
public final class EditingSession {
    public let source: EditSource
    public let storedSize: PixelSize
    public let orientation: Int16
    public private(set) var recipe: EditRecipe
    public private(set) var preview: CGImage?
    public private(set) var isRendering = false
    public private(set) var tool: EditorTool = .crop
    public private(set) var cropAspect: CropAspect = .free
    public private(set) var undoStack: [EditRecipe] = []
    /// What the file carries now, for the metadata form.
    public private(set) var fileMetadata: ExistingMetadata = .none
    /// When the newest restorable backup was made, if there is one.
    public private(set) var backupDate: Date?

    private let service: EditService
    private var previewTask: Task<Void, Never>?
    private var interactionStart: EditRecipe?
    private static let maxPreviewLongSide = 1_600
    private static let maxUndo = 20

    public init(
        source: EditSource,
        storedSize: PixelSize,
        orientation: Int16,
        service: EditService,
        recipe: EditRecipe = EditRecipe()
    ) {
        self.source = source
        self.storedSize = storedSize
        self.orientation = orientation
        self.service = service
        self.recipe = recipe
    }

    // MARK: - Derived state

    public var plan: EditPlan? {
        EditPlanBuilder.plan(recipe, stored: storedSize, orientation: orientation)
    }

    public var outputSize: PixelSize? { plan?.output }
    public var wasClamped: Bool { plan?.wasClamped ?? false }
    public var displayPixelAspect: Double {
        let display = FrameTransform.displaySize(stored: storedSize, orientation: orientation)
        return display.height == 0 ? 1 : Double(display.width) / Double(display.height)
    }

    public var sourceKind: OutputFormat.Kind? { OutputFormats.kind(for: source.url) }

    /// True when exporting would be a byte copy: nothing to render, nothing to lose.
    public var isIdentity: Bool {
        guard let sourceKind else { return false }
        return recipe.isIdentity(for: sourceKind)
    }

    public var canUndo: Bool { !undoStack.isEmpty }

    /// Replace Original writes over the file, so it is offered only when the output is the same container.
    public var isReplaceEligible: Bool {
        source.kind == .image && sourceKind != nil && sourceKind == recipe.format.kind
    }

    public var statusText: String {
        guard let plan else { return "This size is too large." }
        let size = "\(plan.output.width) × \(plan.output.height)"
        let clamped = plan.wasClamped ? " · no enlargement" : ""
        return "\(size) · \(plan.format.kind.rawValue.uppercased())\(clamped)"
    }

    // MARK: - Preview

    /// The crop tool shows the whole picture under the scrim, so the preview deliberately renders with a
    /// full crop; every other tool shows the result.
    private var previewRecipe: EditRecipe {
        guard tool == .crop else { return recipe }
        var full = recipe
        full.crop = .full
        return full
    }

    public func loadPreview() async {
        isRendering = true
        let image = await service.preview(
            for: source, recipe: previewRecipe, maxLongSide: Self.maxPreviewLongSide
        )
        preview = image
        isRendering = false
        await reloadFileMetadata()
    }

    public func reloadFileMetadata() async {
        fileMetadata = await service.metadata(for: source)
        backupDate = await service.backupDate(for: source.mediaID)
    }

    public func setTool(_ tool: EditorTool) {
        guard tool != self.tool else { return }
        self.tool = tool
        schedulePreview()
    }

    private func schedulePreview() {
        previewTask?.cancel()
        let source = source
        let recipe = previewRecipe
        let service = service
        isRendering = true
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            let image = await service.preview(
                for: source, recipe: recipe, maxLongSide: Self.maxPreviewLongSide
            )
            guard !Task.isCancelled, let self, self.previewRecipe == recipe else { return }
            self.preview = image
            self.isRendering = false
        }
    }

    public func cancel() {
        previewTask?.cancel()
        previewTask = nil
    }

    // MARK: - Recipe edits

    private func pushUndo(_ value: EditRecipe) {
        undoStack.append(value)
        if undoStack.count > Self.maxUndo {
            undoStack.removeFirst(undoStack.count - Self.maxUndo)
        }
    }

    public func setRecipe(_ next: EditRecipe) {
        guard next != recipe else { return }
        pushUndo(recipe)
        recipe = next
        schedulePreview()
    }

    public func update(_ transform: (inout EditRecipe) -> Void) {
        var next = recipe
        transform(&next)
        setRecipe(next)
    }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        recipe = previous
        schedulePreview()
    }

    public func reset() {
        var fresh = EditRecipe()
        fresh.format = recipe.format
        setRecipe(fresh)
    }

    /// A quarter turn also turns the live crop, so the pixels the user selected stay selected.
    public func rotate(clockwise: Bool) {
        update { recipe in
            let turns = clockwise ? 1 : 3
            recipe.quarterTurns = (recipe.quarterTurns + turns) % 4
            recipe.crop = recipe.crop.rotated(quarterTurns: turns)
        }
    }

    public func flip(horizontal: Bool) {
        update { recipe in
            if horizontal { recipe.flipHorizontal.toggle() } else { recipe.flipVertical.toggle() }
            recipe.crop = recipe.crop.flipped(horizontal: horizontal, vertical: !horizontal)
        }
    }

    public func setResize(_ rule: ResizeRule) {
        update { $0.resize = rule }
    }

    public func setFormat(_ kind: OutputFormat.Kind) {
        guard OutputFormats.isWritable(kind), kind != recipe.format.kind else { return }
        update { $0.format.kind = kind }
    }

    public func setQuality(_ quality: Double) {
        update { $0.format.quality = min(max(quality, 0.1), 1) }
    }

    public func setCropAspect(_ aspect: CropAspect) {
        cropAspect = aspect
        guard let ratio = aspect.ratio(displayAspect: displayPixelAspect) else { return }
        let normalized = ratio / displayPixelAspect
        var crop = recipe.crop
        var width = crop.width
        var height = width / normalized
        if height > 1 {
            height = 1
            width = height * normalized
        }
        if width > 1 {
            width = 1
            height = width / normalized
        }
        crop = CropRect(
            x: crop.x + (crop.width - width) / 2,
            y: crop.y + (crop.height - height) / 2,
            width: width,
            height: height
        ).clamped()
        setRecipe(with: crop, preservingAspect: true)
    }

    /// A crop drag: no preview while the finger is down, one undo step on release.
    public func beginCropDrag() {
        interactionStart = recipe
    }

    /// Text fields and sliders use the same rule: one undo step for the whole gesture, not one per keystroke.
    public func beginInteraction() {
        guard interactionStart == nil else { return }
        interactionStart = recipe
    }

    public func endInteraction() {
        guard let start = interactionStart else { return }
        interactionStart = nil
        guard start != recipe else { return }
        pushUndo(start)
        schedulePreview()
    }

    // MARK: - Text and watermark

    public var overlay: TextOverlay? { recipe.overlays.first }
    public var hasOverlay: Bool { !recipe.overlays.isEmpty }

    /// Changes the overlay's text. No undo push: the panel brackets the whole typing session with
    /// `beginInteraction`/`endInteraction`.
    public func setOverlayText(_ text: String) {
        var overlays = recipe.overlays
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard !overlays.isEmpty else { return }
            overlays.removeAll()
        } else if var first = overlays.first {
            first.text = text
            overlays[0] = first
        } else {
            overlays = [TextOverlay(kind: .caption, text: text)]
        }
        recipe.overlays = overlays
        schedulePreview()
    }

    public func setOverlayPlacement(_ placement: OverlayPlacement, kind: TextOverlay.Kind) {
        guard var first = recipe.overlays.first else { return }
        first.placement = placement
        first.kind = kind
        if kind == .watermark, first.opacity > 0.6 { first.opacity = 0.35 }
        update { $0.overlays = [first] }
    }

    public func setOverlaySize(_ fraction: Double) {
        guard var first = recipe.overlays.first else { return }
        first.sizeFraction = min(max(fraction, 0.01), 0.25)
        update { $0.overlays = [first] }
    }

    public func setOverlayOpacity(_ opacity: Double) {
        guard var first = recipe.overlays.first else { return }
        first.opacity = min(max(opacity, 0.05), 1)
        update { $0.overlays = [first] }
    }

    public func setOverlayColor(_ color: RGBAColor) {
        guard var first = recipe.overlays.first else { return }
        first.color = color
        update { $0.overlays = [first] }
    }

    public func setOverlayShadow(_ shadow: Bool) {
        guard var first = recipe.overlays.first else { return }
        first.shadow = shadow
        update { $0.overlays = [first] }
    }

    public func clearOverlay() {
        guard !recipe.overlays.isEmpty else { return }
        update { $0.overlays = [] }
    }

    public func updateCropDrag(_ rect: CropRect) {
        recipe.crop = rect.clamped()
    }

    public func endCropDrag() {
        guard let start = interactionStart else { return }
        interactionStart = nil
        guard start != recipe else { return }
        pushUndo(start)
        schedulePreview()
    }

    public func setCrop(_ rect: CropRect) {
        setRecipe(with: rect.clamped(), preservingAspect: false)
    }

    private func setRecipe(with crop: CropRect, preservingAspect: Bool) {
        var next = recipe
        next.crop = crop
        // A one-off crop from the sidebar resets the lock to free unless the lock is what produced it.
        if !preservingAspect { cropAspect = .free }
        setRecipe(next)
    }
}
