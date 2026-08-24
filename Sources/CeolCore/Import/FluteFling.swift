import Foundation
import SwiftData

/// The FlutefFling session-tunes catalogue.
///
/// The Pi had this and neither app does, which is the largest of the gaps
/// between them: it is a flute player's own source, it is where a good number
/// of this library's tunes came from, and it is the one Pi route with no
/// equivalent at all — Dropbox is reached through the system file picker, and
/// a TheCraic export is an ABC file like any other.
///
/// Ported from `main.py`'s `_PdfMp3Parser`, and the parsing rule is copied
/// exactly because it encodes what that page actually looks like rather than
/// what it ought to:
///
///   * each tune is one `<li>`;
///   * inside it, a link ending `.pdf` is the music and one ending `.mp3` is
///     the recording — either may be missing, and a list item with neither is
///     not a tune;
///   * the title is the text of whichever link is there;
///   * the tune type is whatever sits in brackets in the item's text, e.g.
///     "Da Slockit Light (air)".
///
/// This deliberately does not try to be a general scraper. The Pi's version
/// answered one page and so does this.
public enum FluteFling {

    public static let base = "https://flutefling.scot"
    public static let archive = "https://flutefling.scot/resources/flutefling-session-tunes/"

    public struct Entry: Identifiable, Hashable, Sendable {
        public var id: String { title + "|" + (pdf?.absoluteString ?? "") }
        public let title: String
        public let type: String
        public let pdf: URL?
        public let mp3: URL?

        public var hasMusic: Bool { pdf != nil }
        public var hasRecording: Bool { mp3 != nil }
    }

