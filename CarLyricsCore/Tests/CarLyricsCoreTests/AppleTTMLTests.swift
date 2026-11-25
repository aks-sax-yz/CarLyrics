import XCTest
@testable import CarLyricsCore

final class AppleTTMLTests: XCTestCase {
    private let head = #"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word">"#

    func testSyllablesJoinIntoWordsAndBackgroundVocalsDrop() throws {
        let ttml = head + #"<body><div begin="1.000" end="9.000"><p begin="1.000" end="4.500" itunes:key="L1" ttm:agent="v1"><span begin="1.000" end="1.400">I'm</span> <span begin="1.400" end="1.700">Ba</span><span begin="1.700" end="2.900">by</span> <span ttm:role="x-bg"><span begin="3.000" end="3.300">(ooh)</span></span> <span begin="3.300" end="4.500">now</span></p><p begin="0:05.0" end="0:06.250" itunes:key="L2"><span begin="0:05.0" end="0:06.250">Yeah</span></p></div></body></tt>"#
        let lyrics = try XCTUnwrap(AppleTTML.parse(ttml))
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["I'm Baby now", "Yeah"])
        let words = try XCTUnwrap(lyrics.lines[0].words)
        XCTAssertEqual(words.map(\.text), ["I'm", "Baby", "now"])
        XCTAssertEqual(words.map(\.timeMs), [1000, 1400, 3300])
        XCTAssertEqual(words.map(\.endMs), [1400, 2900, 4500])
        XCTAssertEqual(lyrics.lines[0].endMs, 4500)
        XCTAssertEqual(lyrics.lines[1].timeMs, 5000)
        XCTAssertEqual(lyrics.lines[1].endMs, 6250)
    }

    func testLineTimedHasNoWords() throws {
        let ttml = head.replacingOccurrences(of: "Word", with: "Line")
            + #"<body><div><p begin="12.5s" end="15s" itunes:key="L1">Hello   there</p><p begin="1:02:03.4" end="1:02:05" itunes:key="L2">Hour mark</p></div></body></tt>"#
        let lyrics = try XCTUnwrap(AppleTTML.parse(ttml))
        XCTAssertEqual(lyrics.lines.map(\.text), ["Hello there", "Hour mark"])
        XCTAssertNil(lyrics.lines[0].words)
        XCTAssertEqual(lyrics.lines.map(\.timeMs), [12_500, 3_723_400])
        XCTAssertEqual(lyrics.lines[0].endMs, 15_000)
    }

    func testUnsyncedIsPlain() throws {
        let ttml = #"<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p>One</p><p>Two</p></div></body></tt>"#
        let lyrics = try XCTUnwrap(AppleTTML.parse(ttml))
        XCTAssertFalse(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["One", "Two"])
    }

    func testTransliterationReplacesLineButNotTranslation() throws {
        let ttml = head + #"<head><metadata><iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal"><translations><translation xml:lang="en"><text for="L1">You are the one</text></translation></translations><transliterations><transliteration xml:lang="hi-Latn"><text for="L1"><span begin="2.0" end="2.5">Tum</span> <span begin="2.5" end="3.0">hi</span> <span begin="3.0" end="4.0">ho</span></text></transliteration></transliterations></iTunesMetadata></metadata></head><body><div><p begin="2.0" end="4.0" itunes:key="L1"><span begin="2.0" end="2.5">तुम</span> <span begin="2.5" end="3.0">ही</span> <span begin="3.0" end="4.0">हो</span></p><p begin="5.0" end="6.0" itunes:key="L2"><span begin="5.0" end="6.0">अब</span></p></div></body></tt>"#
        let lyrics = try XCTUnwrap(AppleTTML.parse(ttml))
        XCTAssertEqual(lyrics.lines.map(\.text), ["Tum hi ho", "अब"]) // L2 has no Latin copy: the romanizer takes it
        XCTAssertEqual(lyrics.lines[0].words?.map(\.timeMs), [2000, 2500, 3000])
        XCTAssertEqual(lyrics.lines[0].timeMs, 2000)
    }

    func testStereoLyricOffsetShiftsTimesSpatialOnlyLogged() throws {
        let meta = #"<head><metadata><iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal" leadingSilence="0.180"><audio lyricOffset="-0.271" role="spatial"/><audio lyricOffset="0.5"/></iTunesMetadata></metadata></head>"#
        let ttml = head + meta + #"<body><div><p begin="1.000" end="2.000" itunes:key="L1"><span begin="1.000" end="1.400">One</span> <span begin="1.400" end="2.000">two</span></p></div></body></tt>"#
        let lyrics = try XCTUnwrap(AppleTTML.parse(ttml))
        XCTAssertEqual(lyrics.lines[0].timeMs, 1500)
        XCTAssertEqual(lyrics.lines[0].endMs, 2500)
        XCTAssertEqual(lyrics.lines[0].words?.map(\.timeMs), [1500, 1900])
        XCTAssertEqual(lyrics.lines[0].words?.map(\.endMs), [1900, 2500])
        XCTAssertEqual(lyrics.source, "leadingSilence=180ms lyricOffset[spatial]=-271ms lyricOffset[-]=500ms")

        let spatialOnly = head + #"<head><metadata><iTunesMetadata leadingSilence="0"><audio lyricOffset="-0.271" role="spatial"/></iTunesMetadata></metadata></head>"#
            + #"<body><div><p begin="1.000" end="2.000">Hi</p></div></body></tt>"#
        XCTAssertEqual(try XCTUnwrap(AppleTTML.parse(spatialOnly)).lines[0].timeMs, 1000)
    }

    func testGarbageIsNil() {
        XCTAssertNil(AppleTTML.parse("not xml"))
        XCTAssertNil(AppleTTML.parse(#"<tt xmlns="http://www.w3.org/ns/ttml"><body/></tt>"#))
    }
}
