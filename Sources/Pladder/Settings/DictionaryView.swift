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
    @State private var sample = "i tried clode in claude code today"
    @State private var errorMessage: String?
    @FocusState private var focusedCell: DictionaryCell?

    private var entries: [DictionaryEntry] { model.settings.dictionary }

    // Recomputed on every redraw, so a rule that closes a cycle shows at once; cheap,
    // and nowhere near the release path.
    private var cyclicIDs: Set<DictionaryEntry.ID> { DictionaryEntry.cyclicIDs(in: entries) }

    var body: some View {
        Form {
            Section {
                table
                toolbar
            } header: {
                Text("Rules")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    FootnoteText("Whole words only. Longer phrases win. Case is carried over at the start of a sentence unless Match case is on.")
                    FootnoteText("Leave Heard as empty to list a word that should be repaired when it comes out nearly right.")
                    if !cyclicIDs.isEmpty {
                        FootnoteText("⚠️ \u{201c}a\u{201d} → \u{201c}b\u{201d} and \u{201c}b\u{201d} → \u{201c}a\u{201d} undo each other; these rules are ignored.")
                    }
                }
            }

            Section("Try a sentence") {
                testArea
            }
        }
        .formStyle(.grouped)
        .alert(
            "Dictionary",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Table

    private var table: some View {
        Table($model.settings.dictionary, selection: $selection) {
            TableColumn("Heard as") { row in
                HStack(spacing: 4) {
                    if cyclicIDs.contains(row.wrappedValue.id) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("This rule undoes another one, so it is ignored.")
                    }
                    DictionaryField(
                        text: row.from,
                        prompt: "spoken form",
                        cell: DictionaryCell(id: row.wrappedValue.id, column: .from),
                        focus: $focusedCell
                    )
                }
            }
            .width(min: 120, ideal: 170)

            TableColumn("Replace with") { row in
                DictionaryField(
                    text: row.to,
                    prompt: "replacement",
                    cell: DictionaryCell(id: row.wrappedValue.id, column: .to),
                    focus: $focusedCell
                )
            }
            .width(min: 120, ideal: 170)

            TableColumn("Match case") { row in
                Toggle("Match case", isOn: row.matchCase)
                    .labelsHidden()
            }
            .width(76)
        }
        // An empty table otherwise paints striped placeholder rows, which reads as broken.
        .alternatingRowBackgrounds(.disabled)
        .frame(minHeight: 220)
        .onDeleteCommand(perform: removeSelected)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            if entries.isEmpty {
                Button("Add examples", action: addExamples)
                    .buttonStyle(.link)
            }

            Spacer()

            Button("Import…", action: importEntries)
            Button("Export…", action: exportEntries)
                .disabled(entries.isEmpty)

            Button(action: addEntry) {
                Image(systemName: "plus")
            }
            .help("Add a rule")

            Button(action: removeSelected) {
                Image(systemName: "minus")
            }
            .disabled(selection.isEmpty)
            .help("Remove the selected rules")
        }
        .controlSize(.small)
    }

    // MARK: Test field

    private var testArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $sample, prompt: Text("Type a sentence to see how the rules change it"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            Text(testResult.isEmpty ? "—" : testResult)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private func addExamples() {
        merge([
            DictionaryEntry(from: "claude code", to: "Claude Code"),
            DictionaryEntry(from: "clode", to: "Claude"),
            DictionaryEntry(from: "speak up", to: "Pladder"),
            DictionaryEntry(from: "", to: "ChatGPT"),
        ])
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
            errorMessage = String(localized: "Could not read that file. It should be a JSON array of { from, to, matchCase }.")
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
            errorMessage = String(localized: "Could not write that file: \(error.localizedDescription)")
        }
    }

    private func merge(_ incoming: [DictionaryEntry]) {
        model.settings.dictionary.merge(incoming)
    }
}

// Edits a draft and writes back on submit or focus loss, so typing does not save
// the settings on every keystroke.
private struct DictionaryField: View {
    @Binding var text: String
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
