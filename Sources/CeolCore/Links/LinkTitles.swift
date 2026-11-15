import Foundation
import LinkPresentation

// FONN-RESOURCES-1
/// A page's own title, for a link saved without one — what Messages shows
/// in a link preview. Apple's LinkPresentation does the fetching, on iOS and
/// the Mac alike, and knows YouTube's and others' quirks better than a regex
/// over the HTML would.
public enum LinkTitles {

    /// The title, or nil offline, after `timeout`, or for a page with none.
    @MainActor
    public static func title(for url: URL, timeout: TimeInterval = 8) async -> String? {
        // One provider per fetch: LPMetadataProvider is single-use.
        let provider = LPMetadataProvider()
        provider.timeout = timeout
        do {
            let metadata = try await provider.startFetchingMetadata(for: url)
            let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? nil : cleaned(title)
        } catch {
            return nil
        }
    }

    /// Titles come with the site's name stuck on the end, which the row
    /// already shows: "The Kesh – YouTube", "… | Tobar an Dualchais".
    static func cleaned(_ title: String) -> String {
        let suffixes = [" - YouTube", " – YouTube", " | Tobar an Dualchais",
                        " - Tobar an Dualchais", " | SoundCloud", " | Bandcamp"]
        for suffix in suffixes where title.hasSuffix(suffix) {
            return String(title.dropLast(suffix.count))
        }
        return title
    }
}
