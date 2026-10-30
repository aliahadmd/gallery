import Foundation
import GalleryCatalog
import GalleryDomain
import GalleryImaging
import GalleryIndexing
import GallerySupport
import os

/// The cheap classification pass: reads stored metadata and Vision results, samples a few small pixels for
/// graphic candidates, and writes a category with its evidence. It never touches Vision and never decodes a
/// full image, so a library that has already been analysed is categorised in seconds.
public actor CategoryWorker {
    public struct Configuration: Sendable {
        public var batchRows: Int
        public var maximumAttempts: Int
        public var sampleSide: Int32
        public var samplesPerHop: Int
        /// Pass B owns the disk; the categorizer waits for it.
        public var gate: (@Sendable () async -> Bool)?
        public var isLowPower: @Sendable () -> Bool

        public init(
            batchRows: Int = 128, maximumAttempts: Int = 2,
            sampleSide: Int32 = Limits.categorySampleSide,
            samplesPerHop: Int = Limits.categorySamplesPerHop,
            gate: (@Sendable () async -> Bool)? = nil,
            isLowPower: @escaping @Sendable () -> Bool = {
                ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        ) {
            self.batchRows = max(1, batchRows)
            self.maximumAttempts = max(1, maximumAttempts)
            self.sampleSide = sampleSide
            self.samplesPerHop = samplesPerHop
            self.gate = gate
            self.isLowPower = isLowPower
        }
    }

    private let catalog: Catalog
    private let resolver: any MediaResolving
    private let configuration: Configuration
    private let lane = BlockingLane.imageBaking(label: "app.gallery.category")
    private var cancelled = false
    private var paused = false
    private var running = false

    public init(catalog: Catalog, resolver: any MediaResolving, configuration: Configuration = .init()) {
        self.catalog = catalog
        self.resolver = resolver
        self.configuration = configuration
    }

    public var isRunning: Bool { running }

    /// Whether the pass is holding between hops. The UI reads this to draw the HUD's pause state.
    public var isPaused: Bool { paused }

    public func cancel() {
        cancelled = true
    }

    public func setPaused(_ value: Bool) {
        paused = value
    }

    /// Classifies until the queue is empty. Returns how many rows were written.
    public func runOnce() async -> Int {
        guard !running else { return 0 }
        running = true
        // A cancel is meant to stop this pass, not to retire the worker: the next scan or analysis finish
        // starts a fresh pass in the same session.
        cancelled = false
        defer { running = false }
        try? await catalog.resetStaleCategoryClaims()

        var classified = 0
        // Both stops count: the explicit cancel flag (another session or a menu action) and cancellation of
        // the task that called us (the window closing).
        while !cancelled && !Task.isCancelled {
            if paused || configuration.isLowPower() {
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            if let gate = configuration.gate, await gate() {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            guard let jobs = try? await catalog.claimCategories(
                limit: configuration.batchRows, maximumAttempts: configuration.maximumAttempts
            ), !jobs.isEmpty else {
                break
            }
            var results: [CategoryResult] = []
            var samples = 0
            for job in jobs {
                if cancelled { break }
                var sampled: SampledFeatures?
                if samples < configuration.samplesPerHop, Self.isGraphicCandidate(job) {
                    if let features = await sample(job) {
                        sampled = features
                        samples += 1
                    }
                }
                let evidence = CategoryClassifier.classify(Self.input(job, sampled: sampled))
                results.append(CategoryResult(
                    mediaID: job.mediaID, statHash: job.statHash,
                    evidence: evidence, sampled: sampled
                ))
            }
            guard !results.isEmpty else { break }
            do {
                try await catalog.recordCategories(results)
                classified += results.count
            } catch {
                // Put this hop's rows back before leaving: a write failure is not evidence that the rows
                // were classified, and leaving them claimed would hide them until the next relaunch.
                try? await catalog.releaseCategoryClaims(results.map(\.mediaID))
                Log.analysis.error("categories: could not write a \(results.count)-row batch: \(error)")
                break
            }
        }
        return classified
    }

    public func resetAndRun() async -> Int {
        try? await catalog.resetCategories()
        return await runOnce()
    }

    // MARK: - Signals

    static func input(_ job: CategoryJob, sampled: SampledFeatures?) -> CategoryInput {
        let labels: [SceneLabel] = job.labelsJSON.flatMap { text in
            try? JSONDecoder().decode([SceneLabel].self, from: Data(text.utf8))
        } ?? []
        return CategoryInput(
            name: job.name, fileExtension: job.fileExtension, typeIdentifier: job.typeIdentifier,
            subtype: job.subtype, pixelSize: job.pixelSize, device: job.device,
            hasGPS: job.hasGPS, hasCaptureDate: job.hasCaptureDate,
            captureSource: job.captureSource, labels: labels,
            ocrChars: job.ocrChars, ocrBlocks: job.ocrBlocks, ocrAccurate: job.ocrAccurate,
            aesthetic: job.aesthetic, isUtility: job.isUtility, faceCount: job.faceCount,
            sampled: sampled
        )
    }

    /// Only ambiguous graphic candidates pay for a pixel profile: no camera, not a screenshot, and either a
    /// graphic extension, a small image or a squarish one.
    static func isGraphicCandidate(_ job: CategoryJob) -> Bool {
        guard job.device == nil, !job.subtype.contains(.screenshot) else { return false }
        if ["png", "ico", "cur", "tif", "tiff", "psd", "gif"].contains(job.fileExtension.lowercased()) {
            return true
        }
        guard let size = job.pixelSize else { return false }
        if size.longSide <= 1024 { return true }
        let aspect = Double(size.width) / Double(max(1, size.height))
        return aspect >= 0.9 && aspect <= 1.1
    }

    private func sample(_ job: CategoryJob) async -> SampledFeatures? {
        guard let target = await resolver.targets(for: [job.mediaID])[job.mediaID] else { return nil }
        let scope = target.scopedRoot ?? target.url.deletingLastPathComponent()
        let side = Int(configuration.sampleSide)
        let outcome = await lane.run { () -> SampledFeatures? in
            SecurityScope.begin(scope)
            defer { SecurityScope.end(scope) }
            return PixelProfile.sample(url: target.url, side: side)
        }
        guard case .completed(let features) = outcome else { return nil }
        return features
    }
}
