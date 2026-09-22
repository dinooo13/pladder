import Foundation

/// The cheap check before the model: does the correction sound like what was
/// heard? A misrecognition does ("Claud" → "Claude", "get hub" → "GitHub");
/// a change of mind does not ("Friday" → "Monday"). Dropping those here keeps
/// the model for the pairs worth asking about.
///
/// Both sides are reduced to a key, lowercased with everything but letters
/// and digits removed, so "get hub" keys as "gethub". Then:
///
/// - Keys of three characters or fewer pass only at an edit distance of at
///   most one: Soundex agrees on "the" and "tea", and so would the gate. The
///   custom-word corrector has the same guard.
/// - Longer keys pass when their Soundex codes agree (both ASCII), or at an
///   edit distance of at most two. Keys with umlauts or ß skip Soundex, which
///   is defined over the English alphabet, and rely on the distance:
///   "Muller" → "Müller" is one, "Strasse" → "Straße" two.
///
/// Metaphone, which the issue names as an alternative, is not implemented:
/// Soundex plus the distance already catches the misrecognitions the tests
/// hold, and the model does the fine judgement after this.
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

    /// Lowercased letters and digits, in order.
    static func key(_ text: String) -> [Character] {
        text.lowercased().filter { $0.isLetter || $0.isNumber }.map { $0 }
    }

    /// American Soundex over an ASCII key: the first letter and three digits,
    /// same-coded neighbours collapsed, "h" and "w" transparent, vowels
    /// separating. Nil when the key holds anything but ASCII letters and
    /// digits, or no letter at all.
    ///
    /// The same algorithm as `CustomWordCorrector`'s, written again here
    /// rather than shared: that one sits on the release-to-paste path and is
    /// left untouched by a feature that runs after it.
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

    /// Plain two-row Levenshtein over characters.
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
