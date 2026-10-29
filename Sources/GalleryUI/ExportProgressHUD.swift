import SwiftUI
import GalleryEditing

/// The batch export's only chrome: which file, how far, and a way out. Placed where the scan HUD lives,
/// because it answers the same question — "what is the app doing with my folder".
public struct ExportProgressHUD: View {
    private let progress: Exporter.Progress
    private let onCancel: () -> Void

    public init(progress: Exporter.Progress, onCancel: @escaping () -> Void) {
        self.progress = progress
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
                Text("Exporting copies…").font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Stop exporting")
            }
            ProgressView(
                value: Double(progress.completed),
                total: Double(max(progress.total, 1))
            )
            .progressViewStyle(.linear)
            Text(progress.current ?? "\\(progress.completed) of \\(progress.total)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(10)
        .frame(width: 232)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(.separator)
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}
