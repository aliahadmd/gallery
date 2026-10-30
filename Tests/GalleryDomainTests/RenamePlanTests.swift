import Foundation
import Testing
@testable import GalleryDomain

private let utc = TimeZone(secondsFromGMT: 0)!

private func subject(
    _ name: String, parent: String = "", id: Int64? = nil,
    date: Date? = nil, group: String? = nil,
    still: Bool = false, companion: Bool = false,
    identity: Bool = true, offline: Bool = false, trashed: Bool = false
) -> RenameSubject {
    RenameSubject(
        mediaID: MediaID(rawValue: id ?? 1), sourceID: SourceID(rawValue: 1),
        relativePath: parent.isEmpty ? name : parent + "/" + name,
        parentRelativePath: parent, name: name, captureDate: date,
        isLivePhotoStill: still, isLivePhotoCompanion: companion, groupKey: group,
        hasFileIdentity: identity, isOffline: offline, inTrash: trashed
    )
}

private func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}

@Test func findReplacePrefixAndSuffix() {
    let rule = RenameRule(find: "IMG_", replace: "Kyoto-")
    let plan = RenamePlanBuilder.plan(rule, subjects: [subject("IMG_1234.JPG")], existingNames: [:], timeZone: utc)
    #expect(plan.moves.count == 1)
    #expect(plan.moves[0].toName == "Kyoto-1234.JPG")
    #expect(plan.moves[0].toRelativePath == "Kyoto-1234.JPG")

    let insensitive = RenamePlanBuilder.plan(
        RenameRule(find: "img_", replace: "x-"),
        subjects: [subject("IMG_1.jpg")], existingNames: [:], timeZone: utc
    )
    #expect(insensitive.moves.first?.toName == "x-1.jpg")

    let sensitive = RenamePlanBuilder.plan(
        RenameRule(find: "img_", replace: "x-", caseSensitive: true),
        subjects: [subject("IMG_1.jpg")], existingNames: [:], timeZone: utc
    )
    #expect(sensitive.unchanged == 1)
    #expect(sensitive.moves.isEmpty)

    let affixes = RenamePlanBuilder.plan(
        RenameRule(prefix: "Trip-", suffix: "-final"),
        subjects: [subject("a.jpg")], existingNames: [:], timeZone: utc
    )
    #expect(affixes.moves.first?.toName == "Trip-a-final.jpg")
}

@Test func sequenceNumbersAreAssignedInGridOrder() {
    let subjects = [subject("a.jpg", id: 1), subject("b.jpg", id: 2), subject("c.jpg", id: 3)]
    let rule = RenameRule(sequence: .init(start: 5, step: 10, padding: 3, placement: .suffix))
    let plan = RenamePlanBuilder.plan(rule, subjects: subjects, existingNames: [:], timeZone: utc)
    #expect(plan.moves.map(\.toName) == ["a-005.jpg", "b-015.jpg", "c-025.jpg"])

    let replace = RenamePlanBuilder.plan(
        RenameRule(sequence: .init(start: 1, step: 1, padding: 2, placement: .replace)),
        subjects: subjects, existingNames: [:], timeZone: utc
    )
    #expect(replace.moves.map(\.toName) == ["01.jpg", "02.jpg", "03.jpg"])

    let prefix = RenamePlanBuilder.plan(
        RenameRule(sequence: .init(start: 1, step: 1, padding: 2, placement: .prefix, separator: "_")),
        subjects: [subject("a.jpg")], existingNames: [:], timeZone: utc
    )
    #expect(prefix.moves.first?.toName == "01_a.jpg")
}

@Test func dateTokenFallsBackWhenThereIsNoCaptureDate() {
    let dated = subject("a.jpg", date: makeDate(2026, 10, 29))
    let rule = RenameRule(usesCaptureDate: true)
    let plan = RenamePlanBuilder.plan(rule, subjects: [dated], existingNames: [:], timeZone: utc)
    #expect(plan.moves.first?.toName == "2026-10-29-a.jpg")

    let undated = subject("b.jpg", id: 2)
    let fallback = RenamePlanBuilder.plan(rule, subjects: [undated], existingNames: [:], timeZone: utc)
    #expect(fallback.moves.first?.toName == "undated-b.jpg")

    let compact = RenamePlanBuilder.plan(
        RenameRule(usesCaptureDate: true, datePattern: "yyyyMMdd"),
        subjects: [dated], existingNames: [:], timeZone: utc
    )
    #expect(compact.moves.first?.toName == "20261029-a.jpg")
}

