import XCTest
@testable import CarLyricsCore

final class LRCParserTests: XCTestCase {

    func testStandardLines() {
        let lrc = """
        [00:12.00]Line one
        [00:15.30]Line two
        [01:00.50]Line three
        """
        let result = LRCParser.parse(lrc)
        XCTAssertTrue(result.isSynced)
        XCTAssertEqual(result.lines.count, 3)
        XCTAssertEqual(result.lines[0].timeMs, 12_000)
        XCTAssertEqual(result.lines[0].text, "Line one")
        XCTAssertEqual(result.lines[1].timeMs, 15_300)
        XCTAssertEqual(result.lines[2].timeMs, 60_500)
    }

    func testMillisecondPrecision() {
        // 2-digit fraction = centiseconds, 3-digit = milliseconds.
        XCTAssertEqual(LRCParser.parseTime("00:01.5"), 1_500)   // 1 digit -> 500ms
        XCTAssertEqual(LRCParser.parseTime("00:01.50"), 1_500)  // 2 digit -> 500ms
        XCTAssertEqual(LRCParser.parseTime("00:01.500"), 1_500) // 3 digit -> 500ms
        XCTAssertEqual(LRCParser.parseTime("00:01.05"), 1_050)  // 2 digit -> 50ms
        XCTAssertEqual(LRCParser.parseTime("01:30"), 90_000)    // no fraction
        XCTAssertNil(LRCParser.parseTime("ar:Someone"))         // ID tag, not a time
    }

    func testMultipleStampsPerLine() {
        let lrc = "[00:10.00][00:20.00][00:30.00]Repeated chorus"
        let result = LRCParser.parse(lrc)
        XCTAssertEqual(result.lines.count, 3)
        XCTAssertEqual(result.lines.map(\.timeMs), [10_000, 20_000, 30_000])
        XCTAssertTrue(result.lines.allSatisfy { $0.text == "Repeated chorus" })
    }

    func testOffsetTagParsedNotBaked() {
        let lrc = """
        [offset:+250]
        [00:10.00]Hello
        """
        let result = LRCParser.parse(lrc)
        XCTAssertEqual(result.offsetMs, 250)
        // Offset is stored, not applied to line times (SyncEngine applies it).
        XCTAssertEqual(result.lines.first?.timeMs, 10_000)
    }

    func testIDTagsSkipped() {
        let lrc = """
        [ar:The Artist]
        [ti:The Title]
        [al:The Album]
        [00:05.00]Only real line
        """
        let result = LRCParser.parse(lrc)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0].text, "Only real line")
    }

    func testEnhancedWordLevel() {
        let lrc = "[00:12.00]<00:12.00>I <00:12.30>see <00:12.60>trees"
        let result = LRCParser.parse(lrc)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0].text, "I see trees")
        let words = result.lines[0].words
        XCTAssertEqual(words?.count, 3)
        XCTAssertEqual(words?[0].timeMs, 12_000)
        XCTAssertEqual(words?[0].text, "I")
        XCTAssertEqual(words?[2].timeMs, 12_600)
        XCTAssertEqual(words?[2].text, "trees")
    }

    func testSortingOutOfOrderInput() {
        let lrc = """
        [00:30.00]Third
        [00:10.00]First
        [00:20.00]Second
        """
        let result = LRCParser.parse(lrc)
        XCTAssertEqual(result.lines.map(\.text), ["First", "Second", "Third"])
    }

    func testPlainLyrics() {
        let plain = "First line\nSecond line\nThird line"
        let result = LRCParser.parsePlain(plain)
        XCTAssertFalse(result.isSynced)
        XCTAssertEqual(result.lines.count, 3)
        XCTAssertTrue(result.lines.allSatisfy { $0.timeMs == 0 })
    }

    func testEmptyInput() {
        XCTAssertTrue(LRCParser.parse("").isEmpty)
        XCTAssertFalse(LRCParser.parse("").isSynced)
    }
}

final class LRCLibSearchRankingTests: XCTestCase {
    private func r(_ synced: String?, plain: String? = nil, duration: Double?) -> LRCLibClient.Response {
        LRCLibClient.Response(id: nil, trackName: nil, artistName: nil, albumName: nil,
                              duration: duration, instrumental: nil, plainLyrics: plain, syncedLyrics: synced)
    }

    func testPrefersSyncedOverEarlierPlainResult() {
        let best = LRCLibClient.bestMatch([r(nil, plain: "words", duration: 200), r("[00:01.00]x", duration: 200)], durationMs: 200_000)
        XCTAssertEqual(best?.syncedLyrics, "[00:01.00]x")
    }

    func testPrefersClosestDurationAmongSynced() {
        let best = LRCLibClient.bestMatch([r("[00:01.00]live", duration: 260), r("[00:01.00]album", duration: 241)], durationMs: 240_000)
        XCTAssertEqual(best?.syncedLyrics, "[00:01.00]album")
    }

    func testSkipsResultsWithoutLyricsAndKeepsApiOrderOnTies() {
        XCTAssertNil(LRCLibClient.bestMatch([r(nil, duration: 200), r("", plain: "", duration: 200)], durationMs: nil))
        let best = LRCLibClient.bestMatch([r("[00:01.00]first", duration: 100), r("[00:01.00]second", duration: 300)], durationMs: nil)
        XCTAssertEqual(best?.syncedLyrics, "[00:01.00]first")
    }
}
