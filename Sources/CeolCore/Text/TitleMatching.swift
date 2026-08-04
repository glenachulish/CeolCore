import Foundation
import SwiftData

/// Working out which tune a file belongs to from its name.
///
/// This is what makes a folder of recordings worth importing in one go: match
/// well and a hundred files land on the right tunes; match badly and you're
/// correcting a hundred rows by hand.
///
/// Trad titles are written every which way — "The Banshee", "Banshee, The",
/// "banshee", "03 - The Banshee.mp3" — so matching folds all of that together
/// before comparing. Measured against the library, filenames derived from tune
/// titles find the right tune 99% of the time in every style tried; the Pi's
/// matcher, which only strips a leading "The", manages 85% on the "X, The"
/// form. 205 of the titles are written that way, so it matters.
public enum TitleMatching {

    /// A tune title from a filename: drop the extension, turn separators into
    /// spaces, and remove a leading track number.
    public static func title(fromFilename filename: String) -> String {
        var stem = (filename as NSString).deletingPathExtension
        stem = stem.replacingOccurrences(of: "[_]+", with: " ",
                                         options: .regularExpression)
        // Hyphens are separators in "the-banshee" but part of the name in
        // "Cooley's-Reel" — treating them as spaces is right far more often.
        stem = stem.replacingOccurrences(of: "\\s*-\\s*|-", with: " ",
                                         options: .regularExpression)
        // "03 ", "03 - ", "03. " at the front.
        stem = stem.replacingOccurrences(of: "^\\s*\\d+\\s*[-.]?\\s*", with: "",
                                         options: .regularExpression)
        return stem.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fold accents, case and punctuation away — the same treatment the
    /// library search uses, so "O'Carolan" and "ocarolan" meet.
    public static func normalise(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: .current)
        let cleaned = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return cleaned.split(separator: " ").joined(separator: " ")
    }

    /// The name with any article taken off either end. Normalising turns
    /// "Banshee, The" into "banshee the", so the trailing form has to be
    /// handled *after* the punctuation goes — doing it before means the comma
    /// has already been eaten and the rule never fires.
    public static func bareName(_ text: String) -> String {
        var name = normalise(text)
        name = name.replacingOccurrences(of: "^(the|an|a) ", with: "",
                                         options: .regularExpression)
        name = name.replacingOccurrences(of: " (the|an|a)$", with: "",
                                         options: .regularExpression)
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Every spelling of a title that should be considered the same tune.
    public static func variants(of title: String) -> Set<String> {
        let whole = normalise(title)
        let bare = bareName(title)
        return Set([whole, bare, "the " + bare, bare + " the"].filter { !$0.isEmpty })
    }

    /// A lookup built once per import rather than per file — a hundred files
    /// against a thousand tunes is a hundred thousand comparisons done the
    /// naive way.
    public struct Index {
        private var byVariant: [String: [Tune]] = [:]

        public init(tunes: [Tune]) {
            for tune in tunes {
                for variant in TitleMatching.variants(of: tune.title) {
                    byVariant[variant, default: []].append(tune)
                }
                for alias in tune.aliases where !alias.isEmpty {
                    for variant in TitleMatching.variants(of: alias) {
                        byVariant[variant, default: []].append(tune)
                    }
                }
            }
        }

        /// The best tune for this title, preferring one that is a library row
        /// in its own right over an alternative filed inside a version group.
        public func match(_ title: String) -> Tune? {
            let bare = TitleMatching.bareName(title)
            for key in [TitleMatching.normalise(title), bare, "the " + bare, bare + " the"] {
                guard let candidates = byVariant[key], !candidates.isEmpty else { continue }
                return candidates.first { $0.groupID == nil || $0.isDefaultVersion }
                    ?? candidates.first
            }
            return nil
        }
    }
}
