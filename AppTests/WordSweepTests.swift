import XCTest
@testable import CarLyrics
import CarLyricsCore

final class WordSweepTests: XCTestCase {
    private let font = LyricFit.font(18)

    /// Words of `text` sung at an even pace across the row: 100pt a second.
    private func even(_ text: String) -> [WordSweep.Word] {
        let x = { (s: Substring) in Double((String(s) as NSString).size(withAttributes: [.font: self.font]).width) / 100 }
        var at = text.startIndex
        return text.split(separator: " ").map { w in
            let start = x(text[..<w.startIndex]), end = x(text[..<w.endIndex])
            at = w.endIndex
            return .init(chars: w.count, start: start, end: end)
        }
    }

    func testEvenPaceIsOnePiece() {
        let text = "Driving through the city lights"
        let pieces = WordSweep.segments(even(text), text: text, font: font)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].t0, 0)
        XCTAssertEqual(pieces[0].x0, 0)
    }

    func testHeldWordAndGapSplit() {
        let text = "All I want is love"
        var words = even(text)
        words[4].end = words[4].start + 2.5 // "love" held
        XCTAssertEqual(WordSweep.segments(words, text: text, font: font).count, 2)

        var gapped = even(text)
        for k in 2..<gapped.count { gapped[k].start += 0.5; gapped[k].end += 0.5 } // pause after "I"
        XCTAssertEqual(WordSweep.segments(gapped, text: text, font: font).count, 2)
    }

    func testNeverMoreThanFourPieces() {
        let text = "a bb ccc dd e ff ggg hh"
        var t = 0.0
        let words = text.split(separator: " ").enumerated().map { i, w -> WordSweep.Word in
            defer { t += 0.4 + (i.isMultiple(of: 2) ? 0.3 : 1.0) } // every word a different pace, with gaps
            return .init(chars: w.count, start: t, end: t + (i.isMultiple(of: 2) ? 0.2 : 1.2))
        }
        let pieces = WordSweep.segments(words, text: text, font: font)
        XCTAssertEqual(pieces.count, 4)
        XCTAssertEqual(pieces.first?.t0, 0)
        XCTAssertEqual(pieces.last?.t1, words.last?.end)
    }

    func testEncodeDecodeAndSplitKeepWordTimes() {
        let words: [WordSweep.Word] = [.init(chars: 5, start: 0, end: 0.4), .init(chars: 7, start: 0.5, end: 1.2),
                                       .init(chars: 3, start: 3.0, end: 3.3), .init(chars: 4, start: 3.4, end: 4.0)]
        let w = WordSweep.encode(words)
        XCTAssertEqual(w, "5.0.400 7.500.1200 3.3000.3300 4.3400.4000")
        XCTAssertEqual(WordSweep.decode(w), words)

        let at = Date(timeIntervalSince1970: 1000)
        let line = LyricsActivityAttributes.TimedLine(text: "Hello wonders and more", at: at, w: w)
        XCTAssertEqual(line.words, words)
        // Two parts of one row each: the second starts at its first word, with re-based times.
        let parts = LyricFit.split([line], width: LyricFit.font(18).size(of: "Hello wonders") + 4, font: LyricFit.font(18), rows: 1)
        XCTAssertEqual(parts.map(\.text), ["Hello wonders", "and more"])
        XCTAssertEqual(parts[1].at, at.addingTimeInterval(3.0))
        XCTAssertEqual(parts[1].words, [.init(chars: 3, start: 0, end: 0.3), .init(chars: 4, start: 0.4, end: 1.0)])
        // Words that don't match the text (romanized into more words) fall back to the line sweep.
        XCTAssertNil(LyricsActivityAttributes.TimedLine(text: "one two three", at: at, w: "3.0.100 3.100.200").words)
    }

    func testDenseWordWindowFitsActivityLimit() throws {
        let line = { (i: Int) -> LyricsLine in
            let words = (0..<8).map { LyricsLine.Word(timeMs: i * 4000 + $0 * 400, text: "lyrics\($0)", endMs: i * 4000 + $0 * 400 + 350) }
            return LyricsLine(timeMs: i * 4000, text: words.map(\.text).joined(separator: " "), words: words)
        }
        let lyrics = TimedLyrics(lines: (0..<30).map(line), isSynced: true)
        let window = NowPlayingCoordinator.lyricWindow(lyrics, index: 4, songStart: Date(), userOffsetMs: 0, words: true)
        XCTAssertEqual(window.count, 12)
        XCTAssertTrue(window.allSatisfy { $0.words?.count == 8 })
        XCTAssertLessThan(try JSONEncoder().encode(window).count, 3_000) // the state's 3.5KB guard has room for the rest
    }
}

private extension UIFont {
    func size(of text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: self]).width / 0.95 }
}
