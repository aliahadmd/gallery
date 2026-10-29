import Foundation
import AVFoundation
import Vision
import GalleryCatalog
import GalleryDomain
import GalleryIndexing
import GallerySupport

/// Pass C: what is in the picture, not just what the file says about itself.
///
/// The cursor is a column on `media`, not a queue table: claiming *is* the state transition, so there is
/// nothing to keep in step with the rows it describes, and a crash costs one hop rather than a lost queue.
/// The pass is deliberately subordinate — it waits while pass B is running, pauses when told to, and stops
/// with the window — because it is the most expensive thing this app does and the least urgent.
public actor AnalysisWorker {
    public struct Configuration: Sendable {
        /// Vision is roughly ten times a decode, so hops are small: the HUD stays honest and a cancelled
        /// run loses a couple of seconds rather than a minute.
        public var batchRows: Int
        /// Two attempts, not three: a file Vision cannot read is unlikely to become readable by asking again.
        public var maximumAttempts: Int
        public var visionLane: BlockingLane
        /// True while another pass should win. Injected as a closure so this actor does not need a handle on
        /// `MetadataWorker` — and so a test can open and close the gate deterministically.
        public var gate: (@Sendable () async -> Bool)?
        public var analyzer: VisionAnalyzer.Configuration
        public var faces: FaceClusterer.Configuration
        public var duplicates: DuplicateFinder.Configuration
        public var pausedPollInterval: Duration

        public init(batchRows: Int = 32, maximumAttempts: Int = 2,
                    visionLane: BlockingLane = BlockingLane(label: "app.gallery.vision",
                                                           semaphore: .vision()),
                    gate: (@Sendable () async -> Bool)? = nil,
                    analyzer: VisionAnalyzer.Configuration = .init(),
                    faces: FaceClusterer.Configuration = .init(),
                    duplicates: DuplicateFinder.Configuration = .init(),
                    pausedPollInterval: Duration = .milliseconds(500)) {
            self.batchRows = max(1, batchRows)
            self.maximumAttempts = max(1, maximumAttempts)
            self.visionLane = visionLane
            self.gate = gate
            self.analyzer = analyzer
            self.faces = faces
            self.duplicates = duplicates
            self.pausedPollInterval = pausedPollInterval
        }
    }

    public struct Outcome: Sendable, Hashable {
        public var hops = 0
        public var claimed = 0
        public var analyzed = 0
        public var textFound = 0
        public var tagged = 0
        public var facesFound = 0
        public var duplicatesLinked = 0
        public var failed = 0
        public var parked = 0
        public var droppedBatches = 0
    }

    private enum Verdict {
        case analyzed(AnalysisJob, VisionAnalyzer.Still)
        case failed(AnalysisJob, String)
        case released(AnalysisJob)
    }

    private let catalog: Catalog
    private let resolver: any MediaResolving
    private let analyzer: VisionAnalyzer
    private let faceIndex: FaceIndex
    private let duplicateFinder: DuplicateFinder
    private let configuration: Configuration

    private var task: Task<Void, Never>?
    private var isDraining = false
    private var isPaused = false
    private var progress: [SourceID: IndexProgress] = [:]
    private var listeners: [UUID: AsyncStream<IndexProgress>.Continuation] = [:]

    public init(catalog: Catalog, resolver: any MediaResolving,
                configuration: Configuration = Configuration()) {
        self.catalog = catalog
        self.resolver = resolver
        self.analyzer = VisionAnalyzer(configuration: configuration.analyzer)
        self.faceIndex = FaceIndex(
            catalog: catalog,
            revision: Int64(VNGenerateImageFeaturePrintRequest.currentRevision),
            clusterer: FaceClusterer(configuration: configuration.faces)
        )
        self.duplicateFinder = DuplicateFinder(configuration: configuration.duplicates)
        self.configuration = configuration
    }

    // MARK: - Running

    public var isRunning: Bool { task != nil }

    public func start() {
        guard task == nil else { return }
        // A previous process may have been killed between claim and write. One consumer per process, so the
        // reset is safe; pass B makes the same assumption about its queue.
        let catalog = self.catalog
        task = Task(priority: .utility) {
            try? await catalog.beginAnalysisSession()
            let outcome = await self.drainGuarded()
            Log.indexing.info("analysis: \(outcome.analyzed) analysed, \(outcome.tagged) tagged, \(outcome.textFound) with text, \(outcome.facesFound) faces, \(outcome.failed) failed, \(outcome.parked) parked")
            self.task = nil
        }
    }

    public func drain() async -> Outcome {
        guard task == nil else { return Outcome() }
        return await drainGuarded()
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    public func setPaused(_ paused: Bool) async {
        isPaused = paused
        for sourceID in progress.keys { await publishSnapshot(sourceID) }
    }

    /// "Analyze Library Again": drop every derived row, then walk the library from the top.
    public func reanalyze() async throws {
        cancel()
        try await catalog.resetAnalysis()
        start()
    }

    private func drainGuarded() async -> Outcome {
        guard !isDraining else { return Outcome() }
        isDraining = true
        let outcome = await drainLoop()
        isDraining = false
        return outcome
    }

    private func drainLoop() async -> Outcome {
        var outcome = Outcome()
        while !Task.isCancelled {
            await waitWhilePaused()
            if let gate = configuration.gate, await gate() {
                // Pass B owns the machine while it runs; analysis resumes when it reports finished.
                try? await Task.sleep(for: configuration.pausedPollInterval)
                continue
            }
            guard let jobs = try? await catalog.claimAnalysis(limit: configuration.batchRows),
                  !jobs.isEmpty else { break }
            await process(jobs, into: &outcome)
        }
        if !Task.isCancelled {
            for sourceID in progress.keys { await publishSnapshot(sourceID) }
        }
        return outcome
    }

    private func waitWhilePaused() async {
        while isPaused, !Task.isCancelled {
            try? await Task.sleep(for: configuration.pausedPollInterval)
        }
    }

    private func process(_ jobs: [AnalysisJob], into outcome: inout Outcome) async {
        outcome.hops += 1
        outcome.claimed += jobs.count
        let ids = jobs.map(\.mediaID)
        let targets = await resolver.targets(for: ids)
        let analyzer = self.analyzer
        let faceIndex = self.faceIndex
        let lane = configuration.visionLane
        let maximumAttempts = configuration.maximumAttempts

        let verdicts = await withTaskGroup(of: Verdict.self) { group in
            for job in jobs {
                group.addTask {
                    guard let target = targets[job.mediaID] else {
                        return .failed(job, "The catalog cannot find this file.")
                    }
                    let root = target.scopedRoot ?? target.url
                    // A clip's duration is an AVFoundation load, not a Vision call: read it before the lane so
                    // the blocking work inside stays purely analysis.
                    let isVideo = job.kind == .video
                    let duration = isVideo
                        ? try? await AVURLAsset(url: target.url).load(.duration)
                        : nil
                    let work = await lane.run {
                        SecurityScope.withAccess(to: root) {
                            if isVideo, let duration {
                                return analyzer.analyzeVideo(at: target.url, duration: duration)
                            }
                            return analyzer.analyzeImage(at: target.url, subtype: job.subtype)
                        }
                    }
                    switch work {
                    case .cancelled:
                        return .released(job)
                    case .completed(let still):
                        guard var still else {
                            return .failed(job, "The file could not be decoded.")
                        }
                        // The person a face belongs to is not Vision's answer; the index assigns it, serially,
                        // before the row is written so a face is never stored without its cluster. Clips have
                        // no per-frame pixels to print, so their faces are counted but never clustered.
                        if !isVideo, !still.faces.isEmpty {
                            still.faces = await faceIndex.assign(still.faces, mediaID: job.mediaID)
                        }
                        return .analyzed(job, still)
                    }
                }
            }
            var collected: [Verdict] = []
            for await verdict in group { collected.append(verdict) }
            return collected
        }

        var results: [MediaAnalysisResult] = []
        var failed: [MediaID] = []
        var parked: [MediaID] = []
        var released: [MediaID] = []
        for verdict in verdicts {
            switch verdict {
            case .analyzed(let job, let still):
                let tags = AnalysisRules.tags(from: still.labels,
                                              ocrCharacters: still.ocrText?.count ?? 0,
                                              confidence: configuration.analyzer.tagConfidence,
                                              limit: configuration.analyzer.maximumTags)
                results.append(MediaAnalysisResult(
                    mediaID: job.mediaID,
                    statHash: job.statHash,
                    version: AnalysisWorker.version,
                    revision: AnalysisWorker.revision,
                    labels: still.labels,
                    ocrText: still.ocrText,
                    ocrBlockCount: still.ocrBlocks,
                    ocrWasAccurate: still.ocrAccurate,
                    aesthetic: still.aesthetic,
                    isUtility: AnalysisRules.isUtility(
                        aesthetic: still.aesthetic,
                        ocrCharacters: still.ocrText?.count ?? 0,
                        labels: still.labels,
                        subtype: job.subtype,
                        modelSaidSo: still.isUtility
                    ),
                    tags: tags,
                    dhash: still.dhash,
                    faces: still.faces,
                    frameCount: still.frames
                ))
                if still.ocrText != nil { outcome.textFound += 1 }
                if !tags.isEmpty { outcome.tagged += 1 }
                outcome.facesFound += still.faces.count
            case .failed(let job, _):
                if job.attempts >= maximumAttempts { parked.append(job.mediaID) } else { failed.append(job.mediaID) }
            case .released(let job):
                released.append(job.mediaID)
            }
        }

        do {
            if !results.isEmpty { try await catalog.recordAnalysis(results) }
        } catch {
            // Nothing landed: every claimed row goes back to the cursor rather than being counted as done.
            outcome.droppedBatches += 1
            try? await catalog.releaseClaims(jobs.map(\.mediaID))
            return
        }
        if !failed.isEmpty { try? await catalog.releaseClaims(failed) }
        if !parked.isEmpty { try? await catalog.parkClaims(parked) }
        if !released.isEmpty { try? await catalog.releaseClaims(released) }

        outcome.analyzed += results.count
        outcome.failed += failed.count
        outcome.parked += parked.count

        // Grouping runs after the rows land: the candidate query reads `media_analysis`, and a photo cannot
        // be compared against an analysis that has not been written yet.
        await linkDuplicates(results, jobs: jobs, into: &outcome)

        for sourceID in Set(jobs.map(\.sourceID)) { await publishSnapshot(sourceID) }
    }

    /// Pairs each analysed photo with the first candidate it resembles, joining that candidate's group or
    /// starting one. Local and incremental on purpose: a full recompute of duplicates at 100k is quadratic.
    private func linkDuplicates(_ results: [MediaAnalysisResult], jobs: [AnalysisJob],
                                into outcome: inout Outcome) async {
        let hashes = results.filter { $0.dhash != nil }
        guard !hashes.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.mediaID, $0) })
        let days = Set(jobs.map(\.dayBucket)).filter { $0 > 0 }
        let candidates = (try? await catalog.duplicateCandidates(
            days: days, excluding: jobs.map(\.mediaID), limit: 2_000
        )) ?? []
        guard !candidates.isEmpty else { return }

        let finder = duplicateFinder
        for result in hashes {
            guard let job = byID[result.mediaID], let hash = result.dhash else { continue }
            let aspect = job.pixelHeight > 0 ? Double(job.pixelWidth) / Double(job.pixelHeight) : 0
            let parent = (job.relativePath as NSString).deletingLastPathComponent
            let probe = DuplicateFinder.Probe(
                dhash: hash,
                aspectRatio: aspect,
                parentDirectory: parent == "." ? "" : parent,
                captureUTC: job.captureUTC
            )
            guard let match = finder.match(probe, among: candidates) else { continue }
            let groupID = (try? await catalog.duplicateGroupID(for: match.candidate.mediaID))
                ?? Int64(fnv1aID("dup:\(min(result.mediaID.rawValue, match.candidate.mediaID.rawValue))"))
            try? await catalog.addToDuplicateGroup(groupID: groupID, mediaID: result.mediaID,
                                                   distance: match.distance)
            outcome.duplicatesLinked += 1
        }
    }

    /// Bumped when the shape of a result changes (a new tag vocabulary, a new request). A change is offered
    /// to the user as "Analyze Library Again"; re-running 100k files behind their back is not a kindness.
    public static let version = 1
    public static var revision: String {
        "classify=\(VNClassifyImageRequest.currentRevision);" +
            "ocr=\(VNRecognizeTextRequest.currentRevision);" +
            "aes=\(VNCalculateImageAestheticsScoresRequest.currentRevision)"
    }

    // MARK: - Progress

    public func progressFeed() -> AsyncStream<IndexProgress> {
        let (stream, continuation) = AsyncStream<IndexProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        let token = UUID()
        listeners[token] = continuation
        continuation.onTermination = { _ in
            Task { await self.removeListener(token) }
        }
        return Coalescing(interval: .milliseconds(100)).attach(stream)
    }

    public func latestProgress(sourceID: SourceID? = nil) async -> [IndexProgress] {
        if let sourceID { return [await snapshot(sourceID)] }
        let known = Array(progress.keys)
        var entries: [IndexProgress] = []
        for id in known { entries.append(await snapshot(id)) }
        return entries
    }

    private func removeListener(_ token: UUID) { listeners[token] = nil }

    private func snapshot(_ sourceID: SourceID) async -> IndexProgress {
        let counts = (try? await catalog.analysisCounts(sourceID: sourceID)) ?? AnalysisCounts()
        return IndexProgress(
            sourceID: sourceID,
            phase: counts.pending > 0 ? .analyzing : .finished,
            discovered: counts.tracked,
            metadataDone: counts.done,
            thumbnailed: counts.done,
            failed: counts.parked,
            queued: counts.pending,
            isPaused: isPaused,
            analyzed: counts.done
        )
    }

    private func publishSnapshot(_ sourceID: SourceID) async {
        let fresh = await snapshot(sourceID)
        progress[sourceID] = fresh
        for listener in listeners.values { listener.yield(fresh) }
    }
}
