import Foundation
import Compression

/// MusicXML → ABC, ported from v3's `backend/musicxml2abc.py`.
///
/// Scope is the same: single-line traditional tunes. The first voice of the
/// first part is taken and everything else — second parts, piano left hands,
/// chord stacks — is dropped, because that is what a tune in this library is.
///
/// Beyond the Python, and worth knowing about because each is a place it could
/// be wrong:
///   • modes. `<mode>dorian</mode>` and `<mode>mixolydian</mode>` are ordinary
///     in trad and the Python turned both into major. K:Ador now comes out as
///     K:Ador.
///   • beaming. ABC beams notes that aren't separated by a space, so the
///     Python's bar-at-a-time output rendered a reel as one eight-note beam.
///     The printed beams are followed where the file has them, and the metre
///     is used where it doesn't.
///   • first and second endings, which nearly every tune has and the Python
///     silently discarded.
///   • triplets, written as (3 rather than as three notes of length 2/3.
///   • grace notes, which the Python skipped — they're the ornamentation.
///   • composer, and a tune type where the metre gives it away without a guess.
///
/// Public API: `convert(_:index:)`, or `source(from:filename:)` for the
/// importer, which wants an ABCImportPlan.Source and no thrown errors.
public enum MusicXMLToABC {

    /// What the router will hand to this.
    public static let fileExtensions = ["xml", "musicxml", "mxl"]

    public enum Failure: LocalizedError {
        case notMusicXML(String)
        case noPart
        case noNotes

        public var errorDescription: String? {
            switch self {
            case .notMusicXML(let why): return "Not MusicXML Ceòl can read — \(why)."
            case .noPart: return "No music found in that file."
            case .noNotes: return "That file has no notes in it."
            }
        }
    }

    // MARK: - Entry points

    public static func convert(_ data: Data, index: Int = 1) throws -> String {
        let xml = try unwrap(data)
        guard let root = XMLTree.parse(xml) else {
            throw Failure.notMusicXML("it wouldn't parse")
        }
        guard root.name == "score-partwise" else {
            throw Failure.notMusicXML(
                root.name == "score-timewise"
                ? "it's timewise MusicXML, which almost nothing writes and Ceòl doesn't read"
                : "the root element is <\(root.name)>")
        }
        return try build(from: root, index: index)
    }

