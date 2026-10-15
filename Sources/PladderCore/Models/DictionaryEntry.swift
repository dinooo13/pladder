import Foundation

public struct DictionaryEntry: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var from: String
    public var to: String
    public var matchCase: Bool

    public init(id: UUID = UUID(), from: String, to: String, matchCase: Bool = false) {
        self.id = id
        self.from = from
        self.to = to
        self.matchCase = matchCase
    }

    private enum CodingKeys: String, CodingKey { case id, from, to, matchCase }

    // Only `from` and `to` are required: hand-written files rarely carry an `id`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        matchCase = try c.decodeIfPresent(Bool.self, forKey: .matchCase) ?? false
    }

    // Empty for a custom word, which has no `from`.
    public var normalizedFrom: String { Self.normalized(from) }

    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public var mergeKey: String? {
        let from = normalizedFrom
        if !from.isEmpty { return "from:" + from }
        let to = Self.normalized(self.to)
        if !to.isEmpty { return "to:" + to }
        return nil
    }

    // Each rule runs once, in order, over the same string, so "a" → "b" then "b" → "a"
    // silently reverts the first. A rule whose replacement contains its own trigger
    // ("iphone" → "iPhone") is not a cycle.
    public static func cyclicIDs(in entries: [DictionaryEntry]) -> Set<UUID> {
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
    public func hasRule(for heard: String) -> Bool {
        let key = DictionaryEntry.normalized(heard)
        return !key.isEmpty && contains { $0.normalizedFrom == key }
    }

    // An overwritten row keeps its `id`, so selection in the Dictionary tab survives.
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
