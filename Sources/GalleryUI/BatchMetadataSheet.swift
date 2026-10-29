import SwiftUI
import GalleryEditing

/// Title, capture date and location applied to a whole selection, field by field.
struct BatchMetadataSheet: View {
    let model: MediaLibraryModel
    @Bindable var session: BatchMetadataSession
    @State private var isApplying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Metadata")
                .font(.title3.weight(.semibold))
            Text(session.count == 1
                 ? "The fields are written into the file itself."
                 : "The fields are written into all \(session.count) files.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Toggle("Title", isOn: $session.applyTitle).toggleStyle(.checkbox)
                    TextField("", text: $session.title)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .disabled(!session.applyTitle)
                }
                GridRow {
                    Toggle("Capture date", isOn: $session.applyDate).toggleStyle(.checkbox)
                    DatePicker("", selection: $session.date, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .disabled(!session.applyDate)
                }
                GridRow {
                    Toggle("Location", isOn: $session.applyLocation).toggleStyle(.checkbox)
                    HStack(spacing: 6) {
                        TextField("Latitude", text: $session.latitude)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 96)
                        TextField("Longitude", text: $session.longitude)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 96)
                    }
                    .disabled(!session.applyLocation)
                }
            }

            Text("Sets are written without re-encoding the pixels. Clearing a field re-encodes, because ImageIO cannot remove a tag in place. The previous values are kept in memory for one Undo.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { model.closeBatchMetadata() }
                Button {
                    Task {
                        isApplying = true
                        await model.applyBatchMetadata()
                        isApplying = false
                    }
                } label: {
                    if isApplying {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Write Metadata")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.overrides == nil || isApplying)
            }
        }
        .padding(18)
        .frame(minWidth: 500, minHeight: 320)
    }
}
