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

    // MARK: - Filing order

    /// What a title sorts as, with the article out of the way.
    ///
    /// Two forms turn up in this library and both have to be handled, because
    /// tunes arrive from different places and are written down differently:
    ///
    /// - the filing form, `"Little Cascade, The"`, which already sorts under L
    ///   but drags a comma and an article into the comparison;
    /// - the spoken form, `"The Kesh Jig"`, which sorts under T — and is why
    ///   half a trad library ends up filed under one letter. Every tune whose
    ///   name begins "The" lands in the same stretch of the alphabet, which is
    ///   no use at all for finding one.
    ///
    /// ## Only "The"
    ///
    /// `articles` above lists seven, and every one of them is right *after a
    /// comma* — somebody typed it there deliberately, and "Bruach na Carraige
    /// Bàine, Na" means what it says. At the front of a title they are not
    /// safe: "Am I Right" and "A Fig for a Kiss" are not articles, and a rule
    /// that files them under I and F is worse than one that leaves them where
    /// they are. So the leading form strips "The" and nothing else, which is
    /// also what thesession.org does.
    ///
    /// This is a sort key, not a rename. Nothing on disk changes and the title
    /// still reads the way it was written.
    public static func sortKey(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Filing form: the article after the comma is exactly the part to drop,
        // and the head is already the sorting name.
        if let comma = text.lastIndex(of: ",") {
            let head = text[..<comma].trimmingCharacters(in: .whitespaces)
            let tail = text[text.index(after: comma)...]
                .trimmingCharacters(in: .whitespaces)
            let isArticle = articles.contains {
                $0.compare(tail, options: .caseInsensitive) == .orderedSame
            }
            if isArticle && !head.isEmpty { text = head }
        }

        // Spoken form. Case-insensitive, so "THE Ashplant" is caught as well.
        if text.count > 4,
           text.prefix(4).compare("The ", options: .caseInsensitive) == .orderedSame {
            let rest = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
            // A tune actually called "The" keeps its name rather than sorting
            // under nothing at all.
            if !rest.isEmpty { text = rest }
        }

        return text.isEmpty ? title : text
    }

    /// Does `a` come before `b` in the library?
    ///
    /// `localizedStandardCompare` rather than `<`: it is case-insensitive, it
    /// puts accented letters beside their plain forms rather than after Z, and
    /// it reads runs of digits as numbers, so "Reel #2" comes before
    /// "Reel #10" instead of after it.
    ///
    /// The tie-break on the full title matters more than it looks. Swift's
    /// `sorted` is not guaranteed stable, so two tunes with the same sort key —
    /// "The Kesh Jig" and "Kesh Jig", which is exactly the pair a library
    /// collects — could otherwise swap places between one redraw and the next,
    /// under the reader's finger.
    public static func precedes(_ a: String, _ b: String) -> Bool {
        switch sortKey(a).localizedStandardCompare(sortKey(b)) {
        case .orderedAscending:  return true
        case .orderedDescending: return false
        case .orderedSame:       return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// The letter a title files under, lowercased, for the A–Z strip.
    ///
    /// Folded, so "Òran" answers to O. Nil only for an empty title; a tune
    /// beginning with a digit or a bracket answers with that character and
    /// simply matches no letter, which is the behaviour that was there before.
    public static func initial(_ title: String) -> Character? {
        sortKey(title)
            .folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: .current)
            .first
    }
}
