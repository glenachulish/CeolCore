import Foundation

// FONN-METRO-3
/// The usual time signature and a moderate practice tempo for each kind of
/// tune, for when there is no notation to read them from — a tune that is
/// only a PDF or a photograph, or the moment before the music page has
/// reported.
///
/// The tempo is in the beats the music page counts: crotchets in 2/4, 3/4 and
/// 4/4, dotted crotchets in 6/8, 9/8 and 12/8. They are on the steady side of
/// session speed, because a click you can't keep up with is no use, and
/// "Save for this tune" is there for the rest.
public enum TuneTypeDefaults {
    private static let table: [String: (meter: String, bpm: Int)] = [
        "reel": ("4/4", 180),
        "jig": ("6/8", 100),
        "double jig": ("6/8", 100),
        "slip jig": ("9/8", 100),
        "single jig": ("6/8", 105),
        "slide": ("12/8", 115),
        "hornpipe": ("4/4", 140),
        "polka": ("2/4", 130),
        "waltz": ("3/4", 140),
        "mazurka": ("3/4", 130),
        "barndance": ("4/4", 150),
        "barn dance": ("4/4", 150),
        "fling": ("4/4", 140),
        "highland": ("4/4", 140),
        "strathspey": ("4/4", 120),
        "march": ("2/4", 100),
        "pipe march": ("2/4", 90),
        "three-two": ("3/2", 120),
        "schottische": ("4/4", 140),
        "air": ("3/4", 70),
        "slow air": ("3/4", 70),
    ]

    private static func entry(for type: String) -> (meter: String, bpm: Int)? {
        let key = type.trimmingCharacters(in: .whitespaces).lowercased()
        if let found = table[key] { return found }
        // "Reels", "Jig (single)" and the like.
        let simple = key.hasSuffix("s") ? String(key.dropLast()) : key
        if let found = table[simple] { return found }
        return table.first { key.hasPrefix($0.key) }?.value
    }

    /// The usual time signature for a kind of tune, or nil if unknown.
    public static func meter(for type: String) -> String? { entry(for: type)?.meter }

    /// A moderate tempo for a kind of tune, or nil if unknown.
    public static func tempo(for type: String) -> Int? { entry(for: type)?.bpm }
}
