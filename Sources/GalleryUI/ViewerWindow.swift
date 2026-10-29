import SwiftUI
import GalleryDomain

/// The viewer in a window of its own, for a second display or a bigger look at one photo.
///
/// It shares the model with the library window on purpose: the photo the viewer is on is model state, so
/// stepping with the arrows in either window moves both, and the pool still owns exactly one player.
public struct ViewerWindow: View {
    private let model: MediaLibraryModel

    public init(model: MediaLibraryModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.viewerItem != nil {
                ViewerView(model: model)
            } else {
                ContentUnavailableView(
                    "No Photo Open",
                    systemImage: "photo",
                    description: Text("Open a photo in the library, then choose Open in New Window (⌘⏎).")
                )
                .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}
