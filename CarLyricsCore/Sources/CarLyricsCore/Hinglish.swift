import Foundation

/// Devanagari → Hinglish spelled the way people type it ("mein", "hain", "karte", "bhai", "chale"),
/// instead of ICU's scholarly ISO 15919 ("mem", "haim", "karate", "bha'i", "cale").
/// Table-driven, plus Hindi schwa deletion: the inherent "a" drops word-finally and in V C _ C V
/// (Ohala's rule), so करते → "karte", जानती → "jaanti", but ज़िंदगी keeps "zindagi".
/// ponytail: rules plus a few whole-word overrides, no lexicon. Expect the odd miss ("mehanti"
/// where people write "mehnati"); add the word to `overrides` when one keeps showing up.
/// Tuned against hand-typed Hinglish for Seedhe Maut's "Luka Chippi": 56% of words matched with
/// ICU, 82%+ with this.
enum Hinglish {
    static func romanize(_ text: String) -> String {
        var out = ""
        var word: [Unicode.Scalar] = []
        func flush() {
            guard !word.isEmpty else { return }
            out += romanizeWord(word)
            word.removeAll()
        }
        // NFD splits nukta letters (क़ → क + ़), so one table covers both spellings.
        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x0966...0x096F: flush(); out += String(scalar.value - 0x0966) // Devanagari digits
            case 0x0964, 0x0965: flush(); out += "."                            // danda
            case 0x0900...0x097F: word.append(scalar)
            default: flush(); out.unicodeScalars.append(scalar)
            }
        }
        flush()
        return out
    }

    private enum Vowel { case silent, schwa, aa, i, ii, u, uu, ri, e, ai, o, au }

    private struct Syllable {
        var onset: [String] = []
        var vowel: Vowel = .schwa
        var nasal = false
        var visarga = false
    }

    private static func romanizeWord(_ scalars: [Unicode.Scalar]) -> String {
        var key = String.UnicodeScalarView()
        key.append(contentsOf: scalars)
        if let word = overrides[String(key)] { return word }

        // Parse into syllables: a consonant cluster (joined by viramas) plus one vowel.
        var syl: [Syllable] = []
        var lastBase: Unicode.Scalar?
        var joining = false
        for s in scalars {
            if let c = consonants[s] {
                if joining, !syl.isEmpty {
                    syl[syl.count - 1].onset.append(c)
                    syl[syl.count - 1].vowel = .schwa
                } else {
                    syl.append(Syllable(onset: [c]))
                }
                lastBase = s
                joining = false
            } else if s == "\u{093C}" { // nukta: क़ q, ज़ z, फ़ f, ड़ d …
                if let base = lastBase, let n = nukta[base], let last = syl.indices.last, !syl[last].onset.isEmpty {
                    syl[last].onset[syl[last].onset.count - 1] = n
                }
            } else if s == "\u{094D}" { // virama: no vowel, the next consonant joins the cluster
                if let last = syl.indices.last { syl[last].vowel = .silent; joining = true }
            } else if let v = matras[s] {
                if let last = syl.indices.last { syl[last].vowel = v }
                joining = false
            } else if let v = vowels[s] {
                syl.append(Syllable(vowel: v))
                lastBase = nil
                joining = false
            } else if s == "\u{0902}" || s == "\u{0901}" { // anusvara, chandrabindu
                if let last = syl.indices.last { syl[last].nasal = true }
            } else if s == "\u{0903}" {
                if let last = syl.indices.last { syl[last].visarga = true }
            }
        }

        // Schwa deletion. Word-final first, except after a conjunct ending in y/r/v ("satya").
        let n = syl.count
        if n > 1, syl[n - 1].vowel == .schwa, !syl[n - 1].nasal,
           !(syl[n - 1].onset.count > 1 && ["y", "r", "v"].contains(syl[n - 1].onset.last ?? "")) {
            syl[n - 1].vowel = .silent
        }
        // Then V C _ C V, right to left, never making a 3-consonant cluster (a nasal counts).
        if n > 2 {
            for i in stride(from: n - 2, through: 1, by: -1) {
                let drop = syl[i].vowel == .schwa && !syl[i].nasal && syl[i].onset.count == 1
                    && syl[i - 1].vowel != .silent && !syl[i - 1].nasal && !syl[i - 1].visarga
                    && syl[i + 1].onset.count == 1 && syl[i + 1].vowel != .silent
                if drop { syl[i].vowel = .silent }
            }
        }

        var out = ""
        for i in syl.indices {
            let s = syl[i]
            let last = i == n - 1
            let next = last ? nil : syl[i + 1]

            var onset = s.onset.enumerated().map { j, c -> String in
                // व is "w" in clusters ("swaad"), between a-sounds ("awaaz", "jawaab"), and
                // word-initially before a/aa/o ("wo", "wazan"); "v" otherwise ("kavi", "vishwaas").
                if c == "v", j > 0
                    || (i > 0 && [.schwa, .aa].contains(syl[i - 1].vowel) && !syl[i - 1].nasal && [.schwa, .aa].contains(s.vowel))
                    || (i == 0 && s.onset.count == 1 && [.schwa, .aa, .o, .au].contains(s.vowel)) {
                    return "w"
                }
                // छ is "chh" only word-initially ("chhota"); "peeche", "kuch" elsewhere.
                if c == "chh", i > 0 || j > 0 { return "ch" }
                return c
            }.joined()
            onset = onset.replacingOccurrences(of: "chch", with: "cch").replacingOccurrences(of: "jn", with: "gy")
            // A vowel straight after a/aa glides in with "y": गए "gaye", आए "aaye", गई "gayi"; not
            // after u ("jue", "dhuen") or in ā+ई ("bhai").
            if s.onset.isEmpty, i > 0 {
                let prev = syl[i - 1].vowel
                if [.e, .ai].contains(s.vowel), [.schwa, .aa].contains(prev) { onset = "y" }
                if [.i, .ii].contains(s.vowel), prev == .schwa { onset = "y" }
            }

            let vowel: String
            switch s.vowel {
            case .silent: vowel = ""
            case .schwa:
                // "rahti" → "rehti": a schwa before an h that lost its own vowel reads as "e".
                vowel = next?.onset == ["h"] && next?.vowel == Vowel.silent && i + 2 < n ? "e" : "a"
            case .aa:
                if let next, next.onset.isEmpty, [.i, .ii].contains(next.vowel) { vowel = "a" } // भाई "bhai"
                else { vowel = !last || (s.nasal && n == 1) ? "aa" : "a" }            // "baat", "tha", "haan"
            case .i: vowel = "i"
            case .ii: vowel = last ? "i" : "ee"                                       // "jeena", "nahi"
            case .u: vowel = "u"
            case .uu: vowel = last && !s.nasal ? "u" : "oo"                           // "poocha", "tu", "hoon"
            case .ri: vowel = "ri"
            case .e: vowel = last && s.nasal && !s.onset.isEmpty ? "ei" : "e"         // में "mein", धुएँ "dhuen"
            case .ai: vowel = "ai"
            case .o: vowel = "o"
            case .au: vowel = "au"
            }

            var nasal = ""
            if s.nasal {
                let labial = next?.onset.first.map { ["p", "b", "bh", "m"].contains($0) } ?? false
                nasal = labial ? "m" : "n" // "sambhaal", "rang"
            }
            out += onset + vowel + nasal + (s.visarga ? "h" : "")
        }
        return out
    }

    /// Very common words whose usual Hinglish spelling isn't phonetic (NFD keys).
    private static let overrides: [String: String] = [
        "हम": "hum", "नहीं": "nahi", "नहिं": "nahi", "मां": "maa", "माँ": "maa",
        "यह": "yeh", "वह": "woh", "कहां": "kahan", "कहाँ": "kahan", "क्यों": "kyun", "क्यूँ": "kyun",
        "मुँह": "muh", "मुंह": "muh", "चाहिए": "chahiye", "चाहिये": "chahiye",
        "हमें": "humein", "हमसे": "humse", "हमको": "humko", "हमारा": "humara", "हमारी": "humari", "हमारे": "humare",
    ].reduce(into: [:]) { $0[$1.key.decomposedStringWithCanonicalMapping] = $1.value }

    private static let consonants: [Unicode.Scalar: String] = [
        "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "n",
        "च": "ch", "छ": "chh", "ज": "j", "झ": "jh", "ञ": "n",
        "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n",
        "त": "t", "थ": "th", "द": "d", "ध": "dh", "न": "n",
        "प": "p", "फ": "f", "ब": "b", "भ": "bh", "म": "m",
        "य": "y", "र": "r", "ल": "l", "व": "v", "ळ": "l",
        "श": "sh", "ष": "sh", "स": "s", "ह": "h",
    ]

    private static let nukta: [Unicode.Scalar: String] = [
        "क": "q", "ख": "kh", "ग": "gh", "ज": "z", "फ": "f", "ड": "d", "ढ": "dh", "य": "y", "न": "n", "र": "r",
    ]

    private static let matras: [Unicode.Scalar: Vowel] = [
        "\u{093E}": .aa, "\u{093F}": .i, "\u{0940}": .ii, "\u{0941}": .u, "\u{0942}": .uu, "\u{0943}": .ri,
        "\u{0945}": .e, "\u{0946}": .e, "\u{0947}": .e, "\u{0948}": .ai,
        "\u{0949}": .o, "\u{094A}": .o, "\u{094B}": .o, "\u{094C}": .au,
    ]

    private static let vowels: [Unicode.Scalar: Vowel] = [
        "अ": .schwa, "आ": .aa, "इ": .i, "ई": .ii, "उ": .u, "ऊ": .uu, "ऋ": .ri,
        "ऍ": .e, "ऎ": .e, "ए": .e, "ऐ": .ai, "ऑ": .o, "ऒ": .o, "ओ": .o, "औ": .au,
    ]
}
