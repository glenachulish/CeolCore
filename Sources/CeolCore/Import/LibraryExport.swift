import Foundation
import SwiftData

/// Getting your library back out again.
///
/// The format is deliberately the **same `.ceol.json` the Pi writes and this
/// app reads** — including the `parent_id` / `is_default` fields that carry
/// version groups. That makes it a genuine round trip: export from the phone,
/// import to the Pi, or back into a fresh install here. An export you can't
/// re-import is a false comfort.
///
/// Media files are not in the JSON (they're files, not text). Their references
/// are, so a future folder export can carry them; the importer skips any whose
/// file is missing rather than creating a broken attachment.
public enum LibraryExport {

    // MARK: - Whole library

    public static func libraryJSON(context: ModelContext) throws -> Data {
        let tunes = (try? context.fetch(FetchDescriptor<Tune>(sortBy: [SortDescriptor(\.title)]))) ?? []
        let sets = (try? context.fetch(FetchDescriptor<TuneSet>(sortBy: [SortDescriptor(\.name)]))) ?? []
        let collections = (try? context.fetch(
            FetchDescriptor<TuneCollection>(sortBy: [SortDescriptor(\.name)]))) ?? []

        // Stable ids, assigned here — SwiftData's own identifiers mean nothing
        // to the Pi, and the sets and collections below refer to these.
        var idFor: [PersistentIdentifier: Int] = [:]
        for (index, tune) in tunes.enumerated() { idFor[tune.persistentModelID] = index + 1 }

        // Version groups become the Pi's parent/child shape: the default
        // version is the parent, the rest point at it.
        var parentIDFor: [PersistentIdentifier: Int] = [:]
        var groups: [UUID: [Tune]] = [:]
        for tune in tunes {
            guard let groupID = tune.groupID else { continue }
            groups[groupID, default: []].append(tune)
        }
        for (_, members) in groups {
            guard members.count > 1 else { continue }
            let parent = members.first(where: \.isDefaultVersion) ?? members[0]
            guard let parentID = idFor[parent.persistentModelID] else { continue }
            for member in members where member !== parent {
                parentIDFor[member.persistentModelID] = parentID
            }
        }

        let tuneDicts: [[String: Any]] = tunes.map { tune in
            var dict: [String: Any] = [
                "id": idFor[tune.persistentModelID] ?? 0,
                "title": tune.title,
                "type": tune.type,
                "key": tune.key,
                "mode": tune.mode,
                "abc": tune.abc,
                "notes": tune.notes,
                "composer": tune.composer,
                "transcribed_by": tune.transcribedBy,
                "rating": tune.rating,
                "on_hitlist": tune.onHitlist ? 1 : 0,
                "is_favourite": tune.isFavourite ? 1 : 0,
                "source_url": tune.sourceURL,
                "version_label": tune.versionLabel,
                "transpose": tune.transpose,
                "is_default": tune.isDefaultVersion ? 1 : 0,
                "aliases": tune.aliases,
                "imported_at": ISO8601DateFormatter().string(from: tune.createdAt),
            ]
            if let sessionID = tune.theSessionID { dict["session_id"] = sessionID }
            if !tune.theSessionSettingID.isEmpty { dict["setting_id"] = tune.theSessionSettingID }
            if let parentID = parentIDFor[tune.persistentModelID] { dict["parent_id"] = parentID }
            // The speed you practise at, written only when there is one, so a
            // library without any exports exactly what it did before and every
            // existing reader is unaffected. Absent means "no practice tempo
            // set", not "something went wrong" — the same rule as set_indexes.
            if let practice = tune.practiceBPM { dict["practice_bpm"] = practice }

            let media = (tune.media ?? []).map { item -> [String: Any] in
                ["kind": item.kindRaw, "filename": item.filename, "url": item.urlString]
            }
            if !media.isEmpty { dict["media"] = media }
            return dict
        }

        // Sets are referenced from collections by their position in this array,
        // the same way tunes are referenced by index. A name would be ambiguous
        // — two sets can share one — and there is no stable id in the format.
        var setIndexFor: [PersistentIdentifier: Int] = [:]
        for (index, set) in sets.enumerated() { setIndexFor[set.persistentModelID] = index }

        let setDicts: [[String: Any]] = sets.map { set in
            let entries = set.orderedEntries.enumerated().compactMap { index, entry -> [String: Any]? in
                guard let tune = entry.tune, let tuneID = idFor[tune.persistentModelID] else { return nil }
                return ["tune_id": tuneID, "position": index,
                        "repeats": entry.repeats, "key_override": entry.keyOverride]
            }
            return [
                "name": set.name,
                "notes": set.notes,
                "rating": set.rating,
                "is_favourite": set.isFavourite ? 1 : 0,
                "on_hitlist": set.onHitlist ? 1 : 0,
                "entries": entries,
            ]
        }

        let collectionDicts: [[String: Any]] = collections.map { collection in
            var dict: [String: Any] = [
                "name": collection.name,
                "description": collection.about,
                "is_favourite": collection.isFavourite ? 1 : 0,
                "on_hitlist": collection.onHitlist ? 1 : 0,
                "tune_ids": (collection.tunes ?? []).compactMap { idFor[$0.persistentModelID] },
            ]
            // Written only when there are any, so a library with no sets in
            // collections exports byte-for-byte what it did before and older
            // readers — the Pi, and any export already on disk — are unaffected.
            let indexes = (collection.sets ?? []).compactMap { setIndexFor[$0.persistentModelID] }
            if !indexes.isEmpty { dict["set_indexes"] = indexes.sorted() }
            return dict
        }

        let payload: [String: Any] = [
            "ceol": 1,
            "type": "library",
            "exported_at": ISO8601DateFormatter().string(from: .now).prefix(10).description,
            "exported_by": "Ceòl for iOS",
            "tunes": tuneDicts,
            "sets": setDicts,
            "collections": collectionDicts,
        ]
        return try JSONSerialization.data(withJSONObject: payload,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    /// Write the library to a temporary file ready for the share sheet.
    public static func libraryFile(context: ModelContext) throws -> URL {
        let data = try libraryJSON(context: context)
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        return try write(data, named: "ceol-library-\(stamp).ceol.json")
    }

    // MARK: - One tune, one set

    /// ABC for a single tune, as a `.abc` file other trad software can read.
    public static func abcFile(for tune: Tune) throws -> URL {
        var text = tune.abc
        if !text.contains("X:") { text = "X:1\n" + text }
        return try write(Data(text.utf8), named: safeName(tune.title) + ".abc")
    }

    /// Every tune in a set, in order, as one multi-tune ABC file.
    public static func abcFile(for set: TuneSet) throws -> URL {
        var pieces: [String] = []
        for (index, entry) in set.orderedEntries.enumerated() {
            guard let tune = entry.tune, !tune.abc.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            var abc = tune.abc
            // Each tune in a file needs its own X: number.
            if let range = abc.range(of: #"^X:\s*\d+"#, options: [.regularExpression]) {
                abc.replaceSubrange(range, with: "X:\(index + 1)")
            } else {
                abc = "X:\(index + 1)\n" + abc
            }
            pieces.append(abc.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let text = pieces.joined(separator: "\n\n")
        return try write(Data(text.utf8), named: safeName(set.name) + ".abc")
    }

    // MARK: -

    private static func write(_ data: Data, named name: String) throws -> URL {
        // A folder of our own inside tmp, so repeated exports don't pile up
        // next to unrelated temporary files.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CeolExport", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Titles contain slashes and colons often enough to matter.
    private static func safeName(_ raw: String) -> String {
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(80))
    }
}
