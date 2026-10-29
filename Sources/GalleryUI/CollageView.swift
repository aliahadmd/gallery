import SwiftUI
import GalleryEditing

/// How the collage asks for a destination; the same panel idiom as the editor's export.
public typealias CollageExportAction = @MainActor (CollageSession) async -> Void

/// One photo, twice — or twelve times: a template, a few sliders, and an export.
public struct CollageView: View {
    private let model: MediaLibraryModel
    private let session: CollageSession
    private let exportCopy: CollageExportAction?

    @FocusState private var isFocused: Bool

    public init(
        model: MediaLibraryModel,
        session: CollageSession,
        exportCopy: CollageExportAction? = nil
    ) {
        self.model = model
        self.session = session
        self.exportCopy = exportCopy
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                preview
                Divider()
                sidebar.frame(width: 260)
            }
            Divider()
            bottomBar
        }
        .background(.background)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .onKeyPress(.escape) {
            model.closeCollage()
            return .handled
        }
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { model.closeCollage() } label: {
                Image(systemName: "xmark.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .help("Close the collage (Esc)")
            VStack(alignment: .leading, spacing: 1) {
                Text("Collage").font(.headline)
                Text("\(session.memberCount) photos · \(Int(session.outputSize.width)) × \(Int(session.outputSize.height)) px")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.isRendering {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var preview: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image = session.preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(24)
                } else if session.isRendering {
                    ProgressView()
                } else {
                    Text("Nothing to compose.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                labelled("Template") {
                    Picker("Template", selection: templateBinding) {
                        Text("Grid 2 × 2").tag(CollageTemplate.grid(columns: 2))
                        Text("Grid 3 × 3").tag(CollageTemplate.grid(columns: 3))
                        Text("Hero top").tag(CollageTemplate.heroTop)
                        Text("Hero left").tag(CollageTemplate.heroLeft)
                        Text("Strip").tag(CollageTemplate.strip)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                labelled("Aspect") {
                    Picker("Aspect", selection: aspectBinding) {
                        Text("Square").tag(CollageAspect.square)
                        Text("4:5").tag(CollageAspect.portrait4x5)
                        Text("3:2").tag(CollageAspect.landscape3x2)
                        Text("16:9").tag(CollageAspect.wide16x9)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                labelled("Long side") {
                    HStack(spacing: 6) {
                        TextField("", value: longSideBinding, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 74)
                        Text("px").foregroundStyle(.secondary)
                    }
                }

                labelled("Gutter") {
                    Slider(value: gutterBinding, in: 0...0.03)
                }

                labelled("Margin") {
                    Slider(value: marginBinding, in: 0...0.08)
                }

                labelled("Title") {
                    TextField("Optional caption", text: titleBinding)
                        .textFieldStyle(.roundedBorder)
                }

                labelled("Background") {
                    HStack(spacing: 8) {
                        ForEach(backgroundChoices, id: \.name) { choice in
                            Button {
                                session.setBackground(choice.color)
                            } label: {
                                Circle()
                                    .fill(Color(red: choice.color.red, green: choice.color.green,
                                                blue: choice.color.blue))
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(.separator))
                            }
                            .buttonStyle(.plain)
                            .help(choice.name)
                        }
                        Spacer()
                    }
                }

                labelled("Format") {
                    Picker("Format", selection: formatBinding) {
                        ForEach(OutputFormats.available, id: \.self) { kind in
                            Text(kind.rawValue.uppercased()).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                if session.upscaleFactor > 1.05 {
                    Label(
                        "Some photos will be enlarged to fill their slot.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.bar)
    }

    private func labelled<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text("The collage is written as a new file. Nothing in the library changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { model.closeCollage() }
            Button("Export a Copy…") {
                Task {
                    if let exportCopy {
                        await exportCopy(session)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isRendering || exportCopy == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Bindings

    private var templateBinding: Binding<CollageTemplate> {
        Binding(get: { session.document.template }, set: { session.setTemplate($0) })
    }

    private var aspectBinding: Binding<CollageAspect> {
        Binding(get: { session.document.aspect }, set: { session.setAspect($0) })
    }

    private var longSideBinding: Binding<Int> {
        Binding(get: { session.document.longSide }, set: { session.setLongSide($0) })
    }

    private var gutterBinding: Binding<Double> {
        Binding(get: { session.document.gutterFraction }, set: { session.setGutter($0) })
    }

    private var marginBinding: Binding<Double> {
        Binding(get: { session.document.marginFraction }, set: { session.setMargin($0) })
    }

    private var titleBinding: Binding<String> {
        Binding(get: { session.document.title ?? "" }, set: { session.setTitle($0) })
    }

    private var formatBinding: Binding<OutputFormat.Kind> {
        Binding(get: { session.document.format.kind }, set: { session.setFormat($0) })
    }

    private struct BackgroundChoice {
        let name: String
        let color: RGBAColor
    }

    private var backgroundChoices: [BackgroundChoice] {
        [
            BackgroundChoice(name: "White", color: .white),
            BackgroundChoice(name: "Black", color: .black),
            BackgroundChoice(name: "Light grey", color: RGBAColor(white: 0.92)),
            BackgroundChoice(name: "Warm", color: RGBAColor(red: 0.98, green: 0.95, blue: 0.9)),
        ]
    }
}
