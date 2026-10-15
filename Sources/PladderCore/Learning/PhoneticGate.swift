import Foundation

// Short keys need an edit distance of one: Soundex agrees on "the" and "tea".
public enum PhoneticGate {
    static let shortKeyLength = 3
    static let shortKeyDistance = 1
    static let maximumDistance = 2

    public static func isClose(_ heard: String, _ corrected: String) -> Bool {
        let a = key(heard)
        let b = key(corrected)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let distance = levenshtein(a, b)
        if min(a.count, b.count) <= shortKeyLength { return distance <= shortKeyDistance }
        if distance <= maximumDistance { return true }
        if let sa = soundex(a), let sb = soundex(b), sa == sb { return true }
        return false
    }

    static func key(_ text: String) -> [Character] {
        text.lowercased().filter { $0.isLetter || $0.isNumber }.map { $0 }
    }

    // Nil for a non-ASCII key: Soundex is defined over the English alphabet. Written
    // again rather than shared with `CustomWordCorrector`, which is on the release path.
    static func soundex(_ key: [Character]) -> String? {
        guard key.allSatisfy(\.isASCII) else { return nil }
        var out = ""
        var previous: Character = "0"
        for character in key where character.isLetter {
            let code = soundexCode(character)
            if out.isEmpty {
                out.append(character.uppercased())
                previous = code
                continue
            }
            if code != "0", code != previous {
                out.append(code)
                if out.count == 4 { break }
            }
            if character != "h", character != "w" { previous = code }
        }
        guard !out.isEmpty else { return nil }
        while out.count < 4 { out.append("0") }
        return out
    }

    private static func soundexCode(_ character: Character) -> Character {
        switch character {
        case "b", "f", "p", "v": "1"
        case "c", "g", "j", "k", "q", "s", "x", "z": "2"
        case "d", "t": "3"
        case "l": "4"
        case "m", "n": "5"
        case "r": "6"
        default: "0"
        }
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
