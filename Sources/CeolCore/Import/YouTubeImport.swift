import Foundation
import SwiftData

/// Make a tune from a YouTube video.
///
/// The Pi's `/api/import/youtube`: validate the URL, ask YouTube's oEmbed
/// endpoint what the video is called, and create a tune carrying the link. No
/// notation — this is for a tune you have heard and want to keep track of, and
/// an empty stave would be worse than none.
///
/// oEmbed is a plain public JSON endpoint needing no key, which is why the Pi
/// used it and why this can too.
public enum YouTubeImport {

    public enum Failure: LocalizedError {
        case notYouTube
        case offline(String)

        public var errorDescription: String? {
            switch self {
            case .notYouTube:
                return "That isn't a YouTube address. It should look like youtube.com/watch?v=… or youtu.be/…"
            case .offline(let why):
                return why
            }
        }
    }

    /// What YouTube calls the video, or nil if it will not say.
    ///
    /// Failing to get a title is not a reason to refuse the import — the Pi
    /// fell back to "YouTube – <id>" and so does `add`. A tune you can rename
    /// beats an error message.
    public static func title(of url: URL) async -> String? {
        guard MediaLinks.youTubeID(of: url) != nil,
              var parts = URLComponents(string: "https://www.youtube.com/oembed")
        else { return nil }
        parts.queryItems = [URLQueryItem(name: "url", value: url.absoluteString),
                            URLQueryItem(name: "format", value: "json")]
        guard let endpoint = parts.url else { return nil }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["title"] as? String
        else { return nil }
        let tidied = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return tidied.isEmpty ? nil : tidied
    }

    /// Look the video up without writing anything, so the title can be shown
    /// and corrected before it becomes a tune.
    public static func look(at text: String) async throws -> (url: URL, title: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let id = MediaLinks.youTubeID(of: url) else {
            throw Failure.notYouTube
        }
        let secured = MediaLinks.secured(url)
        return (secured, await title(of: secured) ?? "YouTube – \(id)")
    }

    @MainActor
    public static func add(url: URL, title: String, type: String = "",
                           in context: ModelContext) -> Tune {
        let tune = Tune(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        type: type)
        tune.sourceURL = url.absoluteString
        context.insert(tune)

        // A real attachment, not just a line in the notes. The Pi could only
        // write the URL into `notes` and re-scan it on every render; here it
        // can be a `.link`, which means it plays in the media bar under the
        // stave and answers the "has a video link" filter.
        let item = MediaItem(kind: .link, title: "YouTube", urlString: url.absoluteString)
        item.tune = tune
        context.insert(item)

        try? context.save()
        return tune
    }
}
