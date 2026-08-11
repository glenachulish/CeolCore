import Foundation

/// Set-related ABC construction, ported from the Fonn web app (v3 app.js):
/// cleaning (expandAbcRepeats), bar extraction, transition snippets, and the
/// single-tune combined playback ABC with per-tune repeats.
public enum SetABCBuilder {

    // MARK: - Cleaning (port of expandAbcRepeats)

    /// Clean a tune's ABC for reliable abcjs rendering: inject X: if missing,
    /// strip %%MIDI / I:linebreak directives (either silently kills abcjs
    /// rendering), normalise bare "!" line breaks, collapse blank lines.
    public static func cleanABC(_ abc: String) -> String {
        var abc = abc
        if abc.range(of: #"(?m)^X:"#, options: .regularExpression) == nil {
            abc = "X:1\n" + abc
        }
        guard let kRange = abc.range(of: #"(?m)^K:[^\n]*\n?"#, options: .regularExpression) else {
            return abc
        }
        func strip(_ s: String) -> String {
            var s = s
            for pattern in [#"(?mi)^%%MIDI\s+.*$"#,
                            #"(?mi)^%abcjs_soundfont\s+\S+\s*$"#,
                            #"(?mi)^I:linebreak\s+.*$"#] {
                s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
            return s.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        }
        let header = strip(String(abc[abc.startIndex..<kRange.upperBound]))
        var body = strip(String(abc[kRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines))

        if body.contains("!") {
            // Protect !decoration! pairs with a sentinel, convert remaining
            // bare ! (old ABC line-break convention) to newlines, restore.
            let re = try? NSRegularExpression(pattern: "![a-zA-Z][a-zA-Z0-9_-]*!")
            if let re {
                let ns = body as NSString
                var rebuilt = ""
                var last = 0
                for match in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                    rebuilt += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                    let dec = ns.substring(with: match.range) // e.g. "!trill!"
                    rebuilt += "\u{1}" + dec.dropFirst().dropLast() + "\u{1}"
                    last = match.range.location + match.range.length
                }
                rebuilt += ns.substring(from: last)
                rebuilt = rebuilt.replacingOccurrences(of: #"\s*!\s*"#, with: "\n",
                                                       options: .regularExpression)
                body = rebuilt.replacingOccurrences(of: "\u{1}", with: "!")
            }
        }
        let sep = header.hasSuffix("\n") ? "" : "\n"
        return header + sep + body
    }

    // MARK: - Field helpers

    public static func field(_ abc: String, _ name: String) -> String? {
        guard let r = abc.range(of: "(?m)^\(name):\\s*(.+)$", options: .regularExpression) else {
            return nil
        }
        let line = String(abc[r])
        return line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
    }

    /// Music body after the K: line, with field lines and %% directives removed
    /// (port of extractBody).
    public static func body(_ abc: String) -> String {
        guard let kRange = abc.range(of: #"(?m)^K:[^\n]*"#, options: .regularExpression) else {
            return ""
        }
        var body = String(abc[kRange.upperBound...])
        body = body.replacingOccurrences(of: #"(?m)^[A-Za-z]:[^\n]*"#, with: "",
                                         options: .regularExpression)
        body = body.replacingOccurrences(of: #"%%[^\n]*"#, with: "",
                                         options: .regularExpression)
        body = body.replacingOccurrences(of: #"\n{2,}"#, with: "\n",
                                         options: .regularExpression)
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bars of the tune body (port of extractBars).
    public static func bars(_ abc: String) -> [String] {
        guard let kRange = abc.range(of: #"(?m)^K:[^\n]*"#, options: .regularExpression) else {
            return []
        }
        var music = String(abc[kRange.upperBound...])
        music = music.replacingOccurrences(of: #"(?m)^[A-Za-z]:[^\n]*"#, with: "",
                                           options: .regularExpression)
        music = music.replacingOccurrences(of: #"%[^\n]*"#, with: "", options: .regularExpression)
        music = music.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return music.split(separator: "|").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: ":[] "))
        }.filter { !$0.isEmpty }
    }

    // MARK: - Transitions (port of buildTransitionAbc)

