import Foundation

public struct RenamePreviewRow: Identifiable, Sendable, Hashable {
    public var id: MediaID
    public var fromName: String
    public var toName: String
    public var issue: String?

    public init(id: MediaID, fromName: String, toName: String, issue: String? = nil) {
        self.id = id
        self.fromName = fromName
        self.toName = toName
        self.issue = issue
    }
}

/// What a rule would do, computed without touching a file or a database. The preview, the counts and the
/// conflicts are all properties of this value, which is what makes the sheet honest before anything moves.
public struct RenamePlan: Sendable, Hashable {
    public var moves: [RenameMove]
    public var skipped: [MediaID: RenameIssue]
    /// Non-fatal: a path-keyed volume can still be renamed, but a crash before the catalog write would cost
    /// that row its derived state.
    public var warnings: [MediaID: String]
    public var groups: [[MediaID]]
    public var preview: [RenamePreviewRow]
    public var unchanged: Int
    public var companionCount: Int
    public var overLimit: Bool
    public var subjectCount: Int

    public var isEmpty: Bool { moves.isEmpty }
    public var movedCount: Int { moves.count }
}

public enum RenamePlanBuilder {
    public static let maximumSubjects = 20_000

    /// Deterministic, ordered, and pure. `existingNames` maps a relative folder to the names it currently
    /// holds (from `contentsOfDirectory`, not from the catalog, which can be stale).
    public static func plan(
        _ rule: RenameRule,
        subjects: [RenameSubject],
        existingNames: [String: Set<String>],
        maximumSubjects: Int = maximumSubjects,
        timeZone: TimeZone = .current
    ) -> RenamePlan {
        var plan = RenamePlan(
            moves: [], skipped: [:], warnings: [:], groups: [], preview: [],
            unchanged: 0, companionCount: 0, overLimit: false, subjectCount: subjects.count
        )
        guard !subjects.isEmpty else { return plan }
        guard subjects.count <= maximumSubjects else {
            plan.overLimit = true
            return plan
        }

        let units = group(subjects)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone

        var candidates: [(unit: [RenameSubject], moves: [RenameMove], warning: String?)] = []
        var ordinal = 0

        for unit in units {
            guard let primary = unit.first(where: \.isLivePhotoStill) ?? unit.first else { continue }
            if primary.inTrash {
                for member in unit { plan.skipped[member.mediaID] = .trashed }
                continue
            }
            if primary.isOffline {
                for member in unit { plan.skipped[member.mediaID] = .offline }
                continue
            }

            var stem = transformed(
                primary.stem, rule: rule, captureDate: primary.captureDate,
                ordinal: ordinal, formatter: formatter
            )
            ordinal += 1

            if let issue = validate(stem: stem) {
                for member in unit { plan.skipped[member.mediaID] = issue }
                continue
            }

            var unitMoves: [RenameMove] = []
            var unitIssue: RenameIssue?
            for member in unit {
                let ext = member.fileExtension
                let newName = ext.isEmpty ? stem : stem + "." + ext
                if let issue = validate(name: newName) {
                    unitIssue = issue
                    break
                }
                let toParent = rule.destinationFolder ?? member.parentRelativePath
                let toRelative = toParent.isEmpty ? newName : toParent + "/" + newName
                unitMoves.append(RenameMove(
                    mediaID: member.mediaID, sourceID: member.sourceID,
                    fromRelativePath: member.relativePath, toRelativePath: toRelative,
                    fromName: member.name, toName: newName,
                    fromParent: member.parentRelativePath, toParent: toParent
                ))
            }
            if let unitIssue {
                for member in unit { plan.skipped[member.mediaID] = unitIssue }
                continue
            }

            let unchanged = unitMoves.allSatisfy { move in
                move.fromRelativePath == move.toRelativePath
            }
            if unchanged {
                plan.unchanged += 1
                for member in unit { plan.skipped[member.mediaID] = .unchanged }
                continue
            }
            let warning = primary.hasFileIdentity ? nil
                : "This volume reports no file identity; a crash mid-rename could cost the row its favorites."
            candidates.append((unit, unitMoves, warning))
        }

        // Two passes: a duplicate target or an occupied name removes a unit, and removing it can un-vacate a
        // name that another unit wanted. Three passes is enough for any realistic plan and bounds the loop.
        for _ in 0..<3 {
            let collisions = collisions(in: candidates, existingNames: existingNames)
            guard !collisions.isEmpty else { break }
            for index in collisions.sorted(by: >) {
                let unit = candidates[index].unit
                let name = candidates[index].moves.first?.toName ?? ""
                for member in unit { plan.skipped[member.mediaID] = .collision(name) }
                candidates.remove(at: index)
            }
        }

        for candidate in candidates {
            plan.moves += candidate.moves
            plan.groups.append(candidate.unit.map(\.mediaID))
            if let warning = candidate.warning {
                for member in candidate.unit { plan.warnings[member.mediaID] = warning }
            }
            plan.companionCount += candidate.unit.filter(\.isLivePhotoCompanion).count
        }

        plan.preview = preview(of: plan, subjects: subjects)
        return plan
    }

