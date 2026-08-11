import Foundation

/// The circle of fifths, and which tunes sit next to which.
///
/// Ported from the Fonn web app's `_COF_KEY_SIGS` / `_COF_TEMPLATES` and the
/// Pi's compatible-keys endpoint. It lived inside `SetBuilderView` on iOS,
/// which was fine while one app used it and is not now that two do — the
/// key-signature table and the way a stored key is read are exactly the parts
/// that must not drift between the phone and the Mac.
///
/// Nothing here touches SwiftData beyond reading a `Tune`'s key and mode, so
/// it can be reasoned about and, when it comes to it, tested.
public enum CircleOfFifths {

    /// How many sharps (positive) or flats (negative) each key carries.
    ///
    /// Modes are listed explicitly rather than derived, because trad music
    /// lives in dorian and mixolydian and deriving them from a major would put
    /// A dorian at three sharps instead of none — which is the difference
    /// between a suggestion that plays and one that fights.
    public static let keySigs: [String: Int] = [
        "C major": 0, "G major": 1, "D major": 2, "A major": 3,
        "E major": 4, "B major": 5, "F# major": 6,
        "F major": -1, "Bb major": -2, "Eb major": -3, "Ab major": -4,
        "A minor": 0, "A aeolian": 0, "E minor": 1, "E aeolian": 1,
        "B minor": 2, "B aeolian": 2, "F# minor": 3, "F# aeolian": 3,
        "C# minor": 4, "G# minor": 5, "D minor": -1, "G minor": -2, "C minor": -3,
        "D dorian": 0, "A dorian": 1, "E dorian": 2, "B dorian": 3,
        "F# dorian": 4, "G dorian": -1, "C dorian": -2,
        "G mixolydian": 0, "D mixolydian": 1, "A mixolydian": 2,
        "E mixolydian": 3, "C mixolydian": -1, "F mixolydian": -2,
    ]

    /// A canonical "D major" / "A dorian" name for a tune, tolerant of how the
    /// key and mode are actually stored.
    ///
    /// Blank modes, abbreviations like "dor"/"mix"/"m", and a mode baked into
    /// the key field such as "Ador" all occur in this library. Without this,
    /// tunes never match the table above and every suggestion collapses into
    /// one undifferentiated list.
    public static func keyName(of tune: Tune) -> String {
        keyName(key: tune.key, mode: tune.mode)
    }

    public static func keyName(key: String, mode: String) -> String {
        var letter = key.trimmingCharacters(in: .whitespaces)
        var rawMode = mode.trimmingCharacters(in: .whitespaces).lowercased()

        // Key field carrying its own mode, e.g. "Ador", "Bbmaj", "Em".
        if letter.count > 2 || (letter.count == 2 && !"#b".contains(letter.last!)) {
            let (parsedKey, parsedMode) = ABCParser.parseKeyField(letter)
            letter = parsedKey
            if rawMode.isEmpty { rawMode = parsedMode }
        }

        guard !letter.isEmpty else { return "" }
        // Normalise the letter: uppercase note, lowercase accidental.
        var normalised = letter.prefix(1).uppercased()
        if letter.count > 1 {
            let accidental = letter.dropFirst().prefix(1)
            if accidental == "#" { normalised += "#" }
            else if accidental.lowercased() == "b" { normalised += "b" }
        }

        let named: String
        switch true {
        case rawMode.isEmpty, rawMode.hasPrefix("maj"), rawMode.hasPrefix("ion"): named = "major"
        case rawMode.hasPrefix("dor"): named = "dorian"
        case rawMode.hasPrefix("mix"): named = "mixolydian"
        case rawMode.hasPrefix("aeo"), rawMode.hasPrefix("min"), rawMode == "m": named = "minor"
        case rawMode.hasPrefix("lyd"): named = "lydian"
        case rawMode.hasPrefix("phr"): named = "phrygian"
        case rawMode.hasPrefix("loc"): named = "locrian"
        default: named = rawMode
        }
        return "\(normalised) \(named)"
    }

