import SwiftUI
import GalleryDomain
import GalleryEditing

/// The editor's right column: one tool at a time, and a footer that always says what will be written.
struct EditorSidebar: View {
    let session: EditingSession
    let applyMetadata: (@MainActor (MetadataOverrides) async -> Bool)?

    @State private var titleText = ""
    @State private var hasDate = false
    @State private var captureDate = Date()
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var isSaving = false

    init(
        session: EditingSession,
        applyMetadata: (@MainActor (MetadataOverrides) async -> Bool)? = nil
    ) {
        self.session = session
        self.applyMetadata = applyMetadata
    }

    private enum SizeMode: Hashable {
        case original
        case longSide
        case exact
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Tool", selection: toolBinding) {
                    ForEach(EditorTool.allCases, id: \.self) { tool in
                        Label(tool.title, systemImage: tool.symbol).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch session.tool {
                case .crop: cropPanel
                case .size: sizePanel
                case .format: formatPanel
                case .mark: markPanel
                case .metadata: metadataPanel
                }

                Divider()
                status
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.bar)
    }

    private var toolBinding: Binding<EditorTool> {
        Binding(get: { session.tool }, set: { session.setTool($0) })
    }

    // MARK: - Crop

    private var cropPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { session.rotate(clockwise: false) } label: {
                    Image(systemName: "rotate.left")
                }
                .help("Rotate left (←)")
                Button { session.rotate(clockwise: true) } label: {
                    Image(systemName: "rotate.right")
                }
                .help("Rotate right (→)")
                Button { session.flip(horizontal: true) } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Flip horizontally")
                Button { session.flip(horizontal: false) } label: {
                    Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
                .help("Flip vertically")
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 4) {
                Text("Aspect").font(.caption).foregroundStyle(.secondary)
                Picker("Aspect", selection: aspectBinding) {
                    ForEach(CropAspect.allCases, id: \.self) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            Button("Reset Crop") { session.setCrop(.full) }
                .controlSize(.small)
                .disabled(session.recipe.crop.isFull)
        }
    }

    private var aspectBinding: Binding<CropAspect> {
        Binding(get: { session.cropAspect }, set: { session.setCropAspect($0) })
    }

    // MARK: - Size

