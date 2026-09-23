import Foundation

/// The pairs the user answered Dismiss to, so they are never proposed again.
///
/// Its own file, `dismissed-corrections.json` beside `settings.json`, and not
/// a field of `Settings`: every settings assignment is compared, saved and
/// pushed into the coordinator, which rebuilds the processor pipeline, and a
/// memory the app writes to itself does not belong in that value. And
/// `SettingsStore` moves an undecodable file aside, so a bug here could cost
/// the user their dictionary; this file can only ever cost itself.
///
/// Matching is case-insensitive on both sides. Loaded on first use; an
/// unreadable file counts as empty and is left where it is until the next
/// Dismiss rewrites it. Deleting the file is the whole reset.
public actor DismissedCorrections {
    private let url: URL
    private var pairs: [CorrectionPair] = []
    private var keys: Set<String>?

    public init(url: URL) {
        self.url = url
    }

    public func contains(_ pair: CorrectionPair) -> Bool {
        loaded().contains(pair.key)
    }

    public func dismiss(_ pair: CorrectionPair) {
        var keys = loaded()
        guard keys.insert(pair.key).inserted else { return }
        self.keys = keys
        pairs.append(pair)
        save()
    }

    private func loaded() -> Set<String> {
        if let keys { return keys }
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([CorrectionPair].self, from: data) {
            pairs = stored
        }
        let keys = Set(pairs.map(\.key))
        self.keys = keys
        return keys
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(pairs) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
