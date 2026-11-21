import Foundation

// FONN-LAYOUT-1
/// Why a tune comes out strangely on the stave, and the tidy-up.
///
/// Measured in abcjs with Fonn's own wrap settings: its wrapping splits a long
/// line but never joins short ones, so every line break in the ABC starts a new
/// stave, and a tune pasted one bar to a line is drawn one bar to a stave. Old
/// ABC's "!" line break (about one tune in twelve in a library from
/// thesession.org) forces a stave break too, and can swallow notes. A blank
/// line ends the tune. Non-breaking and zero-width spaces from web pages are
/// skipped with warnings. Windows line endings and %%staffwidth make no
/// difference.
///
/// The same checks, line for line, are `ceolLayoutProblems` and
/// `ceolTidyLayout` in Web/edittools.js (used by Compose);
/// tools/verify_abclayout.py checks the two agree over a whole library.
public enum ABCLayout {

    public struct Problem: Identifiable, Equatable {
        public let id: String
        public let title: String
        public let detail: String
        public let fixable: Bool
    }

    // MARK: - Checking

    public static func problems(in abc: String) -> [Problem] {
        let text = normalisedNewlines(abc)
        let lines = text.components(separatedBy: "\n")
        guard let k = lines.firstIndex(where: { $0.hasPrefix("K:") }) else { return [] }
        let body = Array(lines[(k + 1)...])

        var lastMusic = -1
        for (i, line) in body.enumerated() where !isBlank(line) && !isFieldLine(line) { lastMusic = i }

        var blank = false, bangs = false, noBars = false, header = false, secondTune = false
        var short = 0, music = 0
        for (i, line) in body.enumerated() {
            if startsField(line, "X") { secondTune = true }
            if isBlank(line) {
                if i < lastMusic && !secondTune { blank = true }
                continue
            }
            if startsField(line, "T") { header = true }
            if isFieldLine(line) { continue }
            music += 1
            if !strayBangs(in: line).isEmpty { bangs = true }
            let bars = barCount(line)
            if bars == 0 && noteCount(line) > 24 { noBars = true }
            if bars <= 2 && i != lastMusic && !endsWithContinuation(line) { short += 1 }
        }

        var out: [Problem] = []
        if blank {
            out.append(Problem(id: "blank", title: "A blank line in the music",
                detail: "A blank line ends a tune in ABC, so everything after it is dropped without a word. Tidy takes blank lines out of the music.",
                fixable: true))
        }
        if bangs {
            out.append(Problem(id: "bang", title: "Old-style ! line breaks",
                detail: "Older ABC (much of thesession.org's early music) used ! to end a line. Each one forces a new stave there, whatever the width of the screen, and one with no space after it can swallow the notes that follow. Tidy takes them out and lets Fonn lay the bars out itself.",
                fixable: true))
        }
        if text.unicodeScalars.contains(where: { hidden.contains($0) }) {
            out.append(Problem(id: "hidden", title: "Hidden characters",
                detail: "Non-breaking or zero-width spaces, usually copied from a web page. They can't be seen and the music reader skips them with a warning. Tidy turns them into ordinary spaces or takes them out.",
                fixable: true))
        }
        if music >= 3 && short >= max(2, Int((Double(music) / 3).rounded(.up))) {
            out.append(Problem(id: "short", title: "Short lines",
                detail: "Each line of ABC starts a new stave, and short lines are never joined, so a tune written a bar or two to a line is drawn a bar or two to a stave. Tidy joins each part into one line and lets Fonn lay out the bars to fit the screen.",
                fixable: true))
        }
        if noBars {
            out.append(Problem(id: "nobars", title: "No bar lines",
                detail: "A long run of notes with no | in it is one enormous bar, which can't be laid out across lines. Put a | at the end of each bar.",
                fixable: false))
        }
        if header {
            out.append(Problem(id: "title", title: "A title inside the music",
                detail: "A T: line after the K: line is drawn as a heading partway through the tune. If it names a part, P:A or P:B is the usual way; otherwise delete it.",
                fixable: false))
        }
        if secondTune {
            out.append(Problem(id: "second", title: "Two tunes in one",
                detail: "There is another X: line further down: this ABC holds more than one tune, and only the first is shown. Copy the second into a tune of its own, then delete it here.",
                fixable: false))
        }
        return out
    }

    // MARK: - Tidying