    private var sizePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Size", selection: sizeModeBinding) {
                Text("Original").tag(SizeMode.original)
                Text("Long Side").tag(SizeMode.longSide)
                Text("Exact").tag(SizeMode.exact)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch session.recipe.resize {
            case .original:
                Text("Keeping the photo's own resolution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .longSide:
                HStack(spacing: 6) {
                    Text("Long side").font(.callout)
                    TextField("", value: longSideBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 74)
                    Text("px").font(.callout).foregroundStyle(.secondary)
                }
            case .exact(let width, let height, let fit, let allow):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        TextField("", value: exactWidthBinding(width, height, fit, allow), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                        Text("×").foregroundStyle(.secondary)
                        TextField("", value: exactHeightBinding(width, height, fit, allow), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                        Text("px").font(.callout).foregroundStyle(.secondary)
                    }
                    Picker("Fit", selection: fitBinding(width, height, allow)) {
                        Text("Fit (pad)").tag(ResizeRule.FitMode.fit)
                        Text("Fill (crop)").tag(ResizeRule.FitMode.fill)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Toggle("Allow enlargement", isOn: upscaleBinding(width, height, fit))
                        .toggleStyle(.checkbox)
                        .font(.callout)
                }
            }

            if session.wasClamped {
                Label("The photo is smaller than this size; it will not be enlarged.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var sizeModeBinding: Binding<SizeMode> {
        Binding(
            get: {
                switch session.recipe.resize {
                case .original: .original
                case .longSide: .longSide
                case .exact: .exact
                }
            },
            set: { mode in
                let output = session.outputSize
                switch mode {
                case .original:
                    session.setResize(.original)
                case .longSide:
                    session.setResize(.longSide(Int(max(16, output?.longSide ?? 1600))))
                case .exact:
                    session.setResize(.exact(
                        width: Int(output?.width ?? 1600),
                        height: Int(output?.height ?? 1200),
                        fit: .fit,
                        allowUpscale: false
                    ))
                }
            }
        )
    }

    private var longSideBinding: Binding<Int> {
        Binding(
            get: {
                if case .longSide(let value) = session.recipe.resize { return value }
                return Int(session.outputSize?.longSide ?? 1600)
            },
            set: { session.setResize(.longSide(min(max($0, 16), 20_000))) }
        )
    }

    private func exactWidthBinding(
        _ width: Int, _ height: Int, _ fit: ResizeRule.FitMode, _ allow: Bool
    ) -> Binding<Int> {
        Binding(
            get: { width },
            set: {
                session.setResize(.exact(width: min(max($0, 1), 20_000), height: height,
                                         fit: fit, allowUpscale: allow))
            }
        )
    }

    private func exactHeightBinding(
        _ width: Int, _ height: Int, _ fit: ResizeRule.FitMode, _ allow: Bool
    ) -> Binding<Int> {
        Binding(
            get: { height },
            set: {
                session.setResize(.exact(width: width, height: min(max($0, 1), 20_000),
                                         fit: fit, allowUpscale: allow))
            }
        )
    }

    private func fitBinding(
        _ width: Int, _ height: Int, _ allow: Bool
    ) -> Binding<ResizeRule.FitMode> {
        Binding(
            get: {
                if case .exact(_, _, let fit, _) = session.recipe.resize { return fit }
                return .fit
            },
            set: {
                session.setResize(.exact(width: width, height: height, fit: $0, allowUpscale: allow))
            }
        )
    }

    private func upscaleBinding(
        _ width: Int, _ height: Int, _ fit: ResizeRule.FitMode
    ) -> Binding<Bool> {
        Binding(
            get: {
                if case .exact(_, _, _, let allow) = session.recipe.resize { return allow }
                return false
            },
            set: {
                session.setResize(.exact(width: width, height: height, fit: fit, allowUpscale: $0))
            }
        )
    }

    // MARK: - Mark

    private enum PlacementChoice: Hashable {
        case top
        case center
        case bottom
        case tiled
    }

    private var markPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Text").font(.caption).foregroundStyle(.secondary)
                TextField("Add a caption or watermark", text: overlayTextBinding)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { session.endInteraction() }
            }

            if let overlay = session.overlay {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Placement").font(.caption).foregroundStyle(.secondary)
                    Picker("Placement", selection: placementBinding) {
                        Text("Top").tag(PlacementChoice.top)
                        Text("Centre").tag(PlacementChoice.center)
                        Text("Bottom").tag(PlacementChoice.bottom)
                        Text("Tiled").tag(PlacementChoice.tiled)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Size").font(.caption).foregroundStyle(.secondary)
                    Slider(value: overlaySizeBinding, in: 0.02...0.15)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Opacity").font(.caption).foregroundStyle(.secondary)
                    Slider(value: overlayOpacityBinding, in: 0.05...1)
                }

                HStack(spacing: 8) {
                    Text("Colour").font(.caption).foregroundStyle(.secondary)
                    ForEach(colourChoices, id: \.name) { choice in
                        Button {
                            session.beginInteraction()
                            session.setOverlayColor(choice.color)
                            session.endInteraction()
                        } label: {
                            Circle()
                                .fill(choice.swiftUIColor)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(.separator))
                        }
                        .buttonStyle(.plain)
                        .help(choice.name)
                    }
                    Spacer()
                }

                Toggle("Drop shadow", isOn: shadowBinding)
                    .toggleStyle(.checkbox)
                    .font(.callout)

                Button("Remove Text") { session.clearOverlay() }
                    .controlSize(.small)
                Text(overlay.kind == .watermark
                     ? "A tiled watermark is repeated across the whole photo."
                     : "Percentages are of the exported photo, so the preview matches exactly.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { session.endInteraction() }
    }

    private var overlayTextBinding: Binding<String> {
        Binding(
            get: { session.overlay?.text ?? "" },
            set: { text in
                session.beginInteraction()
                session.setOverlayText(text)
            }
        )
    }

    private var placementBinding: Binding<PlacementChoice> {
        Binding(
            get: {
                guard let placement = session.overlay?.placement else { return .bottom }
                switch placement {
                case .tiled: return .tiled
                case .anchored(let anchor, _):
                    switch anchor {
                    case .top, .topLeading, .topTrailing: return .top
                    case .center, .leading, .trailing: return .center
                    default: return .bottom
                    }
                }
            },
            set: { choice in
                session.beginInteraction()
                switch choice {
                case .top:
                    session.setOverlayPlacement(.anchored(.top, marginFraction: 0.04), kind: .caption)
                case .center:
                    session.setOverlayPlacement(.anchored(.center, marginFraction: 0), kind: .caption)
                case .bottom:
                    session.setOverlayPlacement(.anchored(.bottom, marginFraction: 0.04), kind: .caption)
                case .tiled:
                    session.setOverlayPlacement(
                        .tiled(angleDegrees: -30, columnSpacingFraction: 0.25, rowSpacingFraction: 0.2),
                        kind: .watermark
                    )
                }
                session.endInteraction()
            }
        )
    }

    private var overlaySizeBinding: Binding<Double> {
        Binding(
            get: { session.overlay?.sizeFraction ?? 0.045 },
            set: { value in
                session.beginInteraction()
                session.setOverlaySize(value)
            }
        )
    }

    private var overlayOpacityBinding: Binding<Double> {
        Binding(
            get: { session.overlay?.opacity ?? 1 },
            set: { value in
                session.beginInteraction()
                session.setOverlayOpacity(value)
            }
        )
    }

    private var shadowBinding: Binding<Bool> {
        Binding(
            get: { session.overlay?.shadow ?? false },
            set: { session.setOverlayShadow($0) }
        )
    }

    private struct ColourChoice {
        let name: String
        let color: RGBAColor
        var swiftUIColor: Color {
            Color(red: color.red, green: color.green, blue: color.blue)
        }
    }

    private var colourChoices: [ColourChoice] {
        [
            ColourChoice(name: "White", color: .white),
            ColourChoice(name: "Black", color: .black),
            ColourChoice(name: "Yellow", color: RGBAColor(red: 1, green: 0.85, blue: 0.1)),
            ColourChoice(name: "Orange", color: RGBAColor(red: 1, green: 0.45, blue: 0.1)),
        ]
    }

    // MARK: - Metadata

    private var metadataPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("Untitled", text: $titleText)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Capture date", isOn: $hasDate)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                DatePicker("", selection: $captureDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .disabled(!hasDate)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Location").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("Latitude", text: $latitudeText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 92)
                    TextField("Longitude", text: $longitudeText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 92)
                }
                Text("Leave both empty to remove the location.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button {
                Task { await saveMetadata() }
            } label: {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Save to File")
                }
            }
            .disabled(isSaving || overrides().isEmpty || applyMetadata == nil)

            Text("Written into the photo itself — deleting the catalog cannot lose it. The catalogue is a cache of the file, never the other way round. A capture date stores an offset, not a zone name.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .onAppear { loadMetadataFields() }
        .onChange(of: session.fileMetadata) { _, _ in loadMetadataFields() }
    }

    private func loadMetadataFields() {
        titleText = session.fileMetadata.title ?? ""
        if let instant = session.fileMetadata.captureInstant {
            hasDate = true
            captureDate = instant
        } else {
            hasDate = false
        }
        if let gps = session.fileMetadata.gps {
            latitudeText = String(format: "%.6f", gps.latitude)
            longitudeText = String(format: "%.6f", gps.longitude)
        } else {
            latitudeText = ""
            longitudeText = ""
        }
    }

    private func overrides() -> MetadataOverrides {
        var result = MetadataOverrides()
        if titleText != (session.fileMetadata.title ?? "") {
            let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            result.title = trimmed.isEmpty ? .clear : .set(trimmed)
        }
        if hasDate {
            let existing = session.fileMetadata.captureInstant
            if existing == nil || abs(captureDate.timeIntervalSince(existing ?? .distantPast)) > 1 {
                result.capture = .set(CaptureEdit(
                    instant: captureDate,
                    offsetSeconds: TimeZone.current.secondsFromGMT(for: captureDate)
                ))
            }
        } else if session.fileMetadata.captureInstant != nil {
            result.capture = .clear
        }
        let latitude = Double(latitudeText.trimmingCharacters(in: .whitespaces))
        let longitude = Double(longitudeText.trimmingCharacters(in: .whitespaces))
        if latitude == nil && longitude == nil {
            if session.fileMetadata.gps != nil { result.gps = .clear }
        } else if let latitude, let longitude,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) {
            result.gps = .set(GPSPoint(latitude: latitude, longitude: longitude))
        }
        return result
    }

    private func saveMetadata() async {
        guard let applyMetadata else { return }
        isSaving = true
        _ = await applyMetadata(overrides())
        isSaving = false
    }

    // MARK: - Format

    private var formatPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Format").font(.caption).foregroundStyle(.secondary)
                Picker("Format", selection: formatBinding) {
                    ForEach(OutputFormats.available, id: \.self) { kind in
                        Text(title(for: kind)).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Quality").font(.caption).foregroundStyle(.secondary)
                Picker("Quality", selection: qualityBinding) {
                    ForEach(OutputFormat.qualityPresets, id: \.self) { quality in
                        Text(qualityTitle(quality)).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!session.recipe.format.isLossy)
            }

            Text(session.recipe.format.isLossy
                 ? "A lossy copy. Exporting re-encodes the photo once."
                 : "A lossless copy. The file will be larger.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var formatBinding: Binding<OutputFormat.Kind> {
        Binding(get: { session.recipe.format.kind }, set: { session.setFormat($0) })
    }

    private var qualityBinding: Binding<Double> {
        Binding(get: { session.recipe.format.quality }, set: { session.setQuality($0) })
    }

    private func title(for kind: OutputFormat.Kind) -> String {
        switch kind {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .tiff: "TIFF"
        case .heic: "HEIC"
        case .avif: "AVIF"
        }
    }

    private func qualityTitle(_ quality: Double) -> String {
        switch quality {
        case 0.95: "Best"
        case 0.8: "Smaller"
        default: "High"
        }
    }

    // MARK: - Status

    private var status: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let plan = session.plan {
                Text("\(plan.output.width) × \(plan.output.height) px")
                    .font(.callout)
                    .monospacedDigit()
                Text("\(Int(plan.format.quality * 100))% quality · \(title(for: plan.format.kind))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if session.isIdentity {
                    Text("Nothing changed — Export copies the original file.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if session.recipe.overlays.count > 0 || !session.recipe.crop.isFull {
                    Text("Camera maker notes and HDR gain maps are not carried into an edited copy.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("This size is larger than the editor allows.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("Original \(session.storedSize.width) × \(session.storedSize.height) px")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
