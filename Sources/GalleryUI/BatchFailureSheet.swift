import SwiftUI

/// What a batch could not do, item by item. One aggregate alert is not enough when 300 of 4,000 files fail.
struct BatchFailureSheet: View {
    let failures: [BatchSession.Failure]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(failures.count == 1
                     ? "One item could not be completed"
                     : "\(failures.count) items could not be completed")
                    .font(.headline)
                Spacer()
            }
            List(failures) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(failure.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 300)
    }
}
