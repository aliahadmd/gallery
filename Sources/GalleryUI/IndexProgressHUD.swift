import SwiftUI
import GalleryDomain

/// What the scan is doing right now, over the grid it is filling.
///
/// Enumeration and decoding are reported as different things because they finish at different times: a bar
/// that measures "files listed" reaching 100% is not a promise that the previews are ready.
///
/// The two controls are optional because the number on screen is not always a folder's own walk: when it is
/// the preview drain behind a finished walk, there is no scan here to pause or cancel.
struct IndexProgressHUD: View {
    let progress: IndexProgress
    let onPause: (() -> Void)?
    let onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass.circle")
                    .foregroundStyle(.secondary)
                Text(progress.phase.hudLabel).font(.callout.weight(.medium))
                Spacer(minLength: 8)
                if let pause = onPause {
                    Button(action: pause) {
                        Image(systemName: progress.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(progress.isPaused ? "Resume this scan" : "Pause this scan")
                }

                if let cancel = onCancel {
                    Button(role: .destructive, action: cancel) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop scanning this folder")
                }
            }

            if progress.phase == .enumerating || progress.phase == .sweeping {
                Text("\(progress.discovered.formatted()) files found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if progress.phase == .analyzing {
                // The third pass has its own task, so it gets its own bar and its own words: "1,204 of 8,000
                // analysed" is a different promise from "previews ready", and the grid is already complete.
                ProgressView(value: progress.analysisFraction)
                    .progressViewStyle(.linear)
                Text("\(progress.analyzed.formatted()) of \(progress.discovered.formatted()) analysed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView(value: progress.passBFraction)
                    .progressViewStyle(.linear)
                Text("\(progress.thumbnailed.formatted()) of \(progress.discovered.formatted()) previews")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if progress.isPaused {
                Text("Paused").font(.caption2).foregroundStyle(.orange)
            }
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

extension IndexPhase {
    var hudLabel: String {
        switch self {
        case .resolving: "Opening folder…"
        case .enumerating: "Listing files…"
        case .sweeping: "Checking for deletions…"
        case .readingMetadata: "Reading photo data…"
        case .deriving: "Building albums…"
        case .thumbnailing: "Making previews…"
        case .analyzing: "Reading scenes and text…"
        case .watching: "Watching for changes"
        case .finished: "Up to date"
        case .failed: "Scan stopped"
        }
    }
}
