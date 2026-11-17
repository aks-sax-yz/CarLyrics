import XCTest
@testable import CarLyricsCore

final class TransliteratorTests: XCTestCase {
    private func hasNonLatin(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value >= 0x0370 && $0.properties.isAlphabetic }
    }

    func testRomanizesDevanagariLinesOnly() {
        let lyrics = TimedLyrics(lines: [
            LyricsLine(timeMs: 0, text: "मैं तुझको"),
            LyricsLine(timeMs: 1000, text: "I love you"),
        ], isSynced: true)

        let out = Transliterator.romanized(lyrics)

        XCTAssertFalse(hasNonLatin(out.lines[0].text), "Hindi line should be romanized")
        XCTAssertFalse(out.lines[0].text.isEmpty)
        XCTAssertEqual(out.lines[1].text, "I love you", "English line must pass through untouched")
    }

    func testDropsWordFinalSchwaForHindiOnly() {
        // "तुम ही हो" → "tum hi ho", not ICU's raw "tuma hi ho".
        let lyrics = TimedLyrics(lines: [LyricsLine(timeMs: 0, text: "तुम ही हो")], isSynced: true)
        XCTAssertEqual(Transliterator.romanized(lyrics).lines[0].text, "tum hi ho")
    }

    func testHindiComesOutAsTypedHinglish() {
        // ICU gave "mem", "haim", "karate", "bha'i", "cale", "nausa" for these.
        let cases = [
            "में": "mein", "हैं": "hain", "हूँ": "hoon", "मैं": "main", "नहीं": "nahi", "भाई": "bhai",
            "करते": "karte", "जानती": "jaanti", "कितने": "kitne", "रहती": "rehti", "चले": "chale",
            "छोटे": "chhote", "पीछे": "peeche", "पूछा": "poocha", "ज़िंदगी": "zindagi", "मोहब्बत": "mohabbat",
            "समझना": "samajhna", "धड़कन": "dhadkan", "वज़न": "wazan", "आवाज़": "aawaaz", "विश्वास": "vishwaas",
            "अच्छा": "accha", "ज्ञान": "gyaan", "गए": "gaye", "गई": "gayi", "फाड़ू": "faadu", "क़िस्मत": "qismat",
            "ख़ूंख़ार": "khoonkhaar", "संभाल": "sambhaal", "क्यों": "kyun", "मुँह": "muh",
        ]
        for (hindi, hinglish) in cases {
            XCTAssertEqual(Transliterator.romanize(hindi), hinglish, hindi)
        }
    }

    func testMixedLineLeavesEnglishWordsAlone() {
        // ICU's schwa-drop used to clip the English too ("papa" → "pap").
        XCTAssertEqual(Transliterator.romanize("छोटे मोटे rapper'on का papa है"), "chhote mote rapper'on ka papa hai")
        XCTAssertEqual(Transliterator.romanize("Movie में जी रहे हैं hero कवि"), "Movie mein ji rahe hain hero kavi")
    }

    func testRomanizesOtherScripts() {
        // Non-Devanagari scripts fold to Latin too — and must NOT get the Hindi schwa-drop.
        let lyrics = TimedLyrics(lines: [
            LyricsLine(timeMs: 0, text: "Привет"),      // Cyrillic
            LyricsLine(timeMs: 1000, text: "안녕"),       // Hangul
        ], isSynced: true)
        let out = Transliterator.romanized(lyrics)
        XCTAssertFalse(hasNonLatin(out.lines[0].text), "Cyrillic should romanize")
        XCTAssertFalse(hasNonLatin(out.lines[1].text), "Hangul should romanize")
    }

    func testLeavesEnglishAndAccentsUnchanged() {
        // English and accented European text pass through untouched (no false romanization).
        let lyrics = TimedLyrics(lines: [
            LyricsLine(timeMs: 0, text: "hello café"),
        ], isSynced: true)
        XCTAssertEqual(Transliterator.romanized(lyrics), lyrics)
    }
}
