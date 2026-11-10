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