    /// The importer's door: nothing thrown, nil when it can't be used.
    ///
    /// Where the file held more than one tune it was a set on the page, so it
    /// should be a set in the library too — the name of the work goes back with
    /// it so the review screen can offer to make one.
    public static func source(from data: Data, filename: String, index: Int = 1) -> ABCImportPlan.Source? {
        guard let abc = try? convert(data, index: index), !abc.isEmpty else { return nil }
        let tunes = abc.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("X:") }.count
        var setName: String?
        if tunes > 1 {
            if let xml = try? unwrap(data), let root = XMLTree.parse(xml) {
                let title = titleOf(root)
                if title != "Untitled" { setName = title }
            }
            if setName == nil {
                setName = (filename as NSString).deletingPathExtension
            }
        }
        return ABCImportPlan.Source(name: filename, text: abc, setName: setName)
    }

    private static func ordinal(_ n: Int) -> String {
        switch n {
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }

    // MARK: - The conversion

    private enum Token {
        case note(String)
        /// A beam break — in ABC a space is what stops notes being beamed.
        case space
        case bar(String)
        case lineBreak
    }

    /// What is in force at a given measure. Attributes usually appear once, in
    /// the first measure, so the second tune of a set has to inherit them.
    private struct Context {
        var divisions = 1
        var fifths = 0
        var mode = "major"
        var beats = 4
        var beatType = 4
    }

    private static func apply(_ attributes: XMLTree, to context: inout Context) {
        if let d = attributes.string("divisions"), let value = Int(d), value > 0 {
            context.divisions = value
        }
        if let key = attributes.child("key") {
            context.fifths = Int(key.string("fifths") ?? "0") ?? context.fifths
            context.mode = (key.string("mode") ?? context.mode).lowercased()
        }
        if let time = attributes.child("time") {
            context.beats = Int(time.string("beats") ?? "4") ?? context.beats
            context.beatType = Int(time.string("beat-type") ?? "4") ?? context.beatType
        }
    }

    private static func build(from root: XMLTree, index: Int) throws -> String {
        guard let part = root.all("part").first else { throw Failure.noPart }
        let measures = part.all("measure")
        guard !measures.isEmpty else { throw Failure.noNotes }

        // Follow the printed beams where there are any; fall back to the metre.
        let usesBeams = measures.contains { measure in
            measure.all("note").contains { $0.child("beam") != nil }
        }

        // What's in force at each measure, so a segment can start anywhere.
        var running = Context()
        var contexts: [Context] = []
        for measure in measures {
            if let attributes = measure.child("attributes") { apply(attributes, to: &running) }
            contexts.append(running)
        }

        let baseTitle = titleOf(root)
        let composer = composerOf(root)
        let groups = segments(measures, contexts: contexts)

        var tunes: [String] = []
        for (position, range) in groups.enumerated() {
            // The second and third tunes of a set are usually written without
            // their names — the name is on the set, at the top. A stand-in that
            // says which set it came from and where it sat in it is worth more
            // than "Untitled", and it is the obvious thing to rename later.
            let fallback = groups.count == 1 || position == 0
                ? baseTitle : "\(baseTitle) (\(Self.ordinal(position + 1)) tune)"
            let title = sectionTitle(measures[range.lowerBound]) ?? fallback
            guard let abc = try? render(measures: Array(measures[range]),
                                        contexts: Array(contexts[range]),
                                        title: title,
                                        composer: composer,
                                        usesBeams: usesBeams,
                                        index: index + position) else { continue }
            tunes.append(abc)
        }
        guard !tunes.isEmpty else { throw Failure.noNotes }
        return tunes.joined(separator: "\n")
    }

    /// Where one tune in a set ends and the next begins.
    ///
    /// A set exported as one file is one `<part>` with no marker saying "new
    /// tune" — MusicXML has no such thing. Three things stand in for it, and
    /// all three are how a set is actually written out:
    ///   • a double or final barline that isn't a repeat. A repeat's barline is
    ///     also `light-heavy`, so the `<repeat>` has to be excluded or every
    ///     part of every tune becomes its own tune.
    ///   • a rehearsal mark, which is what MuseScore puts at the head of each
    ///     tune in a set.
    ///   • a change of metre — a jig into a reel is a new tune, not a new part.
    ///
    /// Where none of them appear, this returns one segment and behaves exactly
    /// as it did before.
    private static func segments(_ measures: [XMLTree],
                                 contexts: [Context]) -> [Range<Int>] {
        var boundaries: [Int] = [0]

        for index in 1..<max(1, measures.count) {
            let previous = measures[index - 1]
            let closedOut = previous.all("barline").contains { barline in
                guard (barline.attributes["location"] ?? "right") == "right" else { return false }
                guard barline.child("repeat") == nil else { return false }
                let style = barline.string("bar-style") ?? ""
                return style == "light-heavy" || style == "final" || style == "light-light"
            }
            let marked = sectionTitle(measures[index]) != nil
            let meterChanged = contexts[index].beats != contexts[index - 1].beats
                || contexts[index].beatType != contexts[index - 1].beatType
            // A change of key signature. In a set this is all but decisive —
            // it is what shows up as an inline [K:D] when the same file goes
            // through other converters, and a tune does not change its key
            // signature half way through. Compared on the signature itself
            // rather than the mode, so D major into B minor is not read as two
            // tunes: they share the two sharps.
            let keyChanged = contexts[index].fifths != contexts[index - 1].fifths

            if closedOut || marked || meterChanged || keyChanged { boundaries.append(index) }
        }

        // A segment with no notes in it is a stray double barline, not a tune.
        var ranges: [Range<Int>] = []
        for (position, start) in boundaries.enumerated() {
            let end = position + 1 < boundaries.count ? boundaries[position + 1] : measures.count
            guard start < end else { continue }
            let hasNotes = measures[start..<end].contains { measure in
                measure.all("note").contains { $0.child("rest") == nil && $0.child("grace") == nil }
            }
            if hasNotes { ranges.append(start..<end) }
        }
        if ranges.isEmpty { ranges = [0..<measures.count] }

        // Two bars is not a tune — fold a runt back into the one before it.
        var merged: [Range<Int>] = []
        for range in ranges {
            if range.count < 3, let last = merged.last, last.upperBound == range.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<range.upperBound
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The name written over a tune in a set — a rehearsal mark, or a line of
    /// text that isn't a tempo or an expression mark.
    private static func sectionTitle(_ measure: XMLTree) -> String? {
        for direction in measure.all("direction") {
            for type in direction.all("direction-type") {
                if let rehearsal = type.string("rehearsal") { return rehearsal }
            }
        }
        for direction in measure.all("direction") {
            // A tempo has a <sound tempo="…"> beside it; a title doesn't.
            guard direction.child("sound")?.attributes["tempo"] == nil else { continue }
            guard direction.attributes["placement"] != "below" else { continue }
            for type in direction.all("direction-type") {
                guard let words = type.string("words"), words.count > 3 else { continue }
                let lower = words.lowercased()
                let markings = ["rit", "accel", "cresc", "dim", "fine", "coda", "segno",
                                "da capo", "d.c.", "d.s.", "poco", "molto", "swing"]
                if markings.contains(where: { lower.hasPrefix($0) }) { continue }
                return words
            }
        }
        return nil
    }

    private static func render(measures: [XMLTree],
                               contexts: [Context],
                               title: String,
                               composer: String,
                               usesBeams: Bool,
                               index: Int) throws -> String {
        guard let opening = contexts.first else { throw Failure.noNotes }
        let fifths = opening.fifths
        let mode = opening.mode
        let beats = opening.beats
        let beatType = opening.beatType

        var usesSystemBreaks = false
        var tokens: [Token] = []
        var firstVoice: String?
        var noteCount = 0

        for (position, measure) in measures.enumerated() {
            let divisions = contexts[position].divisions

            // Opening repeat: replace the plain barline before it rather than
            // emitting "| |:".
            for barline in measure.all("barline")
            where (barline.attributes["location"] ?? "right") == "left" {
                if let repeatEl = barline.child("repeat"),
                   repeatEl.attributes["direction"] == "forward" {
                    if case .bar(let last)? = tokens.last, last == "|" { tokens.removeLast() }
                    tokens.append(.bar("|:"))
                }
            }

            if measure.all("print").contains(where: { $0.attributes["new-system"] == "yes" }) {
                usesSystemBreaks = true
                tokens.append(.lineBreak)
            }

            // First / second time. "[1" reads the same as the more familiar
            // "|1" and doesn't depend on what came before it.
            for barline in measure.all("barline")
            where (barline.attributes["location"] ?? "right") == "left" {
                if let ending = barline.child("ending"),
                   ending.attributes["type"] == "start",
                   let number = ending.attributes["number"]?
                    .split(separator: ",").first?
                    .trimmingCharacters(in: .whitespaces),
                   !number.isEmpty {
                    tokens.append(.note("[\(number)"))
                }
            }

            let group = beamGroup(beats: beats, beatType: beatType)
            var positionInBar = Frac(0, 1)
            var pendingGrace: [String] = []
            var graceIsSlashed = false
            var tripletLeft = 0

            for note in measure.all("note") {
                // Only the top line of a chord: this library is monophonic.
                if note.child("chord") != nil { continue }

                // Grace notes have no duration; they're held and written into
                // the braces in front of the note they decorate.
                if let grace = note.child("grace") {
                    guard let pitch = note.child("pitch") else { continue }
                    if pendingGrace.isEmpty {
                        graceIsSlashed = grace.attributes["slash"] == "yes"
                    }
                    pendingGrace.append(accidentalPrefix(note, fifths: fifths) + abcPitch(pitch))
                    continue
                }

                let voice = note.string("voice")
                if firstVoice == nil, let v = voice { firstVoice = v }
                if let v = voice, let first = firstVoice, v != first { continue }

                // A triplet's <duration> is what it sounds, not what it looks
                // like. ABC's (3 does the shortening, so the notated length —
                // duration × actual ÷ normal — is what goes on the page.
                var actual = 1
                var normal = 1
                if let modification = note.child("time-modification") {
                    actual = Int(modification.string("actual-notes") ?? "1") ?? 1
                    normal = Int(modification.string("normal-notes") ?? "1") ?? 1
                }
                if actual < 1 { actual = 1 }
                if normal < 1 { normal = 1 }

                let rawDuration = Int(note.string("duration") ?? "0") ?? 0
                let isTriplet = (actual == 3 && normal == 2)
                let length = isTriplet
                    ? Frac(rawDuration * 2 * actual, divisions * normal)
                    : Frac(rawDuration * 2, divisions)

                if isTriplet {
                    if tripletLeft == 0 {
                        tokens.append(.note("(3"))
                        tripletLeft = 3
                    }
                    tripletLeft -= 1
                } else {
                    tripletLeft = 0
                }

                var text = ""
                if !pendingGrace.isEmpty {
                    text += "{" + (graceIsSlashed ? "/" : "") + pendingGrace.joined() + "}"
                    pendingGrace = []
                    graceIsSlashed = false
                }

                if note.child("rest") != nil {
                    text += "z" + lengthSuffix(length)
                } else if let pitch = note.child("pitch") {
                    text += accidentalPrefix(note, fifths: fifths) + abcPitch(pitch) + lengthSuffix(length)
                    if note.all("tie").contains(where: { $0.attributes["type"] == "start" }) {
                        text += "-"
                    }
                } else {
                    continue
                }

                tokens.append(.note(text))
                noteCount += 1

                positionInBar = positionInBar + length
                let breakBeam: Bool
                if usesBeams {
                    if let beam = note.all("beam")
                        .first(where: { ($0.attributes["number"] ?? "1") == "1" }) {
                        breakBeam = beam.text.trimmingCharacters(in: .whitespacesAndNewlines) == "end"
                    } else {
                        breakBeam = true    // nothing to beam it to
                    }
                } else {
                    breakBeam = positionInBar.d == 1 && positionInBar.n % group == 0
                }
                if breakBeam { tokens.append(.space) }
            }

            var closed = false
            for barline in measure.all("barline")
            where (barline.attributes["location"] ?? "right") == "right" {
                let style = barline.string("bar-style") ?? ""
                if let repeatEl = barline.child("repeat"),
                   repeatEl.attributes["direction"] == "backward" {
                    tokens.append(.bar(":|"))
                    closed = true
                } else if style == "light-heavy" || style == "final" {
                    tokens.append(.bar("|]"))
                    closed = true
                } else if style == "light-light" {
                    tokens.append(.bar("||"))
                    closed = true
                }
            }
            if !closed { tokens.append(.bar("|")) }
        }

        guard noteCount > 0 else { throw Failure.noNotes }

        var header = ["X:\(index)", "T:\(title)"]
        if !composer.isEmpty { header.append("C:\(composer)") }
        if let type = tuneType(beats: beats, beatType: beatType) { header.append("R:\(type)") }
        header.append("M:\(beats)/\(beatType)")
        header.append("L:1/8")
        header.append("K:\(keyName(fifths: fifths, mode: mode))")

        let body = assemble(tokens, fourBarLines: !usesSystemBreaks)
        return header.joined(separator: "\n") + "\n" + body + "\n"
    }

    /// Bars into lines. Four to a line unless the file said where the systems
    /// break, in which case it's followed.
    private static func assemble(_ tokens: [Token], fourBarLines: Bool) -> String {
        var lines: [String] = []
        var line = ""
        var bar = ""
        var barsOnLine = 0

        func endLine() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
            line = ""
            barsOnLine = 0
        }

        for token in tokens {
            switch token {
            case .note(let text):
                bar += text
            case .space:
                if !bar.isEmpty, !bar.hasSuffix(" ") { bar += " " }
            case .lineBreak:
                if bar.isEmpty { endLine() }
            case .bar(let symbol):
                let content = bar.trimmingCharacters(in: .whitespaces)
                let piece = content.isEmpty ? symbol : content + " " + symbol
                line += (line.isEmpty ? "" : " ") + piece
                bar = ""
                if !content.isEmpty {
                    barsOnLine += 1
                    if fourBarLines, barsOnLine >= 4 { endLine() }
                }
            }
        }
        let leftover = bar.trimmingCharacters(in: .whitespaces)
        if !leftover.isEmpty { line += (line.isEmpty ? "" : " ") + leftover }
        endLine()
        return lines.joined(separator: "\n")
    }

    // MARK: - Pitch, length, key

    private static func abcPitch(_ pitch: XMLTree) -> String {
        let step = (pitch.string("step") ?? "C").uppercased()
        let octave = Int(pitch.string("octave") ?? "4") ?? 4
        if octave >= 5 {
            return step.lowercased() + String(repeating: "'", count: octave - 5)
        }
        return step + String(repeating: ",", count: max(0, 4 - octave))
    }

    /// The printed accidental if there is one. Where a file leaves them out —
    /// some exporters do — `<alter>` is compared against the key signature and
    /// an accidental written only when they disagree, so nothing goes silently
    /// wrong.
    private static func accidentalPrefix(_ note: XMLTree, fifths: Int) -> String {
        if let printed = note.string("accidental") {
            switch printed {
            case "sharp":                    return "^"
            case "flat":                     return "_"
            case "natural":                  return "="
            case "double-sharp", "sharp-sharp": return "^^"
            case "flat-flat":                return "__"
            default:                         return ""
            }
        }
        guard let pitch = note.child("pitch") else { return "" }
        let alter = Int(Double(pitch.string("alter") ?? "0") ?? 0)
        let step = (pitch.string("step") ?? "C").uppercased()
        guard alter != keySignatureAlter(step: step, fifths: fifths) else { return "" }
        switch alter {
        case 2:  return "^^"
        case 1:  return "^"
        case 0:  return "="
        case -1: return "_"
        case -2: return "__"
        default: return ""
        }
    }

    private static func keySignatureAlter(step: String, fifths: Int) -> Int {
        guard let letter = step.first else { return 0 }
        if fifths > 0, "FCGDAEB".prefix(min(7, fifths)).contains(letter) { return 1 }
        if fifths < 0, "BEADGCF".prefix(min(7, -fifths)).contains(letter) { return -1 }
        return 0
    }

    private static let majorTonics: [Int: String] = [
        0: "C", 1: "G", 2: "D", 3: "A", 4: "E", 5: "B", 6: "F#", 7: "C#",
        -1: "F", -2: "Bb", -3: "Eb", -4: "Ab", -5: "Db", -6: "Gb", -7: "Cb",
    ]

    /// The tonic is a degree of the relative major, and the accidental on that
    /// letter comes from the key signature — so two sharps plus mixolydian is
    /// A, giving K:Amix, and no sharps plus dorian is D, giving K:Ddor.
    static func keyName(fifths: Int, mode: String) -> String {
        let letters = Array("CDEFGAB")
        let degree: Int
        let suffix: String
        switch mode {
        case "minor", "aeolian": degree = 5; suffix = "m"
        case "dorian":           degree = 1; suffix = "dor"
        case "phrygian":         degree = 2; suffix = "phr"
        case "lydian":           degree = 3; suffix = "lyd"
        case "mixolydian":       degree = 4; suffix = "mix"
        case "locrian":          degree = 6; suffix = "loc"
        default:                 degree = 0; suffix = ""
        }
        guard let major = majorTonics[fifths], let head = major.first,
              let start = letters.firstIndex(of: head) else { return "C" }
        let letter = letters[(start + degree) % 7]
        let alter = keySignatureAlter(step: String(letter), fifths: fifths)
        let accidental = alter > 0 ? "#" : (alter < 0 ? "b" : "")
        return "\(letter)\(accidental)\(suffix)"
    }

    private static func lengthSuffix(_ length: Frac) -> String {
        if length.d == 1 { return length.n == 1 ? "" : "\(length.n)" }
        let numerator = length.n == 1 ? "" : "\(length.n)"
        return "\(numerator)/\(length.d)"
    }

    /// How many eighths belong in a beam group. 6/8 beams in threes, a reel in
    /// fours, a waltz or a polka in twos.
    private static func beamGroup(beats: Int, beatType: Int) -> Int {
        if beatType == 8 { return 3 }
        if beatType == 4, beats <= 3 { return 2 }
        return 4
    }

    /// Only where the metre settles it. 4/4 and 2/2 are left blank rather than
    /// called reels, because that would mislabel every hornpipe in the file.
    private static func tuneType(beats: Int, beatType: Int) -> String? {
        switch (beats, beatType) {
        case (6, 8):  return "jig"
        case (9, 8):  return "slip jig"
        case (12, 8): return "slide"
        case (2, 4):  return "polka"
        case (3, 4):  return "waltz"
        case (3, 2):  return "three-two"
        default:      return nil
        }
    }

    private static func titleOf(_ root: XMLTree) -> String {
        if let title = root.child("work")?.string("work-title") { return title }
        if let title = root.string("movement-title") { return title }
        let credits = root.all("credit")
        if let titled = credits.first(where: { $0.string("credit-type") == "title" }),
           let words = titled.string("credit-words") { return words }
        for credit in credits {
            if let words = credit.string("credit-words") { return words }
        }
        return "Untitled"
    }

    private static func composerOf(_ root: XMLTree) -> String {
        guard let creators = root.child("identification")?.all("creator"),
              let composer = creators.first(where: { $0.attributes["type"] == "composer" })
        else { return "" }
        return composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Rationals

    private struct Frac {
        var n: Int
        var d: Int

        init(_ numerator: Int, _ denominator: Int) {
            let safe = denominator == 0 ? 1 : denominator
            let divisor = max(1, Frac.gcd(abs(numerator), abs(safe)))
            n = numerator / divisor
            d = safe / divisor
        }

        static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

        static func + (lhs: Frac, rhs: Frac) -> Frac {
            Frac(lhs.n * rhs.d + rhs.n * lhs.d, lhs.d * rhs.d)
        }
    }

    // MARK: - .mxl

    /// A .mxl is a zip. META-INF/container.xml names the score inside it.
    private static func unwrap(_ data: Data) throws -> Data {
        guard data.count > 4 else { return data }
        let start = data.startIndex
        guard data[start] == 0x50, data[start + 1] == 0x4B else { return data }

        guard let files = Zip.read(data) else {
            throw Failure.notMusicXML("that .mxl wouldn't open")
        }
        if let container = files["META-INF/container.xml"],
           let text = String(data: container, encoding: .utf8),
           let path = fullPath(in: text),
           let inner = files[path] {
            return inner
        }
        let candidates = files.keys
            .filter { name in
                !name.hasPrefix("META-INF") && !name.hasPrefix("__MACOSX")
                    && (name.lowercased().hasSuffix(".xml")
                        || name.lowercased().hasSuffix(".musicxml"))
            }
            .sorted()
        guard let first = candidates.first, let inner = files[first] else {
            throw Failure.notMusicXML("there's no MusicXML inside that .mxl")
        }
        return inner
    }

    private static func fullPath(in container: String) -> String? {
        guard let opening = container.range(of: "full-path=\"") else { return nil }
        let rest = container[opening.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let path = String(rest[..<end])
        return path.isEmpty ? nil : path
    }

    /// Just enough zip to open a .mxl: central directory, stored and deflated
    /// entries. No ZIP64 — a MusicXML score is a few tens of kilobytes.
    private enum Zip {
        static func read(_ data: Data) -> [String: Data]? {
            let bytes = [UInt8](data)
            guard let eocd = findEndOfCentralDirectory(bytes) else { return nil }
            let count = u16(bytes, eocd + 10)
            var offset = u32(bytes, eocd + 16)
            var found: [String: Data] = [:]

            for _ in 0..<count {
                guard offset + 46 <= bytes.count, u32(bytes, offset) == 0x0201_4b50 else { break }
                let method = u16(bytes, offset + 10)
                let compressedSize = u32(bytes, offset + 20)
                let uncompressedSize = u32(bytes, offset + 24)
                let nameLength = u16(bytes, offset + 28)
                let extraLength = u16(bytes, offset + 30)
                let commentLength = u16(bytes, offset + 32)
                let localOffset = u32(bytes, offset + 42)
                let nameEnd = min(bytes.count, offset + 46 + nameLength)
                let name = String(decoding: bytes[(offset + 46)..<nameEnd], as: UTF8.self)
                offset += 46 + nameLength + extraLength + commentLength

                // The local header repeats the name and extra lengths, and they
                // are allowed to differ from the central directory's.
                guard localOffset + 30 <= bytes.count,
                      u32(bytes, localOffset) == 0x0403_4b50 else { continue }
                let localNameLength = u16(bytes, localOffset + 26)
                let localExtraLength = u16(bytes, localOffset + 28)
                let dataStart = localOffset + 30 + localNameLength + localExtraLength
                let dataEnd = dataStart + compressedSize
                guard dataStart >= 0, dataEnd <= bytes.count, dataEnd >= dataStart else { continue }
                let payload = Data(bytes[dataStart..<dataEnd])

                if method == 0 {
                    found[name] = payload
                } else if method == 8,
                          let inflated = inflate(payload, expecting: uncompressedSize) {
                    found[name] = inflated
                }
            }
            return found.isEmpty ? nil : found
        }

        private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
            guard bytes.count >= 22 else { return nil }
            var index = bytes.count - 22
            let limit = max(0, bytes.count - 22 - 65_536)
            while index >= limit {
                if u32(bytes, index) == 0x0605_4b50 { return index }
                index -= 1
            }
            return nil
        }

        /// COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what a zip holds.
        private static func inflate(_ data: Data, expecting size: Int) -> Data? {
            guard size > 0, !data.isEmpty else { return size == 0 ? Data() : nil }
            var destination = Data(count: size)
            let written = destination.withUnsafeMutableBytes { raw -> Int in
                data.withUnsafeBytes { source -> Int in
                    guard let out = raw.bindMemory(to: UInt8.self).baseAddress,
                          let input = source.bindMemory(to: UInt8.self).baseAddress
                    else { return 0 }
                    return compression_decode_buffer(out, size, input, data.count,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            guard written > 0 else { return nil }
            return Data(destination.prefix(written))
        }

        private static func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
            guard offset >= 0, offset + 1 < bytes.count else { return 0 }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }

        private static func u32(_ bytes: [UInt8], _ offset: Int) -> Int {
            guard offset >= 0, offset + 3 < bytes.count else { return 0 }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
    }

    // MARK: - A very small XML tree

    /// iOS has no DOM — XMLDocument is macOS only — so XMLParser's events are
    /// gathered into a tree. External entities are refused: a MusicXML file's
    /// DOCTYPE points at a DTD on the web, and resolving it would mean a network
    /// fetch in the middle of an import.
    final class XMLTree {
        let name: String
        let attributes: [String: String]
        var text = ""
        var children: [XMLTree] = []

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        func child(_ name: String) -> XMLTree? { children.first { $0.name == name } }
        func all(_ name: String) -> [XMLTree] { children.filter { $0.name == name } }

        func string(_ name: String) -> String? {
            guard let node = child(name) else { return nil }
            let trimmed = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        static func parse(_ data: Data) -> XMLTree? {
            let builder = Builder()
            let parser = XMLParser(data: data)
            parser.delegate = builder
            parser.shouldProcessNamespaces = false
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            _ = parser.parse()
            return builder.root
        }

        private final class Builder: NSObject, XMLParserDelegate {
            var root: XMLTree?
            private var stack: [XMLTree] = []

            func parser(_ parser: XMLParser, didStartElement elementName: String,
                        namespaceURI: String?, qualifiedName qName: String?,
                        attributes attributeDict: [String: String] = [:]) {
                let local = elementName.contains(":")
                    ? String(elementName.split(separator: ":").last ?? "")
                    : elementName
                let node = XMLTree(name: local, attributes: attributeDict)
                if let parent = stack.last {
                    parent.children.append(node)
                } else {
                    root = node
                }
                stack.append(node)
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                stack.last?.text += string
            }

            func parser(_ parser: XMLParser, didEndElement elementName: String,
                        namespaceURI: String?, qualifiedName qName: String?) {
                _ = stack.popLast()
            }
        }
    }
}
