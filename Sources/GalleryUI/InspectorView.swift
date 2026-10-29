import SwiftUI
import CoreGraphics
import MapKit
import GalleryDomain

/// What the selected photo is, without leaving the grid.
///
/// The inspector reads its row from the model rather than from a copy taken at click time: pass B lands
/// dimensions and a capture date seconds after a scan starts, and a panel that keeps describing the row as
/// it looked when the user clicked would be wrong for exactly as long as the scan is interesting.
public struct InspectorView: View {
    private let model: MediaLibraryModel

    @State private var preview: CGImage?

    public init(model: MediaLibraryModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            if let item = model.selectedItem {
                details(item)
            } else {
                ContentUnavailableView("No Selection", systemImage: "photo",
                                       description: Text("Select a photo to see its details."))
                    .padding(.top, 40)
            }
        }
        .frame(minWidth: 240, idealWidth: 280)
    }

    private func details(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            previewImage(item)

            HStack(alignment: .firstTextBaseline) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button { Task { await model.toggleFavorite(item.id) } } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(item.isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }

            if let captured = item.capture?.instant {
                Text(captured.formatted(date: .long, time: .standard))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if item.error != .none {
                Label(item.error.userReason, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.yellow)
            }
            if item.isOffline {
                Label(IndexError.offline.userReason, systemImage: "icloud.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                row("Kind", kind(item))
                if let size = item.pixelSize, size.width > 0 {
                    row("Dimensions", "\(size.width) × \(size.height)")
                }
                if let duration = item.durationDisplay {
                    row("Duration", duration)
                }
                row("Size", item.byteSize.formatted(.byteCount(style: .file)))
                if let codec = item.codec, !codec.isEmpty {
                    row("Codec", codec)
                }
                if let device = item.device, !device.isEmpty {
                    row("Camera", device)
                }
                if let lens = item.lens, !lens.isEmpty {
                    row("Lens", lens)
                }
            }

            if let gps = item.gps, gps.isValid {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                    row("Coordinates", String(format: "%.4f, %.4f", gps.latitude, gps.longitude))
                }
                // Where it was taken, at the size of the panel. Hit testing is off so the map cannot steal
                // the scroll wheel from the inspector it sits in.
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: gps.latitude, longitude: gps.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                ))) {
                    Marker(item.name, coordinate: CLLocationCoordinate2D(latitude: gps.latitude,
                                                                         longitude: gps.longitude))
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .allowsHitTesting(false)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                row("Folder", model.sources.first { $0.id == item.sourceID }?.displayName ?? "—")
                if !item.relativePath.isEmpty {
                    row("Path", item.relativePath, selectable: true)
                }
                row("Added", item.addedAt.formatted(date: .abbreviated, time: .shortened))
                if let modified = item.modificationDate {
                    row("Modified", modified.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .padding(16)
        .task(id: PreviewKey(item)) {
            preview = await model.preview(for: item)
        }
    }

    @ViewBuilder private func previewImage(_ item: MediaItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: item.kind == .video ? "video" : "photo")
                    .font(.system(size: 26, weight: .thin))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 160)
        .frame(maxWidth: .infinity)
    }

    private func row(_ label: String, _ value: String, selectable: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Group {
                if selectable {
                    Text(value).textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .lineLimit(3)
            .truncationMode(.middle)
        }
        .font(.callout)
    }

    private func kind(_ item: MediaItem) -> String {
        var parts: [String] = [item.kind == .video ? "Video" : "Photo"]
        if item.subtype.contains(.raw) { parts.append("RAW") }
        if item.isLivePhotoCompanion { parts.append("Live") }
        if !item.fileExtension.isEmpty { parts.append(item.fileExtension.uppercased()) }
        return parts.joined(separator: " · ")
    }

    /// A row lands with a size and, after pass B, everything else. The preview only has to be re-fetched when
    /// the picture itself could have changed — a new row, or a new stamp on this one.
    private struct PreviewKey: Equatable {
        let id: MediaID
        let mtime: Date?

        init(_ item: MediaItem) {
            id = item.id
            mtime = item.modificationDate
        }
    }
}
