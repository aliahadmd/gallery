import SwiftUI
import AVFoundation
import CoreGraphics
import GalleryDomain

/// The photo or clip, over the grid, at the size the display can give it.
///
/// One decode per item and a transform on top of it: zoom and pan move a bitmap that is already in memory,
/// so neither costs a second read of the file. Video is a thin transport over an `AVPlayerLayer`; the player
/// itself belongs to the model's pool, so a SwiftUI rebuild can neither orphan a playing clip nor keep one
/// alive after the viewer closes.
public struct ViewerView: View {
    private let model: MediaLibraryModel

    @State private var image: CGImage?
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var loadFailed = false

    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    @State private var playbackTime: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying = false
    @State private var isScrubbing = false

    @FocusState private var isFocused: Bool

    public init(model: MediaLibraryModel) {
        self.model = model
    }

    public var body: some View {
        if let item = model.viewerItem {
            ZStack {
                Color.black.opacity(0.94).ignoresSafeArea()
                stage(item)
                chrome(item)
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onAppear { isFocused = true }
            .onChange(of: model.viewerID) { _, _ in resetMedia() }
            .onKeyPress(.leftArrow) {
                Task { await model.stepViewer(by: -1) }
                return .handled
            }
            .onKeyPress(.rightArrow) {
                Task { await model.stepViewer(by: 1) }
                return .handled
            }
            .onKeyPress(.space) {
                togglePlayback()
                return .handled
            }
            .onKeyPress(.upArrow) { setZoom(zoom * 1.25); return .handled }
            .onKeyPress(.downArrow) { setZoom(zoom / 1.25); return .handled }
            .onKeyPress(.escape) {
                model.closeViewer()
                return .handled
            }
            .task(id: LoadKey(item)) { await load(item) }
            .task(id: model.viewerID) { await trackPlayback() }
            .transition(.opacity)
        }
    }

    // MARK: - Stage

    @ViewBuilder private func stage(_ item: MediaItem) -> some View {
        if item.kind == .video, !loadFailed, let player {
            VideoSurface(player: player)
                .padding(56)
        } else if item.kind == .image, !loadFailed, let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .scaleEffect(zoom)
                .offset(offset)
                .gesture(pan)
                .simultaneousGesture(magnify)
                .onTapGesture(count: 2) { setZoom(zoom > 1.01 ? 1 : 2.5) }
                .padding(56)
        } else {
            loadingOrFailure
        }
    }

