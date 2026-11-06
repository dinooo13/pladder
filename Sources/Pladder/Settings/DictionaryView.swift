import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PladderCore

private struct DictionaryCell: Hashable {
    enum Column: Hashable { case from, to }
    var id: DictionaryEntry.ID
    var column: Column
}

struct DictionaryView: View {
    @Bindable var model: AppModel

    @State private var selection = Set<DictionaryEntry.ID>()
    @State private var sample = ""
    @State private var failure: FileFailure?
    @FocusState private var focusedCell: DictionaryCell?

    private var entries: [DictionaryEntry] { model.settings.dictionary }

    // Recomputed on every redraw, so a rule that closes a cycle shows at once; cheap,
    // and nowhere near the release path.
    private var cyclicIDs: Set<DictionaryEntry.ID> { DictionaryEntry.cyclicIDs(in: entries) }

    var body: some View {
        Form {
            Section {
                // No table while it is empty: its header and the empty state would collide.
                if entries.isEmpty {
                    emptyState
                } else {
                    table
                }
                if !entries.isEmpty {
                    toolbar
                    testArea
                }
            } footer: {
                if !cyclicIDs.isEmpty {
                    WarningLabel(String(localized: "Two rules undo each other, so both are ignored."))
                }
            }
        }
        .formStyle(.grouped)
        .alert(
            failure?.title ?? "",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK") { failure = nil }
        } message: { failure in
            Text(failure.message)
        }
    }

    // MARK: Table

    private var table: some View {
        Table($model.settings.dictionary, selection: $selection) {
            TableColumn("Heard as") { row in
                HStack(spacing: 4) {
                    if cyclicIDs.contains(row.wrappedValue.id) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .help("This rule undoes another one, so it is ignored.")
                    }
                    DictionaryField(
                        text: row.from,
                        help: "Leave empty to fix near misses of the replacement, such as a name that comes out nearly right.",
                        prompt: "optional",
                        cell: DictionaryCell(id: row.wrappedValue.id, column: .from),
                        focus: $focusedCell
                    )
                    .accessibilityLabel("Heard as")
                }
            }
            .width(min: 120, ideal: 170)

            TableColumn("Replace with") { row in
                DictionaryField(
                    text: row.to,
                    help: "What is pasted instead.",
                    prompt: "Claude",
                    cell: DictionaryCell(id: row.wrappedValue.id, column: .to),
                    focus: $focusedCell
                )
                .accessibilityLabel("Replace with")
            }
            .width(min: 120, ideal: 170)

            TableColumn("Exact case") { row in
                Toggle("Exact case", isOn: row.matchCase)
                    .labelsHidden()
                    .help("Paste the replacement exactly as written, even at the start of a sentence.")
                    .frame(maxWidth: .infinity)
            }
            .width(76)
        }
        .alternatingRowBackgrounds(.disabled)
        .frame(minHeight: 220)
        .onDeleteCommand(perform: removeSelected)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Words Yet", systemImage: "character.book.closed")
        } description: {
            Text("Add a word Pladder keeps mishearing and what it should be, or a name it should learn.")
        } actions: {
            Button("Add Word", action: addEntry)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    // MARK: Toolbar

    // The macOS list layout: add and remove at the leading edge, the rest in a menu.
    private var toolbar: some View {
        HStack(spacing: 4) {
            Button(action: addEntry) {
                Image(systemName: "plus")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help("Add a rule")
            .accessibilityLabel("Add a rule")

            Button(action: removeSelected) {
                Image(systemName: "minus")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(selection.isEmpty)
            .help("Remove the selected rules")
            .accessibilityLabel("Remove the selected rules")

            Spacer()

            Menu {
                Button("Import…", action: importEntries)
                Button("Export…", action: exportEntries)
                    .disabled(entries.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 16, height: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Import or export the dictionary")
            .accessibilityLabel("More")
        }
        .controlSize(.small)
    }

    // MARK: Test field

    private var testArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $sample, prompt: Text("Type a sentence to see how the rules change it"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            if !sample.isEmpty {
                Label {
                    Text(testResult)
                        .textSelection(.enabled)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pasted as")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // The same two processors the pipeline runs, in its order, so this cannot drift.
    private var testResult: String {
        let replaced = DictionaryReplacer(entries: entries).apply(to: sample)
        return CustomWordCorrector(entries: entries).apply(to: replaced)
    }

    // MARK: Editing

    private func addEntry() {
        let entry = DictionaryEntry(from: "", to: "")
        model.settings.dictionary.append(entry)
        selection = [entry.id]
        // The row is not in the view tree until the next update, so focus waits a turn.
        Task { focusedCell = DictionaryCell(id: entry.id, column: .from) }
    }

    private func removeSelected() {
        guard !selection.isEmpty else { return }
        focusedCell = nil
        model.settings.dictionary.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    // MARK: Import and export

    private func importEntries() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            merge(try JSONDecoder().decode([DictionaryEntry].self, from: data))
        } catch {
            failure = FileFailure(
                title: String(localized: "Couldn’t Import the Dictionary"),
                message: String(localized: "The file should be a dictionary exported from Pladder."))
        }
    }

    private func exportEntries() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Pladder Dictionary.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: url, options: .atomic)
        } catch {
            failure = FileFailure(
                title: String(localized: "Couldn’t Export the Dictionary"),
                message: error.localizedDescription)
        }
    }

    private func merge(_ incoming: [DictionaryEntry]) {
        model.settings.dictionary.merge(incoming)
    }
}

private struct FileFailure {
    let title: String
    let message: String
}

// Edits a draft and writes back on submit or focus loss, so typing does not save
// the settings on every keystroke.
private struct DictionaryField: View {
    @Binding var text: String
    let help: LocalizedStringKey
    let prompt: LocalizedStringKey
    let cell: DictionaryCell
    var focus: FocusState<DictionaryCell?>.Binding

    @State private var draft = ""

    var body: some View {
        // Inside a grouped Form a TextField's title renders as a label.
        TextField("", text: $draft, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.plain)
            .focused(focus, equals: cell)
            .help(help)
            .onAppear { draft = text }
            .onSubmit { commit() }
            .onChange(of: text) { _, new in
                // An import or a reset elsewhere; adopted unless the user is editing this very cell.
                if focus.wrappedValue != cell { draft = new }
            }
            .onChange(of: focus.wrappedValue) { old, new in
                if old == cell, new != cell { commit() }
            }
    }

    private func commit() {
        guard draft != text else { return }
        text = draft
    }
}
