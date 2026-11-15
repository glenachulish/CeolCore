import Foundation

// FONN-METRO-3
/// The usual time signature and a moderate practice tempo for each kind of
/// tune, for when there is no notation to read them from — a tune that is
/// only a PDF or a photograph, or the moment before the music page has
/// reported.
///
/// FONN-TEMPO-1: the tempo is in the beats as a player counts them, and the
/// music page uses this same table (`CEOL_TYPE_TEMPO` in abctools.js) for any
/// tune with no Q:, so keep the two in step. Reels, hornpipes, strathspeys,
/// barndances and their kin are counted two to the bar (2/2, minims), the way
/// a foot taps them, so tapping along to a recording gives the same number.
/// Dotted crotchets in 6/8, 9/8 and 12/8; crotchets otherwise. On the steady
/// side of session speed; "Save for this tune" is there for the rest.
public enum TuneTypeDefaults {
    private static let table: [String: (meter: String, bpm: Int)] = [
        "reel": ("2/2", 90),
        "shetland reel": ("2/2", 90),
        "jig": ("6/8", 100),
        "double jig": ("6/8", 100),
        "slip jig": ("9/8", 100),
        "single jig": ("6/8", 105),
        "hop jig": ("9/8", 100),
        "slide": ("12/8", 115),
        "hornpipe": ("2/2", 70),
        "polka": ("2/4", 130),
        "waltz": ("3/4", 140),
        "vals": ("3/4", 140),
        "mazurka": ("3/4", 130),
        "barndance": ("2/2", 75),
        "barn dance": ("2/2", 75),
        "fling": ("2/2", 70),
        "highland": ("2/2", 70),
        "strathspey": ("2/2", 60),
        "march": ("2/4", 100),
        "pipe march": ("2/4", 90),
        "three-two": ("3/2", 120),
        "schottische": ("2/2", 70),
        "air": ("3/4", 70),
        "slow air": ("3/4", 70),
        "song air": ("3/4", 70),
    ]

    /// The time signature as it is counted: the written one, except that a
    /// tune counted in two (a reel in 4/4) is counted as 2/2.
    public static func countingMeter(_ written: String, type: String) -> String {
        guard written == "4/4" || written == "C" else { return written }
        return entry(for: type)?.meter == "2/2" ? "2/2" : written
    }

    private static func entry(for type: String) -> (meter: String, bpm: Int)? {
        let key = type.trimmingCharacters(in: .whitespaces).lowercased()
        if let found = table[key] { return found }
        // "Reels", "Jig (single)" and the like.
        let simple = key.hasSuffix("s") ? String(key.dropLast()) : key
        if let found = table[simple] { return found }
        return table.filter { key.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }?.value
    }

    /// The usual time signature for a kind of tune, or nil if unknown.
    public static func meter(for type: String) -> String? { entry(for: type)?.meter }

    /// A moderate tempo for a kind of tune, or nil if unknown.
    public static func tempo(for type: String) -> Int? { entry(for: type)?.bpm }
}
