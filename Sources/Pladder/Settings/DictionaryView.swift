import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PladderCore

/// Identifies one editable text cell, so the toolbar can move focus into a row
/// it just created and each field knows when it lost focus.
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

    /// Recomputed from the current entries whenever the table redraws, so
    /// typing a new rule that closes a cycle is reflected without any extra
    /// wiring. Cheap: the dictionary is small and this is not on the
    /// release-to-paste path.
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
        // Without this an empty table paints a stack of striped placeholder
        // rows, which reads as broken when the dictionary is empty.
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

    /// Runs the same two processors the pipeline runs, in the same order, so
    /// the preview cannot drift from the real behaviour.
    private var testResult: String {
        let replaced = DictionaryReplacer(entries: entries).apply(to: sample)
        return CustomWordCorrector(entries: entries).apply(to: replaced)
    }

    // MARK: Editing

    private func addEntry() {
        let entry = DictionaryEntry(from: "", to: "")
        model.settings.dictionary.append(entry)
        selection = [entry.id]
        // The row does not exist in the view tree until the next update, so
        // focus has to wait a turn.
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
            let imported = try JSONDecoder().decode([ImportedEntry].self, from: data)
            merge(imported.map(\.entry))
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

    /// Adds entries, overwriting an existing row with the same key instead of
    /// creating a duplicate.
    ///
    /// A regular rule is keyed by its `from`. A custom word — an empty `from`,
    /// which is how `CustomWordCorrector` reads its terms — has no `from` to key
    /// on, so it is keyed by its `to` instead. Without that second key every
    /// custom word would either be dropped on import or duplicated on every
    /// re-import. A row with neither is nothing at all and is skipped.
    private func merge(_ incoming: [DictionaryEntry]) {
        var result = model.settings.dictionary
        var indexByKey = [String: Int]()
        for (index, entry) in result.enumerated() {
            if let key = Self.mergeKey(for: entry) { indexByKey[key] = index }
        }
        for var entry in incoming {
            guard let key = Self.mergeKey(for: entry) else { continue }
            if let index = indexByKey[key] {
                // Keep the existing identity so selection and focus survive.
                entry.id = result[index].id
                result[index] = entry
            } else {
                indexByKey[key] = result.count
                result.append(entry)
            }
        }
        model.settings.dictionary = result
    }

    /// `from:` for a replacement rule, `to:` for a custom word, nil for a row
    /// with neither.
    private static func mergeKey(for entry: DictionaryEntry) -> String? {
        let from = entry.from.trimmingCharacters(in: .whitespaces)
        if !from.isEmpty { return "from:" + from.lowercased() }
        let to = entry.to.trimmingCharacters(in: .whitespaces)
        if !to.isEmpty { return "to:" + to.lowercased() }
        return nil
    }
}

/// `DictionaryEntry`'s synthesised decoder requires every key. Files people write
/// by hand rarely carry an `id`, so import goes through this looser shape.
private struct ImportedEntry: Decodable {
    var id: UUID?
    var from: String
    var to: String
    var matchCase: Bool?

    var entry: DictionaryEntry {
        DictionaryEntry(id: id ?? UUID(), from: from, to: to, matchCase: matchCase ?? false)
    }
}

/// A table cell that edits a draft and writes back on submit or focus loss, so
/// typing does not persist settings on every keystroke.
private struct DictionaryField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    let cell: DictionaryCell
    var focus: FocusState<DictionaryCell?>.Binding

    @State private var draft = ""

    var body: some View {
        // Inside a grouped Form a TextField renders its title as a label, so
        // pass the placeholder as `prompt` and hide the label.
        TextField("", text: $draft, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.plain)
            .focused(focus, equals: cell)
            .onAppear { draft = text }
            .onSubmit { commit() }
            .onChange(of: text) { _, new in
                // An import or a reset happened elsewhere; adopt it unless the
                // user is mid-edit in this very cell.
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