    /// Display form used on badges: "D Minor", "G Dorian" (as on the Pi).
    public static func badge(_ name: String) -> String {
        name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: - What goes next

    /// How one key stands to another, in the order the Pi offers them.
    ///
    /// The order is the point: "same key signature" first because it is the
    /// safest join, then a fifth either way because that is the move that
    /// actually sounds like a set turning a corner, then two steps for when
    /// you want the lift.
    public struct Relationship: Identifiable, Hashable, Sendable {
        public let name: String
        /// Steps round the circle from the tune you are leaving.
        public let delta: Int
        public var id: Int { delta }

        public init(name: String, delta: Int) {
            self.name = name
            self.delta = delta
        }
    }

    public static let relationships: [Relationship] = [
        Relationship(name: "Same key signature", delta: 0),
        Relationship(name: "Up a fifth (brighter)", delta: 1),
        Relationship(name: "Down a fifth (mellower)", delta: -1),
        Relationship(name: "Two steps up", delta: 2),
        Relationship(name: "Two steps down", delta: -2),
    ]

    /// The signature of a key name, or nil if it is not on the circle.
    public static func signature(of keyName: String) -> Int? { keySigs[keyName] }

    /// Every key name sharing a signature — "G major", "E minor", "D dorian"
    /// and "A mixolydian" are all no sharps and no flats, and a tune in any of
    /// them will sit beside a tune in any other.
    public static func keys(withSignature sig: Int) -> [String] {
        keySigs.filter { $0.value == sig }.map(\.key).sorted()
    }

    /// The keys that follow well from this one, grouped by how they relate.
    ///
    /// Returns nothing for a key that isn't on the circle rather than guessing
    /// — a tune stored as "Hp" or with an empty key should produce no advice,
    /// not confident wrong advice.
    public static func following(_ keyName: String) -> [(Relationship, [String])] {
        guard let sig = signature(of: keyName) else { return [] }
        return relationships.compactMap { relationship in
            let found = keys(withSignature: sig + relationship.delta)
            return found.isEmpty ? nil : (relationship, found)
        }
    }

    // MARK: - Ready-made shapes

    public struct Template: Identifiable, Hashable, Sendable {
        public let id: Int
        public let name: String
        public let description: String
        /// Key names, in running order.
        public let slots: [String]

        public init(id: Int, name: String, description: String, slots: [String]) {
            self.id = id
            self.name = name
            self.description = description
            self.slots = slots
        }
    }

    public static let templates: [Template] = [
        Template(id: 1, name: "G–D–E Triangle",
                 description: "Neighbours on the circle + relative minor. Most common Irish set shape.",
                 slots: ["G major", "D major", "E dorian"]),
        Template(id: 2, name: "A–B Pair",
                 description: "A major into B dorian — same key signature, common in Scottish music.",
                 slots: ["A major", "B dorian"]),
        Template(id: 3, name: "D–A Fifth",
                 description: "Up a fifth from D to A. The set brightens as it goes.",
                 slots: ["D major", "A major"]),
        Template(id: 4, name: "Modal Journey",
                 description: "A dorian → G major → D major. Introduces the C♯ as the set progresses.",
                 slots: ["A dorian", "G major", "D major"]),
    ]

    // MARK: - The wheel itself

    /// The twelve positions round the circle, sharpwards from C.
    ///
    /// Stops at six sharps and four flats because that is where the library
    /// stops: the table above has no Db or Cb, and drawing empty spokes for
    /// keys no trad tune is ever in would be decoration rather than
    /// information. Index is the signature, which is what makes the maths
    /// above and the drawing below the same thing.
    public static let wheel: [Int] = Array(-4...6)

    /// The major key at a position, for labelling the outer ring.
    public static func major(atSignature sig: Int) -> String? {
        keys(withSignature: sig).first { $0.hasSuffix(" major") }
    }

    /// The minor at a position, for the inner ring — its relative.
    public static func minor(atSignature sig: Int) -> String? {
        keys(withSignature: sig).first { $0.hasSuffix(" minor") }
    }

    /// Tunes grouped by key name, built in one pass.
    ///
    /// One pass matters: this used to filter the whole library once per key,
    /// which with 1,557 records made every click on the wheel visibly slow.
    public static func index(_ tunes: [Tune]) -> [String: [Tune]] {
        var index: [String: [Tune]] = [:]
        for tune in tunes {
            index[keyName(of: tune).lowercased(), default: []].append(tune)
        }
        return index
    }
}