@Test func theExtensionIsPreservedVerbatim() {
    let plan = RenamePlanBuilder.plan(
        RenameRule(prefix: "x-"),
        subjects: [subject("IMG_1.HEIC", id: 1), subject("clip.MOV", id: 2), subject("noext", id: 3)],
        existingNames: [:], timeZone: utc
    )
    #expect(plan.moves.map(\.toName) == ["x-IMG_1.HEIC", "x-clip.MOV", "x-noext"])
}

@Test func aLivePhotoGroupSharesOneStemAndOneNumber() {
    let still = subject("IMG_1.HEIC", id: 1, group: "live:1", still: true)
    let companion = subject("IMG_1.MOV", id: 2, group: "live:1", companion: true)
    let plan = RenamePlanBuilder.plan(
        RenameRule(prefix: "Trip-", sequence: .init(start: 1, step: 1, padding: 2, placement: .suffix)),
        subjects: [still, companion], existingNames: [:], timeZone: utc
    )
    #expect(plan.moves.count == 2)
    #expect(plan.moves.map(\.toName).sorted() == ["Trip-IMG_1-01.HEIC", "Trip-IMG_1-01.MOV"])
    #expect(plan.companionCount == 1)
    #expect(plan.groups == [[MediaID(rawValue: 1), MediaID(rawValue: 2)]])
    #expect(Set(plan.moves.map { ($0.toName as NSString).deletingPathExtension }).count == 1,
            "both halves share the stem, so a rescan re-pairs them")
}

@Test func invalidNamesAreSkippedWithAReason() {
    let cases: [(RenameRule, RenameIssue)] = [
        (RenameRule(find: "a", replace: ""), .empty),
        (RenameRule(find: "a", replace: "   "), .empty),
        (RenameRule(find: "a", replace: "x/y"), .illegalCharacters),
        (RenameRule(find: "a", replace: "x:y"), .illegalCharacters),
        (RenameRule(prefix: "."), .leadingDot),
        (RenameRule(suffix: " "), .trailingCharacter),
        (RenameRule(prefix: ".gr-"), .leadingDot),
    ]
    for (rule, issue) in cases {
        let plan = RenamePlanBuilder.plan(
            rule, subjects: [subject("a.jpg", id: 1)], existingNames: [:], timeZone: utc
        )
        #expect(plan.moves.isEmpty)
        #expect(plan.skipped[MediaID(rawValue: 1)] == issue, "\(rule) should be \(issue)")
    }

    let long = RenamePlanBuilder.plan(
        RenameRule(prefix: String(repeating: "x", count: 260)),
        subjects: [subject("a.jpg", id: 1)], existingNames: [:], timeZone: utc
    )
    guard case .tooLong(let bytes)? = long.skipped[MediaID(rawValue: 1)] else {
        Issue.record("a 260-character prefix should be refused for length")
        return
    }
    #expect(bytes > 250)
}

@Test func collisionsWithTwoTargetsAndWithOnDiskNames() {
    let subjects = [subject("a.jpg", id: 1), subject("b.jpg", id: 2)]
    let duplicate = RenamePlanBuilder.plan(
        RenameRule(sequence: .init(start: 7, step: 0, padding: 3, placement: .replace)),
        subjects: subjects, existingNames: [:], timeZone: utc
    )
    #expect(duplicate.moves.count == 1)
    #expect(duplicate.skipped[MediaID(rawValue: 2)] == .collision("007.jpg"))

    let occupied = RenamePlanBuilder.plan(
        RenameRule(find: "a", replace: "b"),
        subjects: [subject("a.jpg", id: 1)],
        existingNames: ["": ["b.jpg"]], timeZone: utc
    )
    #expect(occupied.moves.isEmpty)
    #expect(occupied.skipped[MediaID(rawValue: 1)] == .collision("b.jpg"))
}

