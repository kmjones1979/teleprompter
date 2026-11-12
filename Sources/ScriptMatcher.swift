import Foundation

/// A word in the script, with its location in the original text.
struct ScriptWord {
    let range: NSRange
    let norm: String
}

enum ScriptTokenizer {
    static func words(in text: String) -> [ScriptWord] {
        let ns = text as NSString
        var out: [ScriptWord] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byWords, .localized]) { sub, range, _, _ in
            guard let sub else { return }
            let n = normalize(sub)
            if !n.isEmpty { out.append(ScriptWord(range: range, norm: n)) }
        }
        return out
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func spokenTokens(_ transcript: String) -> [String] {
        transcript
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "—" })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }
}

/// Figures out where in the script the speaker is, from the most recent words recognized.
struct ScriptMatcher {
    let words: [String]

    /// Returns the index of the next word to be spoken, or nil if no confident match.
    func advance(spoken: [String], current: Int) -> Int? {
        let tail = Array(spoken.suffix(5))
        guard let last = tail.last, !words.isEmpty else { return nil }
        let lo = max(0, current - 3)
        let hi = min(words.count - 1, current + 30)
        guard lo <= hi else { return nil }

        var bestJ = -1
        var bestScore = 0.0
        for j in lo...hi where Self.similar(last, words[j]) {
            // Walk backwards through the spoken words and the script together.
            var score = weight(words[j])
            var si = tail.count - 2
            var wj = j - 1
            var misses = 0
            while si >= 0, wj >= 0 {
                if Self.similar(tail[si], words[wj]) {
                    score += weight(words[wj]); si -= 1; wj -= 1
                } else if misses == 0 {
                    misses = 1
                    if wj > 0, Self.similar(tail[si], words[wj - 1]) { wj -= 1 }      // skipped a script word
                    else if si > 0, Self.similar(tail[si - 1], words[wj]) { si -= 1 } // said an extra word
                    else { si -= 1; wj -= 1 }
                } else { break }
            }
            let near = j >= current - 1 && j <= current + 3
            let needed: Double = near ? 1.0 : (j < current ? 3.0 : 2.0)
            guard score >= needed else { continue }
            let adjusted = score - Double(abs(j - current)) * 0.05
            if adjusted > bestScore { bestScore = adjusted; bestJ = j }
        }
        return bestJ >= 0 ? bestJ + 1 : nil
    }

    private func weight(_ w: String) -> Double { w.count <= 3 ? 0.5 : 1.0 }

    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let la = a.count, lb = b.count
        guard min(la, lb) >= 4 else { return false }
        if a.hasPrefix(b) || b.hasPrefix(a) { return true }
        let maxEdits = max(la, lb) >= 7 ? 2 : 1
        guard abs(la - lb) <= maxEdits else { return false }
        return levenshtein(Array(a), Array(b)) <= maxEdits
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
