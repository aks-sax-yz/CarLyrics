import Foundation

/// Parses LRC-format lyrics (standard + enhanced word-level A2 extension).
///
/// Standard line:      `[00:12.34]Some lyric text`
/// Multiple stamps:    `[00:12.34][00:45.00]Repeated line`
/// ID tag:             `[ar:Artist]` `[ti:Title]` `[offset:250]`
/// Enhanced words:     `[00:12.00]<00:12.00>I <00:12.30>see <00:12.60>trees`
public enum LRCParser {

    /// Parse an LRC string into sorted, synced lyrics. Returns lines sorted by time.
    public static func parse(_ raw: String) -> TimedLyrics {
        var offsetMs = 0
        var lines: [LyricsLine] = []

        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)

            // Offset ID tag: [offset:+250] / [offset:-100]
            if let offset = idTagValue(in: line, key: "offset"), let v = Int(offset.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")) {
                offsetMs = v
                continue
            }

            let stamps = timeStamps(in: line)
            guard !stamps.isEmpty else { continue } // skip pure ID tags / blank lines

            // Text is whatever follows the final leading time tag.
            let text = textAfterTimeTags(line)
            let words = enhancedWords(in: text)
            let cleanText = strippingWordTags(text).trimmingCharacters(in: .whitespaces)

            // One LyricsLine per time stamp (handles repeated-line stamps).
            for ms in stamps {
                lines.append(LyricsLine(timeMs: ms, text: cleanText, words: words.isEmpty ? nil : words))
            }
        }

        lines.sort { $0.timeMs < $1.timeMs }
        let synced = !lines.isEmpty && !(lines.count == 1 && lines[0].timeMs == 0)
        return TimedLyrics(lines: lines, isSynced: synced, offsetMs: offsetMs)
    }

    /// Wrap plain (unsynced) lyrics — no timestamps, one line per newline at time 0.
    public static func parsePlain(_ raw: String) -> TimedLyrics {
        let lines = raw.split(whereSeparator: \.isNewline).map {
            LyricsLine(timeMs: 0, text: String($0).trimmingCharacters(in: .whitespaces))
        }
        return TimedLyrics(lines: lines, isSynced: false, offsetMs: 0)
    }

    // MARK: - Time tag scanning

    /// Extract leading `[mm:ss.xx]` / `[mm:ss.xxx]` / `[mm:ss]` time stamps (ms).
    static func timeStamps(in line: String) -> [Int] {
        var result: [Int] = []
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "[" {
            guard let close = line[idx...].firstIndex(of: "]") else { break }
            let inner = String(line[line.index(after: idx)..<close])
            if let ms = parseTime(inner) {
                result.append(ms)
            } else {
                // Not a time tag (e.g. [ar:...]); leading tags ended.
                break
            }
            idx = line.index(after: close)
        }
        return result
    }

    /// Parse `mm:ss.xx`, `mm:ss.xxx`, or `mm:ss` into milliseconds. Nil if not a time.
    static func parseTime(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]) else { return nil }
        let secPart = parts[1]
        let secFrac = secPart.split(separator: ".")
        guard let seconds = Int(secFrac[0]) else { return nil }
        var frac = 0
        if secFrac.count == 2 {
            let f = String(secFrac[1])
            guard let fv = Int(f) else { return nil }
            // Normalize centiseconds/milliseconds by digit count.
            switch f.count {
            case 1: frac = fv * 100
            case 2: frac = fv * 10
            default: frac = fv // 3+ digits treated as ms
            }
        }
        return (minutes * 60 + seconds) * 1000 + frac
    }

    /// Everything after the leading run of `[...]` time tags.
    static func textAfterTimeTags(_ line: String) -> String {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "[" {
            guard let close = line[idx...].firstIndex(of: "]") else { break }
            let inner = String(line[line.index(after: idx)..<close])
            guard parseTime(inner) != nil else { break }
            idx = line.index(after: close)
        }
        return String(line[idx...])
    }

    // MARK: - ID tags

    static func idTagValue(in line: String, key: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[\(key):"), trimmed.hasSuffix("]") else { return nil }
        let start = trimmed.index(trimmed.startIndex, offsetBy: key.count + 2)
        let end = trimmed.index(before: trimmed.endIndex)
        guard start <= end else { return nil }
        return String(trimmed[start..<end])
    }

    // MARK: - Enhanced (word-level) tags

    /// Parse `<mm:ss.xx>word` runs into words. Time is absolute (same clock as line tags).
    static func enhancedWords(in text: String) -> [LyricsLine.Word] {
        var words: [LyricsLine.Word] = []
        var idx = text.startIndex
        while let open = text[idx...].firstIndex(of: "<") {
            guard let close = text[open...].firstIndex(of: ">") else { break }
            let inner = String(text[text.index(after: open)..<close])
            guard let ms = parseTime(inner) else {
                idx = text.index(after: close)
                continue
            }
            // Word text runs until the next '<' or end of string.
            let afterClose = text.index(after: close)
            let nextOpen = text[afterClose...].firstIndex(of: "<") ?? text.endIndex
            let word = String(text[afterClose..<nextOpen]).trimmingCharacters(in: .whitespaces)
            if !word.isEmpty {
                words.append(LyricsLine.Word(timeMs: ms, text: word))
            }
            idx = nextOpen
        }
        return words
    }

    static func strippingWordTags(_ text: String) -> String {
        var out = ""
        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx] == "<", let close = text[idx...].firstIndex(of: ">"),
               parseTime(String(text[text.index(after: idx)..<close])) != nil {
                idx = text.index(after: close)
            } else {
                out.append(text[idx])
                idx = text.index(after: idx)
            }
        }
        return out
    }
}
