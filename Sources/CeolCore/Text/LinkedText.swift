import Foundation

/// Web addresses written into a tune's notes, made usable.
///
/// 51 tunes in this library carry a URL in the notes field — "Imported from
/// PDF: 2026-03-22 http://www.youtube.com/watch?v=…" — against 37 that have a
/// proper link attachment. Those 51 came in from older imports that had
/// nowhere else to put a source, and as plain text they are unusable: you
/// cannot tap them, and the app cannot play them.
///
/// This does not move any data. It finds the addresses so a view can render
/// them as links, and so the app can offer to promote them to real
/// attachments — which is a change to the library and therefore something to
/// be shown and confirmed, not done quietly.
public enum LinkedText {

    /// Every web address in a piece of text, in the order they appear.
    ///
    /// `NSDataDetector` rather than a regular expression: it knows where a URL
    /// stops, which is the part hand-written patterns get wrong. Trailing full
    /// stops and closing brackets belong to the sentence, not the address.
    public static func urls(in text: String) -> [URL] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return url
        }
    }

    /// The same text with its addresses marked up, ready for `Text(_:)`.
    ///
    /// Returns nil when there is nothing to link, so a caller can fall back to
    /// a plain string rather than paying for an AttributedString on every
    /// tune with ordinary notes.
    public static func attributed(_ text: String) -> AttributedString? {
        let found = urls(in: text)
        guard !found.isEmpty else { return nil }

        var out = AttributedString(text)
        for url in found {
            // absoluteString rather than the matched substring: the detector
            // may have completed a bare "www." address, and searching for the
            // completed form would find nothing.
            let needle = text.contains(url.absoluteString)
                ? url.absoluteString
                : String(url.absoluteString.dropFirst((url.scheme?.count ?? 0) + 3))
            guard let range = out.range(of: needle) else { continue }
            // `link` is Foundation's own attribute. Deliberately nothing from
            // the SwiftUI attribute scope here — underlineStyle and the rest
            // would drag SwiftUI into a file that has no business importing
            // it, and a link renders as a link without being told to.
            out[range].link = url
        }
        return out
    }

    /// Files the Pi recorded in a tune's notes rather than as attachments.
    ///
    /// The web app wrote lines like `audio: /api/uploads/262ef2ff-….m4a` into
    /// the notes field. 369 tunes in this library carry them — 630 files,
    /// against 307 in the export's own `media` array — so the notes are not a
    /// footnote to the attachments, they are the larger half of them. An
    /// importer that reads only `media` leaves most of a library's recordings
    /// on the floor and says nothing.
    ///
    /// Returns bare filenames, which is what the media folder is keyed by.
    public static func uploadedFilenames(in notes: String) -> [String] {
        guard !notes.isEmpty else { return [] }
        // `/api/uploads/NAME` — the Pi's own URL shape. The name runs to the
        // first character that cannot be in a filename.
        let pattern = #"/api/uploads/([A-Za-z0-9._-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(notes.startIndex..<notes.endIndex, in: notes)
        var out: [String] = []
        for match in regex.matches(in: notes, range: range) {
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: notes) else { continue }
            let name = String(notes[r])
            if !out.contains(name) { out.append(name) }
        }
        return out
    }

    /// Whether a link is one the app can play in a web view rather than
    /// handing to a browser.
    public static func isVideo(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host.contains("youtube.com") || host.contains("youtu.be")
            || host.contains("vimeo.com")
    }

    /// Addresses in the notes that are not already attachments, so the app can
    /// offer to promote them without proposing something you already have.
    public static func unattached(in tune: Tune) -> [URL] {
        let already = Set((tune.media ?? []).compactMap { $0.urlString.isEmpty ? nil : $0.urlString })
        return urls(in: tune.notes).filter { !already.contains($0.absoluteString) }
    }
}
