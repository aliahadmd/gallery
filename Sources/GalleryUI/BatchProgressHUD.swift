import SwiftUI

/// The batch equivalents of the scan HUD: what is running, how far, and a way out.
struct BatchProgressHUD: View {
    let session: BatchSession
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                Text(session.title)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                if session.isCancelling {
                    Text("Stopping…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop after the current item")
                }
            }
            ProgressView(value: session.fraction)
                .progressViewStyle(.linear)
            HStack {
                Text("\(session.completed) of \(session.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if session.failed > 0 {
                    Text("\(session.failed) failed")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let name = session.currentName {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}
