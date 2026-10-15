import Foundation

// Its own file, not part of `Settings`: a bug here can only ever cost this file,
// never the dictionary.
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