    // MARK: - Naming

    private static func transformed(
        _ stem: String, rule: RenameRule, captureDate: Date?, ordinal: Int, formatter: DateFormatter
    ) -> String {
        var result = stem
        if !rule.find.isEmpty {
            result = result.replacingOccurrences(
                of: rule.find, with: rule.replace,
                options: rule.caseSensitive ? [] : [.caseInsensitive]
            )
        }
        result = rule.prefix + result + rule.suffix
        if rule.usesCaptureDate {
            formatter.dateFormat = rule.datePattern
            let stamp = captureDate.map { formatter.string(from: $0) } ?? rule.dateFallback
            result = stamp + "-" + result
        }
        if let sequence = rule.sequence {
            let number = sequence.number(ordinal)
            switch sequence.placement {
            case .replace:
                result = number
            case .prefix:
                result = number + sequence.separator + result
            case .suffix:
                result = result + sequence.separator + number
            }
        }
        return result
    }

    private static func validate(stem: String) -> RenameIssue? {
        if stem.isEmpty || stem.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
        if stem.hasPrefix(".") { return .leadingDot }
        if stem.hasSuffix(" ") || stem.hasSuffix(".") { return .trailingCharacter }
        if let issue = illegalCharacterIssue(stem) { return issue }
        return nil
    }

    private static func validate(name: String) -> RenameIssue? {
        if name.isEmpty { return .empty }
        if name.lengthOfBytes(using: .utf8) > 250 {
            return .tooLong(bytes: name.lengthOfBytes(using: .utf8))
        }
        if name.hasPrefix(".") { return .leadingDot }
        if name.hasSuffix(" ") || name.hasSuffix(".") { return .trailingCharacter }
        let lowered = name.lowercased()
        if lowered == ".ds_store" || lowered.hasPrefix(".gr-") || lowered.hasPrefix(".gallery-") {
            return .reservedName
        }
        if let issue = illegalCharacterIssue(name) { return issue }
        return nil
    }

    private static func illegalCharacterIssue(_ name: String) -> RenameIssue? {
        for scalar in name.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar.value < 0x20 || scalar.value == 0x7F {
                return .illegalCharacters
            }
        }
        return nil
    }

    // MARK: - Collisions

    /// Indices of units whose destination is claimed twice or is occupied by a file this plan is not moving
    /// away from. Case- and normalization-insensitive: the boot volume is.
    private static func collisions(
        in candidates: [(unit: [RenameSubject], moves: [RenameMove], warning: String?)],
        existingNames: [String: Set<String>]
    ) -> [Int] {
        var byTarget: [String: Int] = [:]
        var duplicates: Set<Int> = []
        for (index, candidate) in candidates.enumerated() {
            for move in candidate.moves {
                let key = folded(move.toParent + "/" + move.toName)
                if let first = byTarget[key] {
                    duplicates.insert(max(first, index))
                } else {
                    byTarget[key] = index
                }
            }
        }

        // Names this plan vacates, per parent. A swap or a chain is legal because every from-name counts as
        // free; a unit that is skipped later un-vacates its from-name, which the outer loop re-checks.
        var vacated: [String: Set<String>] = [:]
        for candidate in candidates {
            for move in candidate.moves {
                vacated[move.fromParent, default: []].insert(folded(move.fromName))
            }
        }
        let foldedExisting = existingNames.mapValues { Set($0.map(folded)) }

        var colliding = duplicates
        for (index, candidate) in candidates.enumerated() {
            for move in candidate.moves {
                let target = folded(move.toName)
                guard let names = foldedExisting[move.toParent], names.contains(target) else { continue }
                if vacated[move.fromParent]?.contains(target) != true { colliding.insert(index) }
            }
        }
        return Array(colliding)
    }

    static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - Groups and preview

    /// Subjects sharing a group key are one unit (a Live Photo still and its companion); everything else is
    /// a unit of one, in the caller's order.
    private static func group(_ subjects: [RenameSubject]) -> [[RenameSubject]] {
        var units: [[RenameSubject]] = []
        var indexByKey: [String: Int] = [:]
        for subject in subjects {
            if let key = subject.groupKey, let index = indexByKey[key] {
                units[index].append(subject)
            } else {
                if let key = subject.groupKey { indexByKey[key] = units.count }
                units.append([subject])
            }
        }
        return units
    }

    private static func preview(of plan: RenamePlan, subjects: [RenameSubject]) -> [RenamePreviewRow] {
        var rows: [RenamePreviewRow] = plan.moves.prefix(20).map {
            RenamePreviewRow(id: $0.mediaID, fromName: $0.fromName, toName: $0.toName)
        }
        if rows.count < 20 {
            let names = Dictionary(subjects.map { ($0.mediaID, $0.name) }, uniquingKeysWith: { first, _ in first })
            let skippedRows = plan.skipped
                .filter { $0.value != .unchanged }
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .prefix(20 - rows.count)
                .map {
                    RenamePreviewRow(
                        id: $0.key, fromName: names[$0.key] ?? "", toName: "",
                        issue: $0.value.message
                    )
                }
            rows += skippedRows
        }
        return rows
    }
}
