import Foundation

/// How a tune's name is written down, versus how it is said.
///
/// TheSession and most printed collections file a tune under its first
/// significant word, so the article gets pushed to the end with a comma:
/// "Little Cascade, The". That is a cataloguing convention, not a name —
/// nobody at a session says "we'll play Little Cascade comma The". 201 of the
/// 1,571 tunes in the library are stored that way.
///
/// So the stored title stays exactly as it is — it is what sorting and the A–Z
/// down the side of the library depend on, and what an export has to round-trip
/// — and this turns it back into English wherever a name is read rather than
/// looked up.
///
/// `BuildStamp` used to share this file. It reads `Bundle.main`, which is a
/// different bundle in each app, so it stayed behind in the iOS target.
public enum TitleDisplay {

    /// Articles worth moving. Kept deliberately short: "Please" also turns up
    /// after a comma in this library ("Another Jig Will Do, Please") and is
    /// part of the name, not a filing artefact.
    private static let articles = ["The", "A", "An", "Na", "Am", "An t-", "Na h-"]

    /// The spoken form with any trailing qualifier dropped: "Blackberry
    /// Blossom #1 (G maj)" → "Blackberry Blossom #1". The key in brackets is
    /// there to tell one setting from another in a list of 1,571 tunes; in a
    /// line naming the tunes of a set it is just length, and length is what
    /// pushes the last tune off the screen.
    public static func plain(_ title: String) -> String {
        let spokenTitle = spoken(title)
        let trimmed = spokenTitle.replacingOccurrences(
            of: "\\s*\\([^()]*\\)\\s*$", with: "", options: .regularExpression)
        return trimmed.isEmpty ? spokenTitle : trimmed
    }

    /// "Little Cascade, The" → "The Little Cascade". Anything that isn't in the
    /// filing form comes back untouched.
    public static func spoken(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let comma = trimmed.lastIndex(of: ",") else { return title }

        let tail = trimmed[trimmed.index(after: comma)...]
            .trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty else { return title }

        // Case-insensitive so a stray "Ashplant, THE" is caught too, but the
        // article is written back in its normal form rather than shouted.
        guard let article = articles.first(where: {
            $0.compare(tail, options: .caseInsensitive) == .orderedSame
        }) else { return title }

        let head = trimmed[..<comma].trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty else { return title }

        // "An t-" and "Na h-" join straight onto the word; the rest take a space.
        let joiner = article.hasSuffix("-") ? "" : " "
        return article + joiner + head
    }
}
