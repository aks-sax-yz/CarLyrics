import Foundation

/// Romanizes lyrics in ANY non-Latin script to Latin using the OS's built-in ICU transliteration
/// — offline, no API, no key. Cyrillic, Greek, Arabic, Hebrew, Devanagari, Thai, Hangul, kana,
/// Han, etc. all fold to Latin. Only lines/words that actually contain a non-Latin letter are
/// touched, so English (and accented European text like "café") passes through untouched.
///
/// Output is phonetic and best-effort:
///  - Hindi gets an extra word-final schwa-drop ("tuma"→"tum") for readable Hinglish.
///  - CJK is approximate: Han characters romanize via Mandarin pinyin (so Japanese kanji come out
///    as Chinese readings), though kana/Hangul romanize correctly.
/// Perfect, language-aware romanization would need an LLM/API per song.
public enum Transliterator {

    private static let devanagari: ClosedRange<UInt32> = 0x0900...0x097F

    public static func containsDevanagari(_ s: String) -> Bool {
        s.unicodeScalars.contains { devanagari.contains($0.value) }
    }

    /// True if the text has any non-Latin letter. Threshold 0x0370 (Greek block start) keeps all
    /// Latin — incl. Latin-1/Extended accents (é, ñ, ø) — as-is, and only flags true foreign
    /// scripts (Greek/Cyrillic/Hebrew/Arabic/Indic/CJK/Hangul/Thai…).
    public static func needsRomanization(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value >= 0x0370 && $0.properties.isAlphabetic }
    }

    /// Non-Latin → Latin, diacritics stripped. Idempotent on already-Latin text (safe to re-apply
    /// to cached lyrics). Pass `devanagari: true` to also drop Hindi's word-final inherent schwa.
    public static func romanize(_ s: String, devanagari: Bool = false) -> String {
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformToLatin, false)
        // Schwa-drop BEFORE stripping marks: "tuma"→"tum", "dila"→"dil". Safe because a real
        // long-ā still carries a combining macron here (last scalar isn't a bare 'a'). Hindi only
        // — dropping a final 'a' would break e.g. Japanese "sakura". ponytail: word-final only;
        // internal schwas ("ajanabi") remain — full schwa-deletion needs a lexicon.
        let latin = devanagari ? dropFinalSchwa(m as String) : (m as String)
        let m2 = NSMutableString(string: latin)
        CFStringTransform(m2, nil, kCFStringTransformStripCombiningMarks, false)
        return m2 as String
    }

    private static let consonants = Set("bcdfghjklmnpqrstvwxyz")

    private static func dropFinalSchwa(_ s: String) -> String {
        s.components(separatedBy: " ").map { token -> String in
            let scalars = Array(token.unicodeScalars)
            guard scalars.count >= 2, scalars.last == "a" else { return token }
            let prev = Character(scalars[scalars.count - 2])
            guard consonants.contains(Character(prev.lowercased())) else { return token }
            var out = String.UnicodeScalarView()
            out.append(contentsOf: scalars.dropLast())
            return String(out)
        }.joined(separator: " ")
    }

    /// Romanize every non-Latin line (and its word-level timings, if any) in place.
    public static func romanized(_ lyrics: TimedLyrics) -> TimedLyrics {
        guard lyrics.lines.contains(where: { needsRomanization($0.text) }) else { return lyrics }
        var out = lyrics
        out.lines = lyrics.lines.map { line in
            guard needsRomanization(line.text) else { return line }
            var l = line
            l.text = romanize(line.text, devanagari: containsDevanagari(line.text))
            l.words = line.words?.map { word in
                guard needsRomanization(word.text) else { return word }
                var w = word
                w.text = romanize(word.text, devanagari: containsDevanagari(word.text))
                return w
            }
            return l
        }
        return out
    }
}