    public enum Failure: LocalizedError {
        case offline(String)
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .offline(let why): return why
            case .unreadable:
                return "The catalogue page loaded but nothing on it looked like a tune. The site may have been rebuilt."
            }
        }
    }

    /// Fetch and parse the catalogue.
    ///
    /// A browser's User-Agent, as the Pi sent. Left as the default,
    /// `flutefling.scot` answers some clients with a challenge page rather than
    /// the list, and the parse then finds nothing with no clue as to why.
    public static func catalogue() async throws -> [Entry] {
        guard let url = URL(string: archive) else { throw Failure.unreadable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                         + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        request.setValue("en-GB,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        request.setValue(base + "/", forHTTPHeaderField: "Referer")

        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw Failure.offline("FlutefFling answered \(http.statusCode).")
            }
            data = body
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.offline(error.localizedDescription)
        }

        let html = String(decoding: data, as: UTF8.self)
        let tunes = parse(html)
        guard !tunes.isEmpty else { throw Failure.unreadable }
        return tunes
    }

    /// Split into list items and read each one. Exposed so it can be checked
    /// against a saved copy of the page without going near the network.
    public static func parse(_ html: String) -> [Entry] {
        var out: [Entry] = []
        var seen = Set<String>()
        for item in listItems(in: html) {
            guard let entry = entry(fromListItem: item), seen.insert(entry.id).inserted else {
                continue
            }
            out.append(entry)
        }
        return out
    }

    private static func listItems(in html: String) -> [String] {
        var items: [String] = []
        var rest = Substring(html)
        while let open = rest.range(of: "<li", options: .caseInsensitive) {
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "</li", options: .caseInsensitive) else { break }
            items.append(String(rest[rest.startIndex..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return items
    }

    private static func entry(fromListItem item: String) -> Entry? {
        let links = anchors(in: item)
        let pdf = links.first { $0.href.lowercased().hasSuffix(".pdf") }
        let mp3 = links.first { $0.href.lowercased().hasSuffix(".mp3") }
        guard pdf != nil || mp3 != nil else { return nil }

        let named = pdf ?? mp3!
        let title = tidy(named.text)
        guard !title.isEmpty else { return nil }

        // "(reel)", "(slow air)" — whatever is in brackets anywhere in the item.
        var type = ""
        let text = tidy(stripTags(item))
        if let open = text.firstIndex(of: "("),
           let close = text[open...].firstIndex(of: ")") {
            type = String(text[text.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces).lowercased()
        }

        return Entry(title: title,
                    type: type,
                    pdf: pdf.flatMap { absolute($0.href) },
                    mp3: mp3.flatMap { absolute($0.href) })
    }

    private static func absolute(_ href: String) -> URL? {
        if href.hasPrefix("http") { return URL(string: href) }
        return URL(string: base + (href.hasPrefix("/") ? href : "/" + href))
    }

    private struct Anchor { let href: String; let text: String }

    private static func anchors(in html: String) -> [Anchor] {
        var found: [Anchor] = []
        var rest = Substring(html)
        while let tagStart = rest.range(of: "<a ", options: .caseInsensitive) {
            rest = rest[tagStart.upperBound...]
            guard let tagEnd = rest.firstIndex(of: ">") else { break }
            let attributes = String(rest[rest.startIndex..<tagEnd])
            rest = rest[rest.index(after: tagEnd)...]
            guard let close = rest.range(of: "</a", options: .caseInsensitive) else { break }
            let inner = String(rest[rest.startIndex..<close.lowerBound])
            rest = rest[close.upperBound...]
            if let href = attribute("href", in: attributes) {
                found.append(Anchor(href: href, text: stripTags(inner)))
            }
        }
        return found
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let start = tag.range(of: name + "=", options: .caseInsensitive) else { return nil }
        var rest = tag[start.upperBound...]
        guard let quote = rest.first, quote == "\"" || quote == "'" else {
            // Unquoted: runs to whitespace.
            let value = rest.prefix { !$0.isWhitespace && $0 != ">" }
            return value.isEmpty ? nil : String(value)
        }
        rest = rest.dropFirst()
        guard let end = rest.firstIndex(of: quote) else { return nil }
        return String(rest[rest.startIndex..<end])
    }

    private static func stripTags(_ html: String) -> String {
        var out = ""
        var inside = false
        for character in html {
            if character == "<" { inside = true }
            else if character == ">" { inside = false }
            else if !inside { out.append(character) }
        }
        return out
    }

    // MARK: - Taking one into the library

    /// Titles already in the library, folded the way the importer folds them,
    /// so the list can say what you already have instead of offering it again.
    @MainActor
    public static func alreadyHave(_ entries: [Entry], in context: ModelContext) -> Set<String> {
        let existing = (try? context.fetch(FetchDescriptor<Tune>())) ?? []
        let known = Set(existing.map { TitleMatching.normalise($0.title) })
        return Set(entries.map(\.title).filter { known.contains(TitleMatching.normalise($0)) })
    }

    /// Add these as tunes, fetching the sheet music and the recording onto the
    /// device as you go.
    ///
    /// The link version below leaves you with a tune that needs a signal to show
    /// you anything — which is the wrong way round for an app whose whole point
    /// is a session in a hall with no reception. These are small files: a page of
    /// music is tens of kilobytes and a tune's recording a megabyte or two, so
    /// the whole catalogue is a few hundred megabytes at the outside and a
    /// handful of tunes is nothing.
    ///
    /// A file that won't come down is not a failure worth stopping for: the tune
    /// is still made, and what couldn't be fetched is attached as a link, which
    /// is exactly what the old behaviour was. So a bad connection costs you the
    /// offline copy and nothing else, and running it again later fills the gap.
    ///
    /// `progress` is called on the main actor with (done, total) counted in
    /// files rather than tunes, because that is what takes the time.
    @discardableResult
    @MainActor
    public static func addDownloading(
        _ entries: [Entry],
        in context: ModelContext,
        progress: ((Int, Int) -> Void)? = nil
    ) async -> (tunes: Int, files: Int, unfetched: Int) {

        let total = entries.reduce(0) {
            $0 + ($1.pdf == nil ? 0 : 1) + ($1.mp3 == nil ? 0 : 1)
        }
        var done = 0, tunes = 0, files = 0, unfetched = 0

        for entry in entries {
            let record = Tune(title: entry.title, type: entry.type)
            record.sourceURL = archive
            context.insert(record)
            tunes += 1

            // The PDF is the sheet music and the MP3 is the recording; either
            // may be missing, and neither is worth a second query about.
            let wanted: [(URL?, MediaKind, String)] = [
                (entry.pdf, .pdf, "Sheet music"),
                (entry.mp3, .audio, "Recording"),
            ]

            for (source, kind, title) in wanted {
                guard let source else { continue }
                let item: MediaItem
                if let data = await fetch(source), !data.isEmpty,
                   let name = try? MediaStore.shared.save(data, as: source.lastPathComponent) {
                    item = MediaItem(kind: kind, title: title, filename: name)
                    // Kept as well as the file. Nothing reads it while the file
                    // is there — `MediaLinks` prefers the local copy — but it
                    // records where the thing came from, and it is what a later
                    // re-fetch would use.
                    item.urlString = source.absoluteString
                    files += 1
                } else {
                    item = MediaItem(kind: .link, title: title,
                                     urlString: source.absoluteString)
                    unfetched += 1
                }
                item.tune = record
                context.insert(item)
                done += 1
                progress?(done, total)
            }
        }
        try? context.save()
        return (tunes, files, unfetched)
    }

    /// One file, with the same headers the catalogue needed. Nil for anything
    /// that isn't a clean 200 — the caller falls back to a link.
    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                         + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue(archive, forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Add these as tunes, each carrying its sheet music and recording as
    /// links.
    ///
    /// No ABC: FlutefFling publishes PDFs, not notation, and inventing an empty
    /// ABC body would put 400 blank staves in the library. A tune with a PDF
    /// and no notation is a shape this app already handles — `MediaWindowInline`
    /// exists precisely because 560 tunes here are like that.
    @discardableResult
    @MainActor
    public static func add(_ entries: [Entry], in context: ModelContext) -> Int {
        var added = 0
        for entry in entries {
            // `sourceURL`, not `source` — the model has no `source`, and
            // guessing a property name is the same class of mistake as
            // guessing a type.
            let record = Tune(title: entry.title, type: entry.type)
            record.sourceURL = archive
            context.insert(record)

            if let pdf = entry.pdf {
                let item = MediaItem(kind: .link, title: "Sheet music (PDF)",
                                     urlString: pdf.absoluteString)
                item.tune = record
                context.insert(item)
            }
            if let mp3 = entry.mp3 {
                // `.audio` rather than `.link`: it is a direct file, so it
                // plays in the app with the same speed control as a recording
                // held on the device.
                let item = MediaItem(kind: .audio, title: "Recording",
                                     urlString: mp3.absoluteString)
                item.tune = record
                context.insert(item)
            }
            added += 1
        }
        try? context.save()
        return added
    }

    /// Collapse whitespace and decode the handful of entities this page uses.
    private static func tidy(_ text: String) -> String {
        var out = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#8217;", with: "’")
            .replacingOccurrences(of: "&#8216;", with: "‘")
            .replacingOccurrences(of: "&rsquo;", with: "’")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
