import Foundation

/// One user dictionary rule: replace `from` with `to`.
public struct DictionaryEntry: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    /// The spoken form as the engine tends to transcribe it, e.g. "claude code".
    public var from: String
    /// The replacement, e.g. "Claude Code".
    public var to: String
    /// When true, `from` must match exactly including case. Default is
    /// case-insensitive with capitalisation carried over at sentence start.
    public var matchCase: Bool

    public init(id: UUID = UUID(), from: String, to: String, matchCase: Bool = false) {
        self.id = id
        self.from = from
        self.to = to
        self.matchCase = matchCase
    }

    /// `from` as rules are compared: trimmed and lowercased. Empty for a
    /// custom word, which has no `from`.
    public var normalizedFrom: String { Self.normalized(from) }

    /// The form two spellings of a heard phrase are compared in.
    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// What two entries collide on when one is added over the other:
    /// `from:` for a replacement rule, `to:` for a custom word (an empty
    /// `from`, which is how `CustomWordCorrector` reads its terms), nil for
    /// a row with neither, which is nothing at all.
    public var mergeKey: String? {
        let from = normalizedFrom
        if !from.isEmpty { return "from:" + from }
        let to = Self.normalized(self.to)
        if !to.isEmpty { return "to:" + to }
        return nil
    }

    /// The ids of every entry that sits on a replacement cycle.
    ///
    /// An edge runs from rule A to a different rule B when A's `to` contains
    /// B's `from` as a whole word, case-insensitively, using the same
    /// tokenisation `DictionaryReplacer` matches with. A cycle is any set of
    /// entries reachable from themselves along those edges — two rules that
    /// swap each other's text ("a" → "b" and "b" → "a"), or a longer loop.
    ///
    /// Note what a cycle actually does at run time: each rule runs once, in
    /// order, over the same string. "a" → "b" then "b" → "a" does not loop —
    /// it silently reverts the first rule the moment the second one runs.
    /// That is the confusing behaviour this flags, so the caller can drop
    /// the rules involved rather than ship behaviour nobody asked for.
    ///
    /// A rule whose own replacement contains its trigger ("x" → "x y",
    /// "iphone" → "iPhone") is not a cycle: it runs once and is never
    /// revisited, so it does exactly what it says.
    public static func cyclicIDs(in entries: [DictionaryEntry]) -> Set<UUID> {
        // One regex per entry, matching its `from` as a whole word — built
        // once and reused for every edge check below.
        let triggerRegex: [UUID: NSRegularExpression] = Dictionary(
            uniqueKeysWithValues: entries.compactMap { entry in
                guard let regex = WholeWordPattern.regex(for: entry.from) else { return nil }
                return (entry.id, regex)
            })

        var adjacency: [UUID: Set<UUID>] = [:]
        for a in entries {
            let ns = a.to as NSString
            let range = NSRange(location: 0, length: ns.length)
            var targets: Set<UUID> = []
            for b in entries where b.id != a.id {
                guard let regex = triggerRegex[b.id] else { continue }
                if regex.firstMatch(in: a.to, range: range) != nil {
                    targets.insert(b.id)
                }
            }
            adjacency[a.id] = targets
        }

        var cyclic: Set<UUID> = []
        for entry in entries {
            if isOnACycle(entry.id, adjacency: adjacency) {
                cyclic.insert(entry.id)
            }
        }
        return cyclic
    }

    /// True when `start` can reach itself by following one or more edges.
    private static func isOnACycle(_ start: UUID, adjacency: [UUID: Set<UUID>]) -> Bool {
        var stack = Array(adjacency[start] ?? [])
        var visited: Set<UUID> = []
        while let next = stack.popLast() {
            if next == start { return true }
            guard visited.insert(next).inserted else { continue }
            stack.append(contentsOf: adjacency[next] ?? [])
        }
        return false
    }
}

extension Array where Element == DictionaryEntry {
    /// True when a rule already replaces `heard`, whatever its case or
    /// surrounding spaces.
    public func hasRule(for heard: String) -> Bool {
        let key = DictionaryEntry.normalized(heard)
        return !key.isEmpty && contains { $0.normalizedFrom == key }
    }

    /// Adds `incoming`, overwriting an existing row with the same
    /// `mergeKey` rather than creating a duplicate. The overwritten row keeps
    /// its `id`, so selection and focus in the Dictionary tab survive. Rows
    /// without a key are skipped. The one way entries are added: the
    /// Dictionary tab's import and an accepted learned correction both come
    /// through here.
    public mutating func merge(_ incoming: [DictionaryEntry]) {
        var indexByKey: [String: Int] = [:]
        for (index, entry) in enumerated() {
            if let key = entry.mergeKey { indexByKey[key] = index }
        }
        for var entry in incoming {
            guard let key = entry.mergeKey else { continue }
            if let index = indexByKey[key] {
                entry.id = self[index].id
                self[index] = entry
            } else {
                indexByKey[key] = count
                append(entry)
            }
        }
    }
}
