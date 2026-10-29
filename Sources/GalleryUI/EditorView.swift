import SwiftUI
import AppKit

/// How the editor asks for a destination. The panel is AppKit and lives in the executable target, so the
/// library only needs to know that the user chose where the copy goes.
public typealias EditorExportAction = @MainActor (EditingSession) async -> Void

/// The editing surface: the photo over the grid, its tools beside it, and two buttons that say exactly what
/// they will do. Export is the prominent one because the default must never be the destructive one.
public struct EditorView: View {
    private let model: MediaLibraryModel
    private let session: EditingSession
    private let exportCopy: EditorExportAction?

    @FocusState private var isFocused: Bool
    @State private var isConfirmingReplace = false

    public init(
        model: MediaLibraryModel,
        session: EditingSession,
        exportCopy: EditorExportAction? = nil
    ) {
        self.model = model
        self.session = session
        self.exportCopy = exportCopy
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                EditorCanvas(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                EditorSidebar(session: session, applyMetadata: { overrides in
                    await model.applyMetadata(overrides, to: [session.source.mediaID])
                })
                .frame(width: 272)
            }
            Divider()
            bottomBar
        }
        .background(.background)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .onKeyPress(.escape) {
            model.closeEditor()
            return .handled
        }
        .onKeyPress(KeyEquivalent("z")) {
            guard NSEvent.modifierFlags.contains(.command) else { return .ignored }
            session.undo()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            session.rotate(clockwise: false)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            session.rotate(clockwise: true)
            return .handled
        }
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { model.closeEditor() } label: {
                Image(systemName: "xmark.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .help("Close the editor (Esc)")

            VStack(alignment: .leading, spacing: 1) {
                Text(session.source.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.statusText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button { session.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!session.canUndo)
            .help("Undo the last edit (⌘Z)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text("Export writes a new file. Replace is explicit and keeps a previous version.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if session.backupDate != nil {
                Button("Revert to Previous Version") {
                    Task { await model.revertEditorOriginal() }
                }
                .controlSize(.small)
                .help("Restore the version kept before the last Replace")
            }
            Button("Cancel") { model.closeEditor() }
            Button("Replace Original…") { isConfirmingReplace = true }
                .buttonStyle(.bordered)
                .disabled(session.plan == nil || !session.isReplaceEligible)
                .help(session.isReplaceEligible
                      ? "Write the edit over the file in your folder, keeping a backup"
                      : "Replace keeps the file's type; use Export a Copy to convert")
            Button("Export a Copy…") {
                Task { await exportCopy?(session) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(session.plan == nil || exportCopy == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .alert("Replace the original?", isPresented: $isConfirmingReplace) {
            Button("Replace Original", role: .destructive) {
                Task { await model.replaceEditorOriginal() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The edit is written over \(session.source.name) in your folder. A previous version is kept inside Gallery for 30 days and can be restored with Revert to Previous Version.")
        }
    }
}
