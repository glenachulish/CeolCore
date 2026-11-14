import Foundation

// FONN-MARKS-1
/// The highlighter: runs of notes marked in a colour, kept with the tune.
///
/// A mark is "from the 12th note to the 30th, in yellow", not a place on the
/// page, so it lands on the same music whatever size the tune is drawn at,
/// transposed or not, on every device the tune syncs to. `Tune.marks` holds
/// them as the page writes them: a short JSON list, `[{"a":12,"b":30,"c":"y"}]`,
/// or empty for none. The app never reads inside it; it only carries it
/// between the store and the page (Web/marks.js), which does the drawing and
/// the marking.
public enum MusicMarks {

    /// The message channel the page reports changes on.
    public static let channel = "marks"

    /// The JavaScript that hands the page each shown tune's marks: one for a
    /// tune page, one per engraved tune for a set. Sending it at all is what
    /// puts the highlighter button on the page. Safe to repeat.
    public static func script(_ marks: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: marks)) ?? Data("[]".utf8)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        return "if (typeof ceolSetMarks === 'function') ceolSetMarks(\(json));"
    }

    /// FONN-MARKS-5: the JavaScript that brings the marking tools up on the
    /// page. They aren't there until asked for (the app's "Mark the music"
    /// menu item), and the page's own Done puts them away.
    public static let openScript =
        "if (typeof ceolMarkOpen === 'function') ceolMarkOpen(true);"

    /// What the page says when the marks on one of its tunes change: which
    /// tune (its place among those shown) and its marks, ready to store.
    public static func receive(_ body: Any) -> (index: Int, marks: String)? {
        guard let d = body as? [String: Any],
              let index = (d["tune"] as? NSNumber)?.intValue,
              let marks = d["marks"] as? String else { return nil }
        return (index, marks)
    }
}
