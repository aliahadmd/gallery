import SwiftUI
import GalleryDomain

/// Find & replace, affixes, a capture-date prefix and numbering — with a live preview of every name and
/// every conflict. Nothing moves until Apply, and the plan is what the filesystem will be asked to do.
struct RenameSheet: View {
    let model: MediaLibraryModel
    let session: RenameSession

    @State private var find = ""
    @State private var replace = ""
    @State private var caseSensitive = false
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var usesDate = false
    @State private var datePattern = "yyyy-MM-dd"
    @State private var numbered = false
    @State private var start = 1
    @State private var step = 1
    @State private var padding = 3
    @State private var placement: RenameRule.Sequence.Placement = .suffix
    @State private var separator = "-"
    @State private var isApplying = false

    init(model: MediaLibraryModel, session: RenameSession) {
        self.model = model
        self.session = session
        let rule = session.rule
        _find = State(initialValue: rule.find)
        _replace = State(initialValue: rule.replace)
        _caseSensitive = State(initialValue: rule.caseSensitive)
        _prefix = State(initialValue: rule.prefix)
        _suffix = State(initialValue: rule.suffix)
        _usesDate = State(initialValue: rule.usesCaptureDate)
        _datePattern = State(initialValue: rule.datePattern)
        _numbered = State(initialValue: rule.sequence != nil)
        _start = State(initialValue: rule.sequence?.start ?? 1)
        _step = State(initialValue: rule.sequence?.step ?? 1)
        _padding = State(initialValue: rule.sequence?.padding ?? 3)
        _placement = State(initialValue: rule.sequence?.placement ?? .suffix)
        _separator = State(initialValue: rule.sequence?.separator ?? "-")
    }

    private var draft: RenameRule {
        RenameRule(
            find: find, replace: replace, caseSensitive: caseSensitive,
            prefix: prefix, suffix: suffix,
            usesCaptureDate: usesDate, datePattern: datePattern,
            sequence: numbered
                ? .init(start: start, step: step, padding: padding, placement: placement, separator: separator)
                : nil,
            destinationFolder: session.destinationFolder
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(session.title).font(.title3.weight(.semibold))
                Spacer()
                if session.isMove, let destination = session.destinationFolder {
                    Label("To \(destination.isEmpty ? "the library root" : destination)", systemImage: "folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    label("Find")
                    HStack(spacing: 8) {
                        TextField("", text: $find).textFieldStyle(.roundedBorder).frame(width: 150)
                        Toggle("Match case", isOn: $caseSensitive).toggleStyle(.checkbox)
                    }
                }
                GridRow {
                    label("Replace")
                    TextField("", text: $replace).textFieldStyle(.roundedBorder).frame(width: 220)
                }
                GridRow {
                    label("Add")
                    HStack(spacing: 8) {
                        TextField("Prefix", text: $prefix).textFieldStyle(.roundedBorder).frame(width: 100)
                        TextField("Suffix", text: $suffix).textFieldStyle(.roundedBorder).frame(width: 100)
                        Toggle("Capture date", isOn: $usesDate).toggleStyle(.checkbox)
                        TextField("yyyy-MM-dd", text: $datePattern)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 96)
                            .disabled(!usesDate)
                    }
                }
                GridRow {
                    label("Number")
                    HStack(spacing: 8) {
                        Toggle("Number the files", isOn: $numbered).toggleStyle(.checkbox)
                        Stepper("Start \(start)", value: $start, in: 0...999_999).disabled(!numbered)
                        Stepper("Step \(step)", value: $step, in: 1...1_000).disabled(!numbered)
                        Stepper("Digits \(padding)", value: $padding, in: 1...8).disabled(!numbered)
                        Picker("", selection: $placement) {
                            Text("Prefix").tag(RenameRule.Sequence.Placement.prefix)
                            Text("Suffix").tag(RenameRule.Sequence.Placement.suffix)
                            Text("Only").tag(RenameRule.Sequence.Placement.replace)
                        }
                        .labelsHidden()
                        .frame(width: 86)
                        .disabled(!numbered)
                    }
                }
            }

            preview

            HStack(spacing: 12) {
                if !session.plan.warnings.isEmpty {
                    Label("\(session.plan.warnings.count) files on a volume without file identity",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if session.plan.overLimit {
                    Text("Too many items (limit \(RenamePlanBuilder.maximumSubjects)). Narrow the selection.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { model.closeRename() }
                Button {
                    Task {
                        isApplying = true
                        await model.applyRename(session)
                        isApplying = false
                    }
                } label: {
                    if isApplying {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(session.isMove ? "Move" : "Rename")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.plan.isEmpty || session.plan.overLimit || isApplying)
            }
        }
        .padding(18)
        .frame(minWidth: 620, minHeight: 520)
        .onChange(of: draft) { _, new in session.setRule(new) }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Preview").font(.headline)
                Spacer()
                Text("\(session.plan.movedCount) to change · \(session.plan.skipped.count) skipped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            List(session.plan.preview) { row in
                HStack(spacing: 8) {
                    if let issue = row.issue {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(row.fromName).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(issue).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Text(row.fromName).lineLimit(1).truncationMode(.middle)
                        Text("→").foregroundStyle(.tertiary)
                        Text(row.toName).lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                }
                .font(.callout)
            }
            .listStyle(.inset)
            .frame(minHeight: 220)
        }
    }
}
