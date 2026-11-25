import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parses Apple Music's lyrics TTML (the web player's `syllable-lyrics` / `lyrics` responses).
///
/// - `<p begin end itunes:key>` is a line. Inside it each timed `<span begin end>` is a syllable;
///   syllables with no whitespace between them are one word, whitespace is a word break.
/// - `<span ttm:role="x-bg">` wraps background vocals ("(ooh)"): dropped (no room on CarPlay).
/// - Line-timed TTML has plain text in the `<p>`; unsynced TTML has no `begin` at all.
/// - `<head>…<transliterations><transliteration><text for="L1">` holds a Latin-script copy of a
///   line (Hindi etc., asked for with `l[script]`); it replaces that line, word timings included.
///   `<translations>` are ignored.
/// - `<iTunesMetadata leadingSilence>` and `<audio lyricOffset role>`: per-recording timing
///   metadata. The non-spatial (stereo) `lyricOffset` is added to every time, as YouLy+ does; the
///   spatial (Dolby Atmos) one and `leadingSilence` are only reported in `source` for now.
public enum AppleTTML {
    public static func parse(_ ttml: String) -> TimedLyrics? {
        let delegate = Collector()
        let parser = XMLParser(data: Data(ttml.utf8))
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        let lines = delegate.lines.map { line -> LyricsLine in
            guard let key = line.key, let latin = delegate.transliterations[key], !latin.text.isEmpty else { return line.line }
            var l = latin.line
            l.timeMs = line.line.timeMs
            l.endMs = line.line.endMs
            return l
        }.filter { !$0.text.isEmpty }
        guard !lines.isEmpty else { return nil }
        let synced = delegate.sawTiming
        let shift = delegate.audioOffsets.first { $0.role != "spatial" }?.ms ?? 0
        let shifted = lines.map { line -> LyricsLine in
            guard synced else { var l = line; l.timeMs = 0; return l }
            var l = line
            l.timeMs += shift
            l.endMs = l.endMs.map { $0 + shift }
            l.words = l.words?.map { var w = $0; w.timeMs += shift; w.endMs = w.endMs.map { $0 + shift }; return w }
            return l
        }
        var lyrics = TimedLyrics(lines: shifted, isSynced: synced)
        // Logged (never shown) so the timing metadata of real songs is on record.
        let meta = ["leadingSilence=\(delegate.leadingSilenceMs.map { "\($0)ms" } ?? "-")"]
            + delegate.audioOffsets.map { "lyricOffset[\($0.role ?? "-")]=\($0.ms)ms" }
        lyrics.source = meta.joined(separator: " ")
        return lyrics
    }

    /// "12.345", "1:02.345", "1:02:03.456", or with a trailing "s" → ms.
    static func ms(_ raw: String?) -> Int? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasSuffix("s") { s.removeLast() }
        var total = 0.0
        for part in s.split(separator: ":") {
            guard let v = Double(part) else { return nil }
            total = total * 60 + v
        }
        return Int((total * 1000).rounded())
    }

    /// A signed offset in seconds ("-0.271") → ms.
    static func signedMs(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces) else { return nil }
        let negative = raw.hasPrefix("-")
        return ms(negative ? String(raw.dropFirst()) : raw.replacingOccurrences(of: "+", with: "")).map { negative ? -$0 : $0 }
    }

    /// Builds one line from syllables and text.
    struct LineBuilder {
        var key: String?
        var begin: Int?
        var end: Int?
        var words: [LyricsLine.Word] = []
        var plain = ""            // untimed text (line-timed TTML)
        var joinNext = false      // the next syllable continues the last word (no space between)

        mutating func syllable(_ text: String, begin: Int?, end: Int?) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if joinNext, !(text.first?.isWhitespace ?? false), var last = words.popLast() {
                last.text += trimmed
                last.endMs = end ?? last.endMs
                words.append(last)
            } else {
                words.append(.init(timeMs: begin ?? self.begin ?? 0, text: trimmed, endMs: end))
            }
            // A syllable's own trailing space ends the word.
            joinNext = !(text.last?.isWhitespace ?? false)
        }

        mutating func gap(_ text: String) {
            if text.allSatisfy(\.isWhitespace) { joinNext = false } else { plain += text }
        }

        var text: String {
            words.isEmpty ? plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                          : words.map(\.text).joined(separator: " ")
        }

        var line: LyricsLine {
            LyricsLine(timeMs: begin ?? words.first?.timeMs ?? 0, text: text,
                       words: words.isEmpty ? nil : words, endMs: end ?? words.last?.endMs)
        }
    }

    final class Collector: NSObject, XMLParserDelegate {
        var lines: [LineBuilder] = []
        var transliterations: [String: LineBuilder] = [:]
        var sawTiming = false
        var leadingSilenceMs: Int?
        var audioOffsets: [(role: String?, ms: Int)] = []

        private var current: LineBuilder?
        private var inTransliterations = false
        private var inTransliterationText = false
        private var spanStack: [(begin: Int?, end: Int?, background: Bool)] = []
        private var syllableText = ""

        private var inBackground: Bool { spanStack.contains { $0.background } }
        private var timedSpan: (begin: Int?, end: Int?)? {
            spanStack.last.flatMap { $0.begin != nil ? ($0.begin, $0.end) : nil }
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String]) {
            switch local(name) {
            case "iTunesMetadata": leadingSilenceMs = AppleTTML.ms(a["leadingSilence"])
            case "audio":
                if let ms = AppleTTML.signedMs(a["lyricOffset"]) { audioOffsets.append((a["role"].flatMap { $0.isEmpty ? nil : $0 }, ms)) }
            case "transliterations": inTransliterations = true
            case "text" where inTransliterations:
                inTransliterationText = true
                current = LineBuilder(key: a["for"])
            case "p":
                let begin = AppleTTML.ms(a["begin"])
                if begin != nil { sawTiming = true }
                current = LineBuilder(key: a["itunes:key"], begin: begin, end: AppleTTML.ms(a["end"]))
            case "span" where current != nil:
                flushSyllable()
                let begin = AppleTTML.ms(a["begin"])
                if begin != nil { sawTiming = true }
                spanStack.append((begin, AppleTTML.ms(a["end"]), a["ttm:role"] == "x-bg"))
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch local(name) {
            case "transliterations": inTransliterations = false
            case "text" where inTransliterationText:
                flushSyllable()
                if let line = current, let key = line.key { transliterations[key] = line }
                current = nil
                inTransliterationText = false
            case "p" where !inTransliterations:
                flushSyllable()
                if let line = current { lines.append(line) }
                current = nil
            case "span" where current != nil:
                flushSyllable()
                if spanStack.removeLast().background { current?.joinNext = false }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard current != nil, !inBackground else { return }
            if timedSpan != nil { syllableText += string } else { current?.gap(string) }
        }

        private func flushSyllable() {
            guard let span = timedSpan, !syllableText.isEmpty else { syllableText = ""; return }
            if !inBackground { current?.syllable(syllableText, begin: span.begin, end: span.end) }
            syllableText = ""
        }

        private func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }
    }
}