@Test func aChainOfRenamesIsNotACollision() {
    let subjects = [subject("1.jpg", id: 1), subject("2.jpg", id: 2), subject("3.jpg", id: 3)]
    let plan = RenamePlanBuilder.plan(
        RenameRule(sequence: .init(start: 2, step: 1, padding: 1, placement: .replace)),
        subjects: subjects, existingNames: ["": ["1.jpg", "2.jpg", "3.jpg"]], timeZone: utc
    )
    #expect(plan.moves.map(\.toName) == ["2.jpg", "3.jpg", "4.jpg"],
            "the names being vacated are free; the executor stages the cycle")
}

@Test func movingIntoASubfolderUsesThatFoldersNames() {
    let rule = RenameRule(prefix: "x-", destinationFolder: "Sorted")
    let plan = RenamePlanBuilder.plan(
        rule, subjects: [subject("a.jpg")], existingNames: ["Sorted": ["x-b.jpg"]], timeZone: utc
    )
    #expect(plan.moves.first?.toRelativePath == "Sorted/x-a.jpg")

    let collision = RenamePlanBuilder.plan(
        rule, subjects: [subject("b.jpg")], existingNames: ["Sorted": ["x-b.jpg"]], timeZone: utc
    )
    #expect(collision.moves.isEmpty)
    #expect(collision.skipped[MediaID(rawValue: 1)] == .collision("x-b.jpg"))
}

@Test func offlineTrashedAndUnchangedAreCounted() {
    let plan = RenamePlanBuilder.plan(
        RenameRule(prefix: "x-"),
        subjects: [
            subject("off.jpg", id: 1, offline: true),
            subject("trash.jpg", id: 2, trashed: true),
            subject("same.jpg", id: 3),
        ],
        existingNames: [:], timeZone: utc
    )
    #expect(plan.skipped[MediaID(rawValue: 1)] == .offline)
    #expect(plan.skipped[MediaID(rawValue: 2)] == .trashed)
    #expect(plan.moves.map(\.mediaID) == [MediaID(rawValue: 3)])

    let unchanged = RenamePlanBuilder.plan(
        RenameRule(find: "same", replace: "same"),
        subjects: [subject("same.jpg", id: 3)], existingNames: [:], timeZone: utc
    )
    #expect(unchanged.unchanged == 1)
    #expect(unchanged.moves.isEmpty)
}

@Test func aPathKeyedFileGetsAWarningNotARefusal() {
    let plan = RenamePlanBuilder.plan(
        RenameRule(prefix: "x-"),
        subjects: [subject("a.jpg", identity: false)], existingNames: [:], timeZone: utc
    )
    #expect(plan.moves.count == 1)
    #expect(plan.warnings[MediaID(rawValue: 1)] != nil)
}

@Test func aHugeSelectionIsRefusedRatherThanPlanned() {
    let subjects = (0..<12).map { subject("f\($0).jpg", id: Int64($0 + 1)) }
    let plan = RenamePlanBuilder.plan(
        RenameRule(prefix: "x-"), subjects: subjects, existingNames: [:], maximumSubjects: 10, timeZone: utc
    )
    #expect(plan.overLimit)
    #expect(plan.moves.isEmpty)
}

@Test func thePreviewShowsMovesThenSkips() {
    let plan = RenamePlanBuilder.plan(
        RenameRule(prefix: "x-"),
        subjects: [subject("a.jpg", id: 1), subject("b.jpg", id: 2, offline: true)],
        existingNames: [:], timeZone: utc
    )
    #expect(plan.preview.first?.toName == "x-a.jpg")
    #expect(plan.preview.contains { $0.issue != nil })
}

@Test func aDestinationTheWalkerSkipsIsRefusedBeforeAFileMoves() {
    #expect(RenameRule.destinationProblem("../outside") == .parentTraversal)
    #expect(RenameRule.destinationProblem("/absolute") == .absolute)
    #expect(RenameRule.destinationProblem(".hidden") == .hiddenComponent(".hidden"))
    #expect(RenameRule.destinationProblem("node_modules") == .reservedComponent("node_modules"))
    #expect(RenameRule.destinationProblem("Holiday/2026") == nil)
    #expect(RenameRule.destinationProblem("") == nil)

    let plan = RenamePlanBuilder.plan(
        RenameRule(destinationFolder: "../outside"),
        subjects: [subject("a.jpg", id: 1)], existingNames: [:], timeZone: utc
    )
    #expect(plan.moves.isEmpty)
    #expect(plan.skipped[MediaID(rawValue: 1)]?.message.contains("climb") == true)
}
