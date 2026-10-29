import CoreGraphics
import Foundation
import GalleryDomain
import GallerySupport
import os

public struct ExportRequest: Sendable {
    public var source: EditSource
    public var recipe: EditRecipe

    public init(source: EditSource, recipe: EditRecipe) {
        self.source = source
        self.recipe = recipe
    }
}

public enum ExportError: Error, Sendable, Hashable {
    case unreadable
    case notAnImage
    case unsupportedFormat(OutputFormat.Kind)
    case renderFailed
    case tooManyPixels
    case encodeFailed
    case verifyFailed
    case destinationNotWritable
    case cancelled

    public var userMessage: String {
        switch self {
        case .unreadable: "The file could not be read."
        case .notAnImage: "Only photos can be exported from the editor."
        case .unsupportedFormat(let kind): "This Mac cannot write \(kind.rawValue.uppercased()) files."
        case .renderFailed: "The edit could not be rendered."
        case .tooManyPixels: "The requested size is too large."
        case .encodeFailed: "The file could not be written."
        case .verifyFailed: "The written file failed its read-back check."
        case .destinationNotWritable: "The destination folder could not be written."
        case .cancelled: "The export was cancelled."
        }
    }
}

/// Renders copies of photos into a folder the user chose. Serial on its own lane so a fifty-file export
/// cannot starve the grid's decodes, and deterministic in naming because one file finishes before the next
/// name is chosen.
public actor Exporter {
    public struct Progress: Sendable, Hashable {
        public var completed: Int
        public var total: Int
        public var current: String?

        public init(completed: Int, total: Int, current: String? = nil) {
            self.completed = completed
            self.total = total
            self.current = current
        }
    }

    public struct Outcome: Sendable {
        public var written: [URL] = []
        public var failed: [MediaID: ExportError] = [:]
        public var skipped: [MediaID] = []

        public init() {}
    }

    private let lane: BlockingLane
    private var cancelled = false

    public init(lane: BlockingLane = BlockingLane(
        label: "app.gallery.editing", qos: .userInitiated,
        semaphore: AsyncSemaphore(value: 1)
    )) {
        self.lane = lane
    }

    public func cancel() {
        cancelled = true
    }

    /// One file to a name the user chose. The panel has already confirmed any overwrite, so an existing
    /// file at the destination is replaced.
    public func export(_ request: ExportRequest, to destination: URL) async -> Result<URL, ExportError> {
        cancelled = false
        let folder = destination.deletingLastPathComponent()
        SecurityScope.begin(folder)
        defer { SecurityScope.end(folder) }
        let temp = folder.appendingPathComponent(".gallery-tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }

        if let error = await write(request, to: temp) {
            return .failure(error)
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temp, to: destination)
            return .success(destination)
        } catch {
            return .failure(.destinationNotWritable)
        }
    }

    /// A selection to a folder. Names are resolved against the disk and against the batch's own reservations,
    /// so `number` never hands out a name twice.
    public func export(
        _ requests: [ExportRequest],
        to folder: URL,
        policy: ExportNaming.Policy,
        progress: @escaping @Sendable (Progress) -> Void
    ) async -> Outcome {
        cancelled = false
        var outcome = Outcome()
        guard !requests.isEmpty else { return outcome }

        SecurityScope.begin(folder)
        defer { SecurityScope.end(folder) }
        var reserved: Set<String> = []
        let taken: (String) -> Bool = { name in
            reserved.contains(name)
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
        }

        for (index, request) in requests.enumerated() {
            if cancelled {
                outcome.failed[request.source.mediaID] = .cancelled
                break
            }
            guard let name = ExportNaming.fileName(
                for: request.source, format: request.recipe.format, policy: policy, taken: taken
            ) else {
                outcome.skipped.append(request.source.mediaID)
                continue
            }
            reserved.insert(name)
            let destination = folder.appendingPathComponent(name)
            let temp = folder.appendingPathComponent(".gallery-tmp-\(UUID().uuidString)")

            let error = await write(request, to: temp)
            if let error {
                outcome.failed[request.source.mediaID] = error
                try? FileManager.default.removeItem(at: temp)
                progress(Progress(completed: index + 1, total: requests.count, current: name))
                continue
            }
            do {
                // Only an overwrite policy may replace an existing file; under `number` the name was already
                // unique, and deleting whatever appeared there since would destroy someone else's work.
                if policy.collision == .overwrite,
                   FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temp, to: destination)
                outcome.written.append(destination)
            } catch {
                outcome.failed[request.source.mediaID] = .destinationNotWritable
                try? FileManager.default.removeItem(at: temp)
            }
            progress(Progress(completed: index + 1, total: requests.count, current: name))
        }
        Log.editing.info(
            "export: \(outcome.written.count, privacy: .public) written, \(outcome.failed.count, privacy: .public) failed, \(outcome.skipped.count, privacy: .public) skipped"
        )
        return outcome
    }

    private func write(_ request: ExportRequest, to temp: URL) async -> ExportError? {
        let outcome = await lane.run { Self.perform(request, destination: temp) }
        switch outcome {
        case .completed(let error): return error
        case .cancelled: return .cancelled
        }
    }

    /// Runs on the editing lane. One open of the source: header first, then pixels only if the recipe
    /// actually changes them.
    private static func perform(_ request: ExportRequest, destination: URL) -> ExportError? {
        let source = request.source
        guard source.kind == .image else { return .notAnImage }

        let scope = source.scopedRoot ?? source.url.deletingLastPathComponent()
        SecurityScope.begin(scope)
        defer { SecurityScope.end(scope) }

        guard let header = EditRenderer.readHeader(source.url) else { return .unreadable }
        guard let plan = EditPlanBuilder.plan(
            request.recipe, stored: header.size, orientation: header.orientation
        ) else {
            // Retry without the pixel cap to tell "too big" from "invalid recipe".
            let uncapped = EditPlanBuilder.plan(
                request.recipe, stored: header.size, orientation: header.orientation,
                maxOutputPixels: .max
            )
            return uncapped == nil ? .renderFailed : .tooManyPixels
        }
        guard OutputFormats.isWritable(plan.format.kind) else {
            return .unsupportedFormat(plan.format.kind)
        }

        if let sourceKind = OutputFormats.kind(for: source.url),
           request.recipe.isIdentity(for: sourceKind) {
            do {
                try FileManager.default.copyItem(at: source.url, to: destination)
                return nil
            } catch {
                return .destinationNotWritable
            }
        }

        guard let decoded = EditRenderer.decode(source.url) else { return .unreadable }
        guard let rendered = EditRenderer.render(plan, from: decoded) else { return .renderFailed }
        let properties = MetadataPreserver.properties(from: header.properties, plan: plan)
        guard EditRenderer.encode(rendered, plan: plan, properties: properties, to: destination) else {
            return .encodeFailed
        }
        guard EditRenderer.verify(destination, matching: plan) else { return .verifyFailed }
        return nil
    }
}
