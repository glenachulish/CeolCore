import Foundation
import SwiftData

/// FONN-STARTERSETS-1: sets by tradition, carried in the app.
///
/// Each is a collection share (.fonn) Callum made from his own
/// "Starter Sets — X" collection, so it carries the collection's name, its
/// sets and every tune's ABC. Adding one goes through the ordinary share
/// importer: a tune already in the library is used rather than added again, a
/// set whose name is taken is skipped, and the collection is made (or filled)
/// under its own name. So adding one twice adds nothing the second time.
///
/// Nothing here counts towards the free version's 20, for the same reason as
/// the six starter tunes: they are the app's gift, not the reader's tunes.
public enum StarterSets {

    public struct Tradition: Identifiable, Hashable {
        /// The file's name without its extension. Stable, for menus.
        public let id: String
        /// "Breton": the collection name less its "Starter Sets — " prefix.
        public let name: String
        public let collectionName: String
        public let sets: Int
        public let tunes: Int
        let url: URL

        /// "Breton — 7 sets, 15 tunes"
        public var menuLabel: String {
            "\(name) — \(sets) set\(sets == 1 ? "" : "s"), \(tunes) tune\(tunes == 1 ? "" : "s")"
        }
    }

    /// Every bundled tradition, by name. Empty if none are bundled, and the
    /// menus that offer them are then hidden.
    public static let available: [Tradition] = {
        let urls = Bundle.module.urls(forResourcesWithExtension: "fonn",
                                      subdirectory: "Seed/StarterSets") ?? []
        return urls.compactMap { url -> Tradition? in
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["ceol"] as? Int == 1 else { return nil }
            let collection = (json["name"] as? String ?? url.deletingPathExtension().lastPathComponent)
                .trimmingCharacters(in: .whitespaces)
            var name = collection
            for prefix in ["Starter Sets — ", "Starter Sets - ", "Starter Sets – "] where name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
            }
            return Tradition(id: url.deletingPathExtension().lastPathComponent,
                             name: name,
                             collectionName: collection,
                             sets: ((json["sets"] as? [Any]) ?? []).count,
                             tunes: ((json["tunes"] as? [Any]) ?? []).count,
                             url: url)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    public static func tradition(id: String) -> Tradition? {
        available.first { $0.id == id }
    }

    /// Adds one tradition, outside the free allowance, and saves.
    @MainActor
    public static func add(_ tradition: Tradition, context: ModelContext) throws -> FileImports.Summary {
        let summary = try TuneAllowance.shared.uncounted {
            try FileImports.importCeolJSON(url: tradition.url, context: context)
        }
        try? context.save()
        return summary
    }

    /// What to tell the reader afterwards.
    public static func message(_ summary: FileImports.Summary, for tradition: Tradition) -> String {
        if summary.tunesImported == 0 && summary.setsCreated == 0 {
            return "The \(tradition.name) starter sets are already in your library, in “\(tradition.collectionName)”."
        }
        var parts: [String] = []
        parts.append("\(summary.setsCreated) set\(summary.setsCreated == 1 ? "" : "s")")
        parts.append("\(summary.tunesImported) new tune\(summary.tunesImported == 1 ? "" : "s")")
        if summary.tunesSkipped > 0 {
            parts.append("\(summary.tunesSkipped) you already had")
        }
        return "Added the \(tradition.name) starter sets to “\(tradition.collectionName)”: " + parts.joined(separator: ", ") + "."
    }
}