    /// Last few bars of tune A into the first few of tune B, each group on its
    /// own staff line — for practising the join between tunes in a set.
    ///
    /// Two things this got wrong when it was a straight port of the Pi's
    /// `buildTransitionAbc`:
    ///
    /// **Nothing marked the join.** The two groups were separated by a newline
    /// and nothing else, so the page showed six bars with no indication of
    /// which three belonged to which tune — and a newline is only a hint to
    /// the engraver, not a boundary. There is now a double barline where one
    /// tune ends, and each group is named above the staff.
    ///
    /// **The second tune was engraved in the first tune's key.** One `K:` was
    /// taken from tune A and applied to the whole thing. Sets change key more
    /// often than not: The Leitrim Fancy into Langstrom's Pony is D major into
    /// A mixolydian. That pair happens to share a key signature so nothing
    /// looked wrong, which is exactly why it went unnoticed — a pair that
    /// didn't would have had its accidentals quietly rewritten. Whatever tune B
    /// does differently is now declared inline at the join, the same way
    /// `combinedPlaybackABC` already does it.
    public static func transitionABC(from tuneA: Tune, to tuneB: Tune) -> String? {
        let barsA = bars(tuneA.abc)
        let barsB = bars(tuneB.abc)
        guard !barsA.isEmpty, !barsB.isEmpty else { return nil }
        let lastBars = Array(barsA.suffix(3))
        let firstBars = Array(barsB.prefix(3))

        let meter = field(tuneA.abc, "M") ?? "4/4"
        let len = field(tuneA.abc, "L") ?? "1/8"
        let key = field(tuneA.abc, "K") ?? "C"

        var change = ""
        if let m = field(tuneB.abc, "M"), m != meter { change += "[M:\(m)]" }
        if let l = field(tuneB.abc, "L"), l != len { change += "[L:\(l)]" }
        if let k = field(tuneB.abc, "K"), k != key { change += "[K:\(k)]" }

        // Spoken form, so the staff says "The Leitrim Fancy" and not
        // "Leitrim Fancy, The".
        let nameA = annotation(TitleDisplay.plain(tuneA.title))
        let nameB = annotation(TitleDisplay.plain(tuneB.title))

        // The annotation goes after the opening barline and before the first
        // note: ABC attaches "^text" to what follows it, and a barline is not
        // something it can attach to.
        //
        // No blank lines anywhere in here. A blank line ends a tune in ABC, and
        // one inserted between the two groups would end the piece at the join
        // and silently drop tune B.
        return """
            X:1
            T:\(nameA) into \(nameB)
            M:\(meter)
            L:\(len)
            K:\(key)
            |"^\(nameA)"\(lastBars.joined(separator: "|"))||
            \(change)|"^\(nameB)"\(firstBars.joined(separator: "|"))|
            """
    }

    /// A title safe to put inside an ABC annotation. Double quotes close the
    /// annotation early and a backslash escapes the next character, so both
    /// would corrupt everything after them on the line.
    private static func annotation(_ title: String) -> String {
        title
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Combined playback (port of buildCombinedPlaybackAbc)

    /// Merge all tunes of a set into ONE X:1 tune with inline [M:][L:][K:]
    /// changes between sections and each tune's body repeated per its repeats
    /// setting — this is how the Pi plays a whole set straight through.
    public static func combinedPlaybackABC(entries: [SetEntry], setName: String) -> String? {
        let withABC = entries.compactMap { entry -> (tune: Tune, repeats: Int)? in
            guard let tune = entry.tune,
                  !tune.abc.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (tune, max(1, min(3, entry.repeats)))
        }
        guard let first = withABC.first else { return nil }

        let meter = field(first.tune.abc, "M") ?? "4/4"
        let len = field(first.tune.abc, "L") ?? "1/8"
        let key = field(first.tune.abc, "K") ?? "C"

        var combined = "X:1\nT:\(setName)\nM:\(meter)\nL:\(len)\nK:\(key)\n"

        for (i, item) in withABC.enumerated() {
            let abc = cleanABC(item.tune.abc)
            var prefix = ""
            if i > 0 {
                if let m = field(item.tune.abc, "M"), m != meter { prefix += "[M:\(m)]" }
                if let l = field(item.tune.abc, "L"), l != len { prefix += "[L:\(l)]" }
                if let k = field(item.tune.abc, "K") { prefix += "[K:\(k)]" }
                if !prefix.isEmpty { prefix += "\n" }
            }
            // % comment for the title: invisible to both parsers (a %%text
            // directive would stop abcjs's visual renderer mid-tune).
            let titleLine = "% \(item.tune.title)\n"
            let tuneBody = body(abc)
            // Joined with " " so repeats don't fuse last/first bars.
            let repeated = Array(repeating: tuneBody, count: item.repeats).joined(separator: " ")
            combined += prefix + titleLine + repeated + "\n"
        }
        return combined
    }
}
