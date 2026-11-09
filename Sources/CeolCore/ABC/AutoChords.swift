import Foundation

// FONN-AUTOCHORDS-1
/// Chords made up for tunes that have none: the setting, the test for whether
/// a tune has chords of its own, and the message that asks the music page for
/// them so they can be kept. The work itself is in Web/autochords.js, so the
/// phone, the iPad and the Mac all make the same chords.
public enum AutoChords {
    /// On by default: a tune with no chords gets some, greyed on the music.
    public static let key = "ceol.autoChords"

    /// Whether the tune has any chord symbols of its own: a quoted name
    /// starting with a note letter, after the K: line, outside comments.
    /// (Annotations — "^text", "_text" — aren't chords.)
    public static func hasChordSymbols(_ abc: String) -> Bool {
        var inBody = false
        for line in abc.split(whereSeparator: \.isNewline) {
            if !inBody {
                if line.hasPrefix("K:") { inBody = true }
                continue
            }
            if line.hasPrefix("%") { continue }
            if line.range(of: "\"[A-G]", options: .regularExpression) != nil { return true }
        }
        return false
    }
}

extension Notification.Name {
    /// "Keep these chords": the music page on screen hands back the tune with
    /// its made-up chords written in, and the screen saves it.
    public static let ceolKeepAutoChords = Notification.Name("ceol.keepAutoChords")
}
