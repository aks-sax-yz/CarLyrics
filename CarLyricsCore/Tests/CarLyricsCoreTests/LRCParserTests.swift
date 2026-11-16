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

    func testPrefersHandTypedLatinVersionWithinTwoSeconds() {
        let devanagari = r("[00:01.00]तेरा भाई", duration: 142), latin = r("[00:01.00]Tera bhai", duration: 143)
        XCTAssertEqual(LRCLibClient.bestMatch([devanagari, latin], durationMs: 142_000, preferLatin: true)?.syncedLyrics,
                       latin.syncedLyrics)
        // Only when asked, and never at the cost of timings from a different cut.
        XCTAssertEqual(LRCLibClient.bestMatch([devanagari, latin], durationMs: 142_000)?.syncedLyrics, devanagari.syncedLyrics)
        let otherCut = r("[00:01.00]Tera bhai", duration: 315)
        XCTAssertEqual(LRCLibClient.bestMatch([devanagari, otherCut], durationMs: 142_000, preferLatin: true)?.syncedLyrics,
                       devanagari.syncedLyrics)
    }

    /// LRC text for lines "l0"…"l7" every 2s from 10s, shifted by `shiftMs`.
    private func lrc(shiftMs: Int) -> String {
        (0..<8).map { i -> String in
            let ms = 10_000 + i * 2_000 + shiftMs
            return String(format: "[%02d:%05.2f]line %d", ms / 60_000, Double(ms % 60_000) / 1000, i)
        }.joined(separator: "\n")
    }

    func testConsensusMovesTheChosenUploadToTheMedianTiming() {
        let chosen = LRCParser.parse(lrc(shiftMs: 0))
        // Three uploads 300ms later, one agreeing with ours, one from a different cut (+4.4s),
        // one for a different-length track: the median of the comparable four is +300.
        let versions = [r(lrc(shiftMs: 300), duration: 187), r(lrc(shiftMs: 300), duration: 187),
                        r(lrc(shiftMs: 300), duration: 188), r(lrc(shiftMs: 0), duration: 187),
                        r(lrc(shiftMs: 4_400), duration: 187), r(lrc(shiftMs: -900), duration: 240)]
        // Uploads say lines come 300ms later than ours do, so ours must show 300ms later
        // (offsetMs is "positive = sooner").
        XCTAssertEqual(LRCLibClient.consensusOffsetMs(chosen, versions: versions, durationMs: 187_000), -300)
        // Fewer than 3 comparable uploads: leave it alone.
        XCTAssertEqual(LRCLibClient.consensusOffsetMs(chosen, versions: Array(versions.prefix(2)), durationMs: 187_000), 0)
    }

    func testLineShiftUsesEffectiveTimesAndNeedsCommonLines() {
        let a = LRCParser.parse(lrc(shiftMs: 0))
        var b = LRCParser.parse(lrc(shiftMs: 500))
        b.offsetMs = 200 // an [offset:] tag of +200 shows b 200ms sooner: effective gap is 300
        XCTAssertEqual(LRCLibClient.lineShiftMs(from: a, to: b), 300)
        XCTAssertNil(LRCLibClient.lineShiftMs(from: a, to: LRCParser.parse("[00:10.00]something else")))
    }

    func testSkipsResultsWithoutLyricsAndKeepsApiOrderOnTies() {
        XCTAssertNil(LRCLibClient.bestMatch([r(nil, duration: 200), r("", plain: "", duration: 200)], durationMs: nil))
        let best = LRCLibClient.bestMatch([r("[00:01.00]first", duration: 100), r("[00:01.00]second", duration: 300)], durationMs: nil)
        XCTAssertEqual(best?.syncedLyrics, "[00:01.00]first")
    }
}