    @ViewBuilder private var loadingOrFailure: some View {
        if isLoading {
            ProgressView().controlSize(.large).tint(.white)
        } else {
            VStack(spacing: 8) {
                Image(systemName: loadFailed ? "exclamationmark.triangle" : "photo")
                    .font(.system(size: 30, weight: .thin))
                Text(loadFailed ? "This file could not be opened." : "Nothing to show.")
                    .font(.callout)
            }
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    // MARK: - Chrome

    @ViewBuilder private func chrome(_ item: MediaItem) -> some View {
        VStack {
            HStack(spacing: 10) {
                Button { model.closeViewer() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")

                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button { Task { await model.toggleFavorite(item.id) } } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(item.isFavorite ? .yellow : .white)
                }
                .buttonStyle(.plain)
                .help("Favorite (⌘⇧F)")

                if let index = model.items.firstIndex(where: { $0.id == item.id }) {
                    Text("\(index + 1) of \(model.items.count)")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }

                Button { model.isInspectorPresented.toggle() } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .buttonStyle(.plain)
                .help("Show Info (⌘⌥I)")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .foregroundStyle(.white)

            Spacer()

            if item.kind == .video {
                videoBar(item)
            } else {
                imageBar(item)
            }
        }
    }

    @ViewBuilder private func imageBar(_ item: MediaItem) -> some View {
        HStack(spacing: 10) {
            Text(item.capture?.instant.formatted(date: .abbreviated, time: .shortened) ?? item.name)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            zoomControls
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder private func videoBar(_ item: MediaItem) -> some View {
        HStack(spacing: 12) {
            Button { togglePlayback() } label: {
                Image(systemName: isPlaying ? "pause.fill" : (isAtEnd ? "arrow.counterclockwise" : "play.fill"))
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 26)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Pause (Space)" : "Play (Space)")

            Text(timeLabel(playbackTime))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 56, alignment: .trailing)

            Slider(value: scrubBinding, in: 0...max(duration, 0.01)) { editing in
                isScrubbing = editing
                if !editing { seek(to: playbackTime) }
            }
            .tint(.white)
            .frame(maxWidth: 420)

            Text(timeLabel(duration))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 56, alignment: .leading)

            if let codec = item.codec, !codec.isEmpty {
                Text(codec.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { setZoom(1) } label: { Text("\(Int(zoom * 100))%").monospacedDigit() }
                .frame(minWidth: 52)
            Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help("Zoom (↑↓, or pinch)")
    }

    // MARK: - Playback

    private var isAtEnd: Bool {
        duration > 0 && playbackTime >= duration - 0.15 && !isPlaying
    }

    private var scrubBinding: Binding<Double> {
        Binding(get: { min(playbackTime, max(duration, 0.01)) },
                set: { playbackTime = max(0, $0) })
    }

    private func togglePlayback() {
        guard let player else { return }
        if isAtEnd {
            player.seek(to: .zero)
            playbackTime = 0
            player.play()
        } else if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Polls the player instead of observing it: four reads a second, only while the viewer is on screen,
    /// and no KVO/Combine teardown to get wrong. Scrubbing wins over the clock so the thumb does not fight
    /// the user's finger.
    private func trackPlayback() async {
        while !Task.isCancelled {
            if let player {
                if !isScrubbing {
                    let seconds = player.currentTime().seconds
                    if seconds.isFinite { playbackTime = max(0, seconds) }
                }
                isPlaying = player.timeControlStatus == .playing
                if duration <= 0, let total = player.currentItem?.duration.seconds,
                   total.isFinite, total > 0 {
                    duration = total
                }
                // A container AVFoundation will not decode is a message, not a black rectangle that looks
                // like a clip that has not started yet.
                if player.currentItem?.status == .failed {
                    loadFailed = true
                    isLoading = false
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds.rounded(.down))
        return whole >= 3600
            ? String(format: "%d:%02d:%02d", whole / 3600, (whole % 3600) / 60, whole % 60)
            : String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: - Media

    /// A photo decodes to a bitmap; a clip hands the pool's player to a layer and starts it. A video that
    /// opens is a video the user asked to watch, so play is the default and pause is one key away.
    private func load(_ item: MediaItem) async {
        if item.kind == .video {
            let lease = await model.videoLease(for: item)
            guard !Task.isCancelled, model.viewerID == item.id else { return }
            image = nil
            player = lease?.player
            isLoading = false
            loadFailed = lease == nil
            duration = Double(item.durationMicroseconds ?? 0) / 1_000_000
            playbackTime = 0
            lease?.player.play()
            // The next clip is opened while this one plays, so → is a cut rather than a load.
            await model.preloadVideo(after: item)
        } else {
            let loaded = await model.viewerImage(for: item)
            guard !Task.isCancelled, model.viewerID == item.id else { return }
            player = nil
            image = loaded
            isLoading = false
            loadFailed = loaded == nil
        }
    }

    private func resetMedia() {
        resetTransform()
        image = nil
        player = nil
        isLoading = true
        loadFailed = false
        playbackTime = 0
        duration = 0
        isPlaying = false
        isScrubbing = false
    }

    // MARK: - Gestures

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1.01 else { return }
                offset = CGSize(width: baseOffset.width + value.translation.width,
                                height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in baseOffset = offset }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = clampZoom(baseZoom * value.magnification)
            }
            .onEnded { _ in
                baseZoom = zoom
                if zoom <= 1.01 { withAnimation(.snappy) { offset = .zero; baseOffset = .zero } }
            }
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation(.snappy(duration: 0.18)) {
            zoom = clampZoom(value)
            baseZoom = zoom
            if zoom <= 1.01 { offset = .zero; baseOffset = .zero }
        }
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(8, max(0.5, value))
    }

    private func resetTransform() {
        zoom = 1
        baseZoom = 1
        offset = .zero
        baseOffset = .zero
    }

    /// A new photo is a new decode, and a favorite toggle is not.
    private struct LoadKey: Equatable {
        let id: MediaID
        let mtime: Date?
        let stage: IndexStage

        init(_ item: MediaItem) {
            id = item.id
            mtime = item.modificationDate
            stage = item.stage
        }
    }
}
