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
        // FONN-HEADBLANK-1: a blank line between the first header line and K:.
        let headBlank = lines[0..<k].drop(while: isBlank).contains(where: isBlank)
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
        if blank || headBlank {
            out.append(Problem(id: "blank", title: "A blank line in the tune",
                detail: "A blank line ends a tune in ABC, so everything after it is dropped without a word. Tidy takes blank lines out of the header and the music.",
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
        // FONN-HEADBLANK-1: blank lines out of the header too. The Session's
        // CRLF files, imported before FONN-CRLF-1, left a blank line after
        // every header line; a blank line ends a tune, so the music after K:
        // was never drawn. A header has no use for one.
        let head = lines[0...k].filter { !isBlank($0) }.joined(separator: "\n") + "\n"
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
        out = closeLaterEndings(leadingFieldsAsLines(out))
        var joined = out.joined(separator: "\n")
        while joined.hasSuffix("\n") { joined.removeLast() }
        return head + joined + "\n"
    }

    // MARK: - Phrasing (FONN-LAYOUT-2)

    /// Tidy, then four bars to a line and a label on each part, so the
    /// phrases sit one above another and a repeat or a recurring phrase can
    /// be seen at a glance. Each part starts on a new line; a part written
    /// all on one line is split at its repeat marks. A pickup into a part and
    /// a second-time ending don't count as bars. Parts of 6, 9 or 12 bars go
    /// three to a line; parts of five bars or fewer stay on one line.
    ///
    /// Labels (P:A, P:B …) are added only when the tune has no P: of its own
    /// and has two to eight parts of at least four bars. Tunes with several
    /// voices, or that set their own line breaks (I:linebreak), are only
    /// tidied. Never changes a note: checked in abcjs over a 1,571-tune
    /// library, and running it twice gives the same as running it once.
    /// tools/verify_abclayout.py carries a line-for-line Python copy.
    public static func phrased(_ abc: String) -> String {
        let t = tidy(abc)
        let lines = t.components(separatedBy: "\n")
        guard let k = lines.firstIndex(where: { $0.hasPrefix("K:") }) else { return t }
        let head = Array(lines[0...k])
        var body = Array(lines[(k + 1)...])
        if body.contains(where: { startsField($0, "X") }) { return t }
        // FONN-ONEVOICE-1: a single voice named with V:1 (as many tools write
        // it) is one stave like any other; only two or more voices are left.
        if voiceIDs(lines).count > 1 { return t }
        if lines.contains(where: { $0.contains("%%score")
            || $0.contains("%%staves") || $0.contains("linebreak") }) { return t }

        var music = body.indices.filter { !isBlank(body[$0]) && !isFieldLine(body[$0]) }
        // FONN-ENDING-1: a line that opens with a second (or later) ending
        // gives it back to the line above, where its part is. Laid out line by
        // line, it was counted into the next part, which took the label too.
        var emptied = Set<Int>()
        for pos in music.indices.dropFirst() {
            guard let cut = leadingLaterEnding(body[music[pos]]) else { continue }
            let prev = music[pos - 1]
            let above = trimTrailing(body[prev])
            var moved = cut.moved.trimmingCharacters(in: .whitespaces)
            if moved.count > 1, moved.first == "|", moved.dropFirst().first?.isNumber == true,
               let last = above.last, last == "|" || last == ":" {
                moved = "[" + moved.dropFirst()          // :| |2 would draw an empty bar
            }
            body[prev] = above + " " + moved
            body[music[pos]] = cut.rest.trimmingCharacters(in: .whitespaces)
            if body[music[pos]].isEmpty { emptied.insert(music[pos]) }
        }
        music = music.filter { !emptied.contains($0) }
        let hasP = lines.contains { startsField($0, "P") }
        var phrasedLines: [Int: [(text: String, bars: Int)]] = [:]
        for i in music { phrasedLines[i] = splitParts(body[i]).map(phrasePart) }
        let real = music.flatMap { phrasedLines[$0] ?? [] }.map(\.bars).filter { $0 > 0 }
        let label = !hasP && real.count >= 2 && real.count <= 8 && real.allSatisfy { $0 >= 4 }

        let letters = Array("ABCDEFGH")
        var out: [String] = []
        var part = 0
        for (i, line) in body.enumerated() {
            if let pieces = phrasedLines[i] {
                for piece in pieces {
                    if label && piece.bars > 0 {
                        out.append("P:\(letters[part])")
                        part += 1
                    }
                    out.append(piece.text)
                }
            } else if !emptied.contains(i) {
                out.append(line)
            }
        }
        // FONN-SPLITREPEAT-1: a part that ends a line with "::" hands its
        // start-repeat to the next line, so the repeat sign opens the next
        // part instead of hanging off the end of the one before.
        let rows = out.indices.filter { !isBlank(out[$0]) && !isFieldLine(out[$0]) }
        for (a, b) in zip(rows, rows.dropFirst()) {
            let ta = trimTrailing(out[a])
            for suffix in [":||:", ":|:", "::"] where ta.hasSuffix(suffix) && !ta.hasSuffix("|" + suffix) {
                out[a] = String(ta.dropLast(suffix.count)) + ":|"
                out[b] = "|: " + out[b].drop(while: { $0 == " " || $0 == "\t" })
                break
            }
        }
        return (head + closeLaterEndings(leadingFieldsAsLines(out))).joined(separator: "\n")
    }

    /// FONN-LEADFIELD-1. A time or key change written at the very start of a
    /// line ("[M:2/4] A B c z") is drawn by abcjs at the END of the line
    /// before, and the new line starts with none (An Alarc'h). The same
    /// change on a line of its own ("M:2/4") is drawn at the start of the
    /// line it opens. So a line's leading [M:…] / [K:…] become field lines
    /// above it. Not a note changes; nothing after a second X: is touched.
    /// FONN-CLOSEEND-1. abcjs closes a second-time bar only at a double bar
    /// or a repeat sign. One that ends its line with a plain | before the
    /// next part's |: is closed on the next line instead, and draws a stub of
    /// bracket at its start (Dark Water, parts B and C). So that | becomes
    /// ||, when the ending began on the same line and the next music line
    /// opens a part (|: or a P: line before it).
    static func closeLaterEndings(_ lines: [String]) -> [String] {
        var out = lines
        for (i, line) in lines.enumerated() {
            if startsField(line, "X") { break }
            guard !isBlank(line), !isFieldLine(line) else { continue }
            let t = trimTrailing(line)
            guard t.hasSuffix("|"), !t.hasSuffix("||"), !t.hasSuffix(":|"), !t.hasSuffix("[|") else { continue }
            let chars = Array(t)
            var start: Int?
            for j in 0..<(chars.count - 1) where (chars[j] == "[" || chars[j] == "|")
                && "23456789".contains(chars[j + 1]) { start = j }
            guard let s = start else { continue }
            let tail = String(chars[(s + 1)...])
            guard ![":|", "||", "|]", "|:", "::"].contains(where: { tail.contains($0) }) else { continue }
            var opensPart = false
            for next in lines[(i + 1)...] {
                if isBlank(next) { continue }
                if isFieldLine(next) { if startsField(next, "P") { opensPart = true }; continue }
                let n = next.drop(while: { $0 == " " || $0 == "\t" })
                if n.hasPrefix("|:") || n.hasPrefix("[|") || n.hasPrefix("::") { opensPart = true }
                break
            }
            if opensPart { out[i] = t + "|" }
        }
        return out
    }

    static func leadingFieldsAsLines(_ lines: [String]) -> [String] {
        var out: [String] = []
        var second = false
        for line in lines {
            if startsField(line, "X") { second = true }
            guard !second, !isBlank(line), !isFieldLine(line) else { out.append(line); continue }
            var rest = Substring(line).drop(while: { $0 == " " || $0 == "\t" })
            var fields: [String] = []
            while rest.hasPrefix("[M:") || rest.hasPrefix("[K:"), let close = rest.firstIndex(of: "]") {
                fields.append(rest[rest.index(after: rest.startIndex)..<close]
                    .trimmingCharacters(in: .whitespaces))
                rest = rest[rest.index(after: close)...].drop(while: { $0 == " " || $0 == "\t" })
            }
            guard !fields.isEmpty else { out.append(line); continue }
            out.append(contentsOf: fields)
            if !rest.isEmpty { out.append(String(rest)) }
        }
        return out
    }

    struct Item {
        let isBar: Bool
        let text: String
    }

    /// A line of music cut into note runs and bar lines. Chord symbols,
    /// decorations, grace notes, inline fields, tuplets and comments are kept
    /// whole inside the runs, so a | or : inside them is never a bar line.
    static func items(_ line: String) -> [Item] {
        let c = Array(line)
        let n = c.count
        var out: [Item] = []
        var cur = ""
        var i = 0
        func find(_ ch: Character, from start: Int) -> Int? {
            var j = start
            while j < n { if c[j] == ch { return j }; j += 1 }
            return nil
        }
        func isDigit(_ ch: Character) -> Bool { ch.isASCII && ch.isNumber }
        while i < n {
            let ch = c[i]
            if ch == "\"" {
                let j = find("\"", from: i + 1) ?? (n - 1)
                cur += String(c[i...j]); i = j + 1; continue
            }
            if ch == "!" || ch == "+" || ch == "{" {
                let close: Character = ch == "{" ? "}" : ch
                if let j = find(close, from: i + 1), j > i,
                   ch == "{" || (j - i <= 25 && !c[i..<j].contains(" ")) {
                    cur += String(c[i...j]); i = j + 1; continue
                }
            }
            if ch == "%" {
                cur += String(c[i...]); break
            }
            if ch == "[" && i + 2 < n && c[i + 1].isLetter && c[i + 2] == ":" {
                let j = find("]", from: i + 1) ?? (n - 1)
                cur += String(c[i...j]); i = j + 1; continue
            }
            if ch == "(" && i + 1 < n && isDigit(c[i + 1]) {
                var j = i + 2
                for _ in 0..<2 where j < n && c[j] == ":" {
                    j += 1
                    while j < n && isDigit(c[j]) { j += 1 }
                }
                cur += String(c[i..<j]); i = j; continue
            }
            if ch == "|" || ch == ":" || (ch == "[" && i + 1 < n && (c[i + 1] == "|" || isDigit(c[i + 1]))) {
                var j = i
                while j < n {
                    let d = c[j]
                    if d == "|" || d == ":" { j += 1 }
                    else if d == "]" && j > i && c[j - 1] == "|" { j += 1 }
                    else if d == "[" && j + 1 < n && (c[j + 1] == "|" || isDigit(c[j + 1])) { j += 1 }
                    else { break }
                }
                var k2 = j
                while k2 < n && (isDigit(c[k2]) || (k2 > j && (c[k2] == "," || c[k2] == "-"))) { k2 += 1 }
                out.append(Item(isBar: false, text: cur)); cur = ""
                out.append(Item(isBar: true, text: String(c[i..<k2]))); i = k2; continue
            }
            cur.append(ch); i += 1
        }
        out.append(Item(isBar: false, text: cur))
        return out
    }

    /// Notes and rests in a run, the yardstick for spotting a pickup.
    static func notesIn(_ seg: String) -> Int {
        seg.replacingOccurrences(of: #""[^"]*"|![^!]*!|\{[^}]*\}|\[[A-Za-z]:[^\]]*\]|%.*"#,
                                 with: "", options: .regularExpression)
            .filter { "ABCDEFGabcdefgz".contains($0) }.count
    }

    /// The ending a bar line starts: 1 for |1 or [1, 2 for :|2, nil for none.
    static func ending(_ tok: String) -> Int? {
        tok.first(where: { $0.isASCII && $0.isNumber }).flatMap { $0.wholeNumberValue }
    }

    static func hasNotes(_ items: [Item]) -> Bool {
        items.contains { !$0.isBar && notesIn($0.text) > 0 }
    }

    /// A bar line that ends a part: :| || |] :: with no later ending after it.
    static func isPartEnd(_ items: [Item], _ i: Int) -> Bool {
        let tok = items[i].text
        if ending(tok) != nil { return false }
        if ![":|", "||", "|]", "::"].contains(where: { tok.contains($0) }) { return false }
        var j = i + 1
        while j < items.count {
            let it = items[j]
            if !it.isBar {
                if notesIn(it.text) > 0 { return true }
            } else if let e = ending(it.text), e >= 2 {
                return false
            } else {
                return true
            }
            j += 1
        }
        return false
    }

    /// FONN-ENDING-1. If a line opens with a second (or later) ending: that
    /// ending, up to where the next part starts, and the rest of the line.
    static func leadingLaterEnding(_ line: String) -> (moved: String, rest: String)? {
        let all = items(line)
        guard let first = all.firstIndex(where: {
                  $0.isBar || !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }),
              all[first].isBar, let e = ending(all[first].text), e >= 2 else { return nil }
        for n in (first + 1)..<all.count where all[n].isBar {
            let x = all[n].text
            if x.hasSuffix("|:") && !x.contains(":|") && ending(x) == nil {
                let before = all[..<n].map(\.text).joined()
                let lastIsBar = all[..<n].last(where: {
                    $0.isBar || !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })?.isBar ?? false
                let close = x.count > 2 ? String(x.dropLast(2)) : (lastIsBar ? "" : "|")
                return (before + close, "|:" + all[(n + 1)...].map(\.text).joined())
            }
            if (x.contains("||") || x.contains("|]")) && ending(x) == nil {
                return (all[...n].map(\.text).joined(), all[(n + 1)...].map(\.text).joined())
            }
        }
        return (line, "")
    }

    static func splitParts(_ line: String) -> [[Item]] {
        let all = items(line)
        var parts: [[Item]] = []
        var cur: [Item] = []
        for (i, it) in all.enumerated() {
            // A start repeat in the middle of a line begins a new part: the
            // part before ends with a bar line, and the new one starts with |:.
            if it.isBar && it.text.hasSuffix("|:") && !it.text.contains(":|") && ending(it.text) == nil
                && cur.filter({ !$0.isBar && notesIn($0.text) > 0 }).count >= 2 {
                let lastBar = cur.last(where: { $0.isBar || !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })?.isBar ?? false
                if it.text.count > 2 {
                    cur.append(Item(isBar: true, text: String(it.text.dropLast(2))))
                } else if !lastBar {
                    cur.append(Item(isBar: true, text: "|"))
                }
                parts.append(cur)
                cur = [Item(isBar: true, text: "|:")]
                continue
            }
            cur.append(it)
            if it.isBar && isPartEnd(all, i) {
                parts.append(cur); cur = []
            }
        }
        if hasNotes(cur) || parts.isEmpty { parts.append(cur) }
        else { parts[parts.count - 1].append(contentsOf: cur) }
        return parts
    }

    static func phrasePart(_ items: [Item]) -> (text: String, bars: Int) {
        let segs = items.indices.filter { !items[$0].isBar && notesIn(items[$0].text) > 0 }
        if segs.isEmpty {
            return (items.map(\.text).joined().trimmingCharacters(in: .whitespaces), 0)
        }
        let counts = segs.map { notesIn(items[$0].text) }
        let median = counts.sorted()[counts.count / 2]
        var counted = Set<Int>()
        for (idx, i) in segs.enumerated() {
            let opening = i > 0 ? items[i - 1].text : ""
            if idx == 0 && segs.count > 1 && counts[idx] * 2 < median { continue }   // pickup
            if let e = ending(opening), e >= 2 { continue }                          // a later ending
            counted.insert(i)
        }
        let total = counted.count
        let per = total <= 5 ? total : (total % 4 == 0 ? 4 : (total % 3 == 0 ? 3 : 4))
        var out = ""
        var c = 0
        var pending = false
        for (i, it) in items.enumerated() {
            if it.isBar {
                var text = it.text
                let e = ending(text)
                if pending && e == 1 {
                    // Break before the first ending: after the bar line if the
                    // ending is written [1, otherwise before the whole bar line.
                    if let cut = text.firstIndex(of: "["), cut > text.startIndex {
                        out += String(text[..<cut])
                        text = String(text[cut...])
                    }
                    out += "\n"; pending = false
                }
                out += text
                if pending && e == nil { out += "\n"; pending = false }
            } else {
                out += it.text
                if counted.contains(i) {
                    c += 1
                    if c % per == 0 && c < total { pending = true }
                }
            }
        }
        let text = out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return (text, total)
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

    /// FONN-ONEVOICE-1: the voices a tune names, in V: lines and [V:] fields.
    static func voiceIDs(_ lines: [String]) -> Set<String> {
        var ids = Set<String>()
        for line in lines {
            if startsField(line, "V") {
                let rest = line.drop(while: { $0 == " " || $0 == "\t" }).dropFirst(2)
                ids.insert(rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? "")
            }
            var search = line[...]
            while let r = search.range(of: "[V:") {
                let after = search[r.upperBound...].drop(while: { $0 == " " })
                let id = after.prefix(while: { $0 != "]" && $0 != " " })
                ids.insert(String(id))
                search = after
            }
        }
        return ids
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
