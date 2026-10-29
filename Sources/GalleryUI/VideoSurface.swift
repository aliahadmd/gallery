import AVFoundation
import SwiftUI

/// An `AVPlayerLayer` with no chrome of its own.
///
/// Deliberately not `AVPlayerView` or `AVPlayerViewController`: their transport is designed for a player
/// window, and in a gallery viewer it fights the photo chrome around it. The layer is also the only piece of
/// this that belongs to AppKit — the transport is SwiftUI, and the pool, not this view, owns the player.
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    /// The layer must not outlive its appearance holding a player: SwiftUI keeps representables around
    /// across rebuilds, and a layer that still points at a paused clip keeps its decode pipeline warm.
    static func dismantleNSView(_ view: PlayerLayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlayerLayerView is created in code only")
    }

    override func layout() {
        super.layout()
        // The layer does not autoresize inside a host layer, and a stale frame is a letterboxed clip with
        // its controls a finger's width off.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
