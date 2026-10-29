import Foundation
import Observation
import GalleryDomain

/// The rename sheet's state: the subjects, the folder's current names, and the rule being previewed.
/// Recomputing the plan is pure, so every keystroke can show exactly what Apply would do.
@MainActor
@Observable
public final class RenameSession {
    public let subjects: [RenameSubject]
    public let existingNames: [String: Set<String>]
    public private(set) var rule: RenameRule
    public private(set) var plan: RenamePlan
    public let destinationFolder: String?

    public init(subjects: [RenameSubject], existingNames: [String: Set<String>], rule: RenameRule) {
        self.subjects = subjects
        self.existingNames = existingNames
        self.rule = rule
        self.destinationFolder = rule.destinationFolder
        self.plan = RenamePlanBuilder.plan(rule, subjects: subjects, existingNames: existingNames)
    }

    public var isMove: Bool { destinationFolder != nil }

    public func setRule(_ rule: RenameRule) {
        guard rule != self.rule else { return }
        self.rule = rule
        plan = RenamePlanBuilder.plan(rule, subjects: subjects, existingNames: existingNames)
    }

    public var title: String {
        if isMove {
            return plan.movedCount == 1 ? "Move one photo" : "Move \(plan.movedCount) photos"
        }
        return plan.movedCount == 1 ? "Rename one photo" : "Rename \(plan.movedCount) photos"
    }
}
