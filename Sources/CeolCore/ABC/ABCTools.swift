import Foundation

/// Small edits to ABC text that the Pi offers and this app didn't.
///
/// Both are ports of `main.py`: `strip_tune_chords` and the `Q:` writer behind
/// "Set tempo". They work on the notation itself, so the result is permanent
/// and travels with an export — unlike a display setting.
public enum ABCTools {

    /// Remove guitar chord symbols — the "Am" / "G/B" quoted strings — from a
    /// tune's body, leaving header lines alone. Someone else's chords are
    /// often wrong for how you play it, and they clutter the page.
    public static func stripChords(_ abc: String) -> (abc: String, removed: Int) {
        var removed = 0
        let lines = abc.components(separatedBy: "\n").map { line -> String in
            // A header line is a single letter (or %) followed by a colon.
            // Chords never appear there, and a K: or T: containing quotes
            // must not be mangled.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isHeaderLine(trimmed) { return line }
            let before = count(of: #""[^"]*""#, in: line)
            let stripped = line.replacingOccurrences(
                of: #""[^"]*""#, with: "", options: .regularExpression)
            removed += before
            return stripped
        }
        return (lines.joined(separator: "\n"), removed)
    }

    public static func hasChords(_ abc: String) -> Bool {
        abc.components(separatedBy: "\n").contains { line in
            !isHeaderLine(line.trimmingCharacters(in: .whitespaces))
                && count(of: #""[^"]*""#, in: line) > 0
        }
    }

    /// The tempo written into the notation, if any. `Q:` comes in several
    /// shapes: `Q:120`, `Q:1/4=120`, `Q:"Slowly" 1/4=60`.
    public static func tempo(in abc: String) -> Int? {
        guard let match = abc.range(of: #"(?m)^Q:\s*(?:[^=\n]+=\s*)?(\d+)"#,
                                    options: .regularExpression) else { return nil }
        let digits = abc[match].compactMap { $0.isNumber ? $0 : nil }
        // The leading "4" of "1/4=" would otherwise be swallowed into the
        // number, so take the trailing run.
        let text = String(abc[match])
        if let equals = text.lastIndex(of: "=") {
            return Int(text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces))
        }
        return Int(String(digits))
    }

    /// Write a tempo into the ABC, replacing any existing `Q:`. Placed after
    /// `L:` (or before `K:`) so it sits where the standard expects.
    public static func setTempo(_ bpm: Int, in abc: String) -> String {
        let line = "Q:1/4=\(bpm)"
        var lines = abc.components(separatedBy: "\n")

        if let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("Q:")
        }) {
            lines[index] = line
            return lines.joined(separator: "\n")
        }
        // No Q: yet — put it just before the key, which is the last header
        // line and where the body begins.
        if let keyIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("K:")
        }) {
            lines.insert(line, at: keyIndex)
            return lines.joined(separator: "\n")
        }
        return abc
    }

    /// Which instrument backs the tune, written into the notation as
    /// `%%MIDI chordprog`.
    ///
    /// abcjs takes the melody instrument as a synth parameter but has no such
    /// parameter for the chords — this build has no `chordsProgram` in it at
    /// all. What it does honour is the ABC MIDI directives, so the instrument
    /// is said in the ABC itself.
    ///
    /// Placed immediately after `K:`, which is where the header ends and the
    /// music begins. Measured through the jsdom harness before being relied on:
    /// a tune with these two lines renders identically to one without — same
    /// staves, same notes, same bars — so this is inaudible to the engraver and
    /// only reaches the synth. `bassprog` goes with it because abcjs plays a
    /// bass note under each chord and leaving it on the default gives you a
    /// guitar chord over a piano bass.
    ///
    /// Note that `SetABCBuilder.cleanABC` strips `%%MIDI` lines when it joins
    /// several tunes into one, so a set needs this applied per tune rather than
    /// to the combined ABC.
    ///
    /// Pass nil to take it out again and let abcjs use its own default.
    public static func setAccompaniment(_ program: Int?, in abc: String) -> String {
        var lines = abc.components(separatedBy: "\n")
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces).lowercased()
                return !t.hasPrefix("%%midi chordprog") && !t.hasPrefix("%%midi bassprog")
            }

        guard let program else { return lines.joined(separator: "\n") }

        guard let keyIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("K:")
        }) else {
            // No key line means no header to sit after, and a directive before
            // the music with nothing to anchor it is worse than none.
            return lines.joined(separator: "\n")
        }
        lines.insert(contentsOf: ["%%MIDI chordprog \(program)",
                                  "%%MIDI bassprog \(program)"],
                     at: keyIndex + 1)
        return lines.joined(separator: "\n")
    }

    // MARK: -

    private static func isHeaderLine(_ trimmed: String) -> Bool {
        guard trimmed.count >= 2 else { return false }
        let first = trimmed[trimmed.startIndex]
        guard first.isLetter || first == "%" else { return false }
        let rest = trimmed.dropFirst().drop(while: { $0 == " " })
        return rest.first == ":"
    }

    private static func count(of pattern: String, in text: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