    /// Line endings, hidden characters, blank lines and stray ! out of the
    /// music, and each part's lines joined into one. Header lines, P:, inline
    /// fields, comments and lyrics keep their own lines. Never changes a note:
    /// checked over a 1,571-tune library.
    public static func tidy(_ abc: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in normalisedNewlines(abc).unicodeScalars {
            switch s {
            case "\u{2028}", "\u{2029}": scalars.append("\n")
            case "\u{00A0}": scalars.append(" ")
            case "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}": continue
            default: scalars.append(s)
            }
        }
        let lines = String(scalars).components(separatedBy: "\n")
        guard let k = lines.firstIndex(where: { $0.hasPrefix("K:") }) else { return String(scalars) }
        let head = lines[0...k].joined(separator: "\n") + "\n"
        let body = Array(lines[(k + 1)...])
        let hasSecond = body.contains { startsField($0, "X") }

        var out: [String] = []
        var current = ""
        func flush() {
            if !isBlank(current) { out.append(trimTrailing(current)) }
            current = ""
        }
        var i = 0
        while i < body.count {
            var line = body[i]
            if startsField(line, "X") {
                flush()
                out.append(contentsOf: body[i...])
                break
            }
            if isBlank(line) {
                if hasSecond { flush(); out.append("") }
                i += 1
                continue
            }
            if isFieldLine(line) {
                flush()
                out.append(trimTrailing(line))
                i += 1
                continue
            }
            var chars = Array(line)
            for index in strayBangs(in: line).reversed() { chars[index] = " " }
            line = String(chars)
                .replacingOccurrences(of: #"\\\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { i += 1; continue }
            if current.isEmpty {
                current = line
            } else if endsWithBar(current) && line.hasPrefix("|") {
                current = trimTrailing(current)
                current.removeLast()
                current += line
            } else {
                current += (endsWithBar(current) ? "" : " ") + line
            }
            // A part ends at a closing repeat, a double bar or a final bar.
            if current.range(of: #"(:\||\|\]|\|\||::)\s*$"#, options: .regularExpression) != nil {
                flush()
            }
            i += 1
        }
        flush()
        var joined = out.joined(separator: "\n")
        while joined.hasSuffix("\n") { joined.removeLast() }
        return head + joined + "\n"
    }

    // MARK: - Pieces

    static let hidden: Set<Unicode.Scalar> = [
        "\u{00A0}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{2028}", "\u{2029}"
    ]

    static func normalisedNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A header or inline field line ("P:A", "w:…") or a comment.
    static func isFieldLine(_ line: String) -> Bool {
        let t = Array(line.drop(while: { $0 == " " || $0 == "\t" }))
        if t.first == "%" { return true }
        return t.count >= 2 && t[0].isASCII && t[0].isLetter && t[1] == ":"
    }

    static func startsField(_ line: String, _ letter: Character) -> Bool {
        let t = Array(line.drop(while: { $0 == " " || $0 == "\t" }))
        return t.count >= 2 && t[0] == letter && t[1] == ":"
    }

    static func trimTrailing(_ s: String) -> String {
        var s = s
        while let last = s.last, last == " " || last == "\t" { s.removeLast() }
        return s
    }

    static func endsWithBar(_ s: String) -> Bool { trimTrailing(s).hasSuffix("|") }

    static func endsWithContinuation(_ s: String) -> Bool { trimTrailing(s).hasSuffix("\\") }

    /// Offsets (in Characters) of each "!" that isn't part of a decoration
    /// like !trill! — old ABC's line break. Decorations are paired from the
    /// left, so in !trill!A! only the last one is stray.
    static func strayBangs(in line: String) -> [Int] {
        let c = Array(line)
        var out: [Int] = []
        var i = 0
        while i < c.count {
            guard c[i] == "!" else { i += 1; continue }
            var j = i + 1
            while j < c.count && c[j] != "!" && !c[j].isWhitespace && c[j] != "|" { j += 1 }
            let inner = j - i - 1
            if j < c.count && c[j] == "!" && inner >= 1 && inner <= 24 {
                i = j + 1          // a decoration
            } else {
                out.append(i)
                i += 1
            }
        }
        return out
    }

    static func barCount(_ line: String) -> Int {
        line.replacingOccurrences(of: #""[^"]*""#, with: "", options: .regularExpression)
            .filter { $0 == "|" }.count
    }

    static func noteCount(_ line: String) -> Int {
        line.replacingOccurrences(of: #""[^"]*"|![^!]*!|\{[^}]*\}"#, with: "", options: .regularExpression)
            .filter { "ABCDEFGabcdefg".contains($0) }.count
    }
}
