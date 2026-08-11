import Foundation
import SwiftData

/// File-based importers, ported from the Fonn web app (v3 backend).
public enum FileImports {

    public struct Summary {
        /// Spelled out: the free memberwise initialiser is internal, and
        /// ABCImportPlan still builds one of these from the app.
        public init() {}

        public var tunesImported = 0
        public var tunesSkipped = 0      // duplicates
        public var setsCreated = 0
        public var collectionsCreated = 0
        public var versionGroups = 0
        public var mediaAttached = 0

        public var message: String {
            var parts = ["Imported \(tunesImported) tune\(tunesImported == 1 ? "" : "s")"]
            if tunesSkipped > 0 { parts.append("skipped \(tunesSkipped) duplicate\(tunesSkipped == 1 ? "" : "s")") }
            if versionGroups > 0 { parts.append("\(versionGroups) version group\(versionGroups == 1 ? "" : "s")") }
            if mediaAttached > 0 { parts.append("\(mediaAttached) recording\(mediaAttached == 1 ? "" : "s")") }
            if setsCreated > 0 { parts.append("\(setsCreated) set\(setsCreated == 1 ? "" : "s")") }
            if collectionsCreated > 0 { parts.append("\(collectionsCreated) collection\(collectionsCreated == 1 ? "" : "s")") }
            return parts.joined(separator: ", ")
        }
    }

    public enum ImportError: LocalizedError {
        case unreadable
        case notCeolFile
        case noLibraryInFolder
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read the file."
            case .notCeolFile: return "Not a valid Fonn export file (.ceol.json)."
            case .noLibraryInFolder:
                return """
                    No library.ceol.json in there.

                    This is for the ceol-media-export folder that export-ceol-json.py writes — the one holding both library.ceol.json and the media folder.

                    For a folder of recordings, photos or PDFs named after tunes, go back and choose “A whole folder” under “A folder at a time”.
                    """
            }
        }
    }

    // MARK: - ABC file (also covers TheCraic exports)

    /// Bulk-import a multi-tune .abc file. Skips tunes whose exact title
    /// already exists in the library.
    public static func importABCFile(url: URL, context: ModelContext) throws -> Summary {
        let text = try readFile(url: url)
        let existingTitles = Set(try context.fetch(FetchDescriptor<Tune>())
            .map { $0.title.lowercased().trimmingCharacters(in: .whitespaces) })

        var summary = Summary()
        for block in ABCParser.splitTunes(text) {
            let parsed = ABCParser.parse(block)
            guard !parsed.abc.isEmpty, !parsed.title.isEmpty, parsed.title != "Untitled" else { continue }
            if existingTitles.contains(parsed.title.lowercased().trimmingCharacters(in: .whitespaces)) {
                summary.tunesSkipped += 1
                continue
            }
            let tune = Tune(title: parsed.title, type: parsed.type,
                            key: parsed.key, mode: parsed.mode, abc: parsed.abc)
            tune.composer = parsed.composer
            tune.aliases = parsed.aliases
            context.insert(tune)
            summary.tunesImported += 1
        }
        return summary
    }

    // MARK: - .ceol.json (export from the web/Pi app)

    /// Import a .ceol.json exported from any Fonn library. Merges tunes,
    /// recreates set/collection structure, skips duplicates — same rules
    /// as v3's import_ceol_json.
    public static func importCeolJSON(url: URL, context: ModelContext) throws -> Summary {
        let data = try readFileData(url: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.notCeolFile
        }
        guard json["ceol"] as? Int == 1 else { throw ImportError.notCeolFile }

        let ftype = json["type"] as? String ?? "tunes"
        if ftype == "library" {
            return try importLibrary(json: json, context: context)
        }
        let tuneList = (json["tunes"] as? [[String: Any]]) ?? []
        let existingTunes = try context.fetch(FetchDescriptor<Tune>())

        var summary = Summary()
        var titleToTune: [String: Tune] = [:]

        // 1. Import / match tunes
        for td in tuneList {
            let title = (td["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            let titleKey = title.lowercased()

            let sessionID = (td["session_id"] as? Int)
                ?? (td["session_id"] as? String).flatMap { Int($0) }

            var existing: Tune?
            if let sessionID {
                existing = existingTunes.first { $0.theSessionID == sessionID }
            }
            if existing == nil {
                existing = existingTunes.first {
                    $0.title.lowercased().trimmingCharacters(in: .whitespaces) == titleKey
                }
            }

            if let existing {
                titleToTune[titleKey] = existing
                summary.tunesSkipped += 1
                continue
            }

            let tune = Tune(title: title,
                            type: td["type"] as? String ?? "",
                            key: td["key"] as? String ?? "",
                            mode: td["mode"] as? String ?? "",
                            abc: td["abc"] as? String ?? "")
            tune.notes = td["notes"] as? String ?? ""
            tune.composer = td["composer"] as? String ?? ""
            tune.transcribedBy = td["transcribed_by"] as? String ?? ""
            tune.rating = td["rating"] as? Int ?? 0
            tune.onHitlist = (td["on_hitlist"] as? Int ?? 0) != 0
            tune.isFavourite = (td["is_favourite"] as? Int ?? 0) != 0
            tune.theSessionID = sessionID
            tune.sourceURL = td["source_url"] as? String ?? ""
            tune.practiceBPM = td["practice_bpm"] as? Int
            tune.aliases = (td["aliases"] as? [String]) ?? []
            context.insert(tune)
            titleToTune[titleKey] = tune
            summary.tunesImported += 1
        }

        // 2. Recreate collection (for collection exports)
        if ftype == "collection" {
            let name = (json["name"] as? String ?? "Imported Collection")
                .trimmingCharacters(in: .whitespaces)
            let existingCollections = try context.fetch(FetchDescriptor<TuneCollection>())
            let collection: TuneCollection
            if let found = existingCollections.first(where: {
                $0.name.lowercased().trimmingCharacters(in: .whitespaces) == name.lowercased()
            }) {
                collection = found
            } else {
                collection = TuneCollection(name: name,
                                            about: json["description"] as? String ?? "")
                context.insert(collection)
                summary.collectionsCreated += 1
            }
            for td in tuneList {
                let key = (td["title"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                if let tune = titleToTune[key],
                   collection.tunes?.contains(where: { $0 === tune }) != true {
                    collection.tunes?.append(tune)
                }
            }
        }

        // 3. Recreate the set itself (for set exports)
        if ftype == "set" {
            let name = (json["name"] as? String ?? "Imported Set").trimmingCharacters(in: .whitespaces)
            summary.setsCreated += createSet(named: name,
                                             notes: json["notes"] as? String ?? "",
                                             tuneDicts: tuneList,
                                             titleToTune: titleToTune,
                                             context: context)
        }

        // 4. Recreate any embedded sets (collection exports can include them)
        for sd in (json["sets"] as? [[String: Any]]) ?? [] {
            let name = (sd["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let tuneDicts = (sd["tunes"] as? [[String: Any]])
                ?? (sd["tunes"] as? [String])?.map { ["title": $0] }
                ?? []
            summary.setsCreated += createSet(named: name,
                                             notes: sd["notes"] as? String ?? "",
                                             tuneDicts: tuneDicts,
                                             titleToTune: titleToTune,
                                             context: context)
        }

        return summary
    }

    /// Whole-library import (type "library"): tunes carry their original ids,
    /// and sets/collections reference tunes BY ID — titles are ambiguous in a
    /// full library (multiple settings share a title). Duplicates are only
    /// skipped when both title and ABC match exactly.
    private static func importLibrary(json: [String: Any], context: ModelContext) throws -> Summary {
        var summary = Summary()

        // Duplicate key → the tune that owns it. Seeded from the library, then
        // extended as this import inserts, so a tune duplicated *within the
        // file* still resolves to something.
        //
        // It used to be a Set of keys plus a lookup in the pre-fetch, which
        // meant an in-file duplicate matched nothing on a fresh import: its id
        // never reached idToTune, and any version group it anchored was lost.
        // That cost 39 of 222 groups.
        var byDupKey: [String: Tune] = [:]
        for tune in try context.fetch(FetchDescriptor<Tune>()) {
            byDupKey[tune.title.lowercased() + "|#|" + tune.abc] = tune
        }

        var idToTune: [Int: Tune] = [:]
        // Bound to a local because the grouping pass below needs the same
        // array again once idToTune is complete.
        let tuneList = (json["tunes"] as? [[String: Any]]) ?? []

        for td in tuneList {
            let title = (td["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let abc = td["abc"] as? String ?? ""
            guard !title.isEmpty, !abc.isEmpty else { continue }
            let originalID = td["id"] as? Int

            let dupKey = title.lowercased() + "|#|" + abc
            if let match = byDupKey[dupKey] {
                // Already have this one — but still point its id at the tune
                // that stands in for it, or the grouping pass loses the link.
                summary.tunesSkipped += 1
                if let originalID { idToTune[originalID] = match }
                continue
            }

            let tune = Tune(title: title,
                            type: td["type"] as? String ?? "",
                            key: td["key"] as? String ?? "",
                            mode: td["mode"] as? String ?? "",
                            abc: abc)
            tune.notes = td["notes"] as? String ?? ""
            tune.composer = td["composer"] as? String ?? ""
            tune.transcribedBy = td["transcribed_by"] as? String ?? ""
            tune.rating = td["rating"] as? Int ?? 0
            tune.onHitlist = (td["on_hitlist"] as? Int ?? 0) != 0
            tune.isFavourite = (td["is_favourite"] as? Int ?? 0) != 0
            tune.theSessionID = (td["session_id"] as? Int)
                ?? (td["session_id"] as? String).flatMap { Int($0) }
            tune.theSessionSettingID = (td["setting_id"] as? String)
                ?? (td["setting_id"] as? Int).map(String.init) ?? ""
            tune.sourceURL = td["source_url"] as? String ?? ""
            tune.versionLabel = td["version_label"] as? String ?? ""
            tune.transpose = td["transpose"] as? Int ?? 0
            // Absent means no practice tempo, which is different from zero —
            // hence the optional rather than `?? 0`.
            tune.practiceBPM = td["practice_bpm"] as? Int
            tune.aliases = (td["aliases"] as? [String]) ?? []
            context.insert(tune)
            byDupKey[dupKey] = tune
            if let originalID { idToTune[originalID] = tune }
            summary.tunesImported += 1
        }

        // Version groups, rebuilt from the Pi's parent_id. Without this every
        // setting arrives as a separate top-level tune — 222 groups' worth of
        // work the Pi had already done, handed straight to the Duplicates
        // screen. Must run after the tune loop, when idToTune is complete.
        summary.versionGroups = rebuildVersionGroups(from: tuneList, idToTune: idToTune)
        // Grouping edits *existing* rows rather than inserting new ones. Don't
        // leave that to autosave — on a re-import, where nothing is inserted,
        // the grouping is the only change there is.
        try? context.save()

        let existingSets = (try? context.fetch(FetchDescriptor<TuneSet>())) ?? []
        // Which set each entry in the file's `sets` array turned into, so a
        // collection's `set_indexes` can be resolved afterwards. Filled for
        // skipped sets too — a collection should still point at the set you
        // already had rather than quietly losing it.
        var setForIndex: [Int: TuneSet] = [:]

        for (fileIndex, sd) in ((json["sets"] as? [[String: Any]]) ?? []).enumerated() {
            let name = (sd["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let set: TuneSet
            if let found = existingSets.first(where: {
                $0.name.lowercased().trimmingCharacters(in: .whitespaces) == name.lowercased()
            }) {
                // Same-name set already there: skip if it has tunes, but HEAL
                // it if it's an empty shell (e.g. from an earlier partial import).
                guard (found.entries ?? []).isEmpty else {
                    setForIndex[fileIndex] = found
                    continue
                }
                set = found
            } else {
                set = TuneSet(name: name)
                context.insert(set)
            }
            set.notes = sd["notes"] as? String ?? ""
            set.isFavourite = (sd["is_favourite"] as? Int ?? 0) != 0
            set.rating = sd["rating"] as? Int ?? 0
            set.onHitlist = (sd["on_hitlist"] as? Int ?? 0) != 0
            var position = 0
            let entries = ((sd["entries"] as? [[String: Any]]) ?? [])
                .sorted { (($0["position"] as? Int) ?? 0) < (($1["position"] as? Int) ?? 0) }
            for ed in entries {
                guard let tid = ed["tune_id"] as? Int, let tune = idToTune[tid] else { continue }
                let entry = SetEntry(position: position, tune: tune)
                entry.repeats = ed["repeats"] as? Int ?? 2
                entry.keyOverride = ed["key_override"] as? String ?? ""
                entry.tuneSet = set
                context.insert(entry)
                position += 1
            }
            setForIndex[fileIndex] = set
            summary.setsCreated += 1
        }

        let existingCollections = (try? context.fetch(FetchDescriptor<TuneCollection>())) ?? []
        for cd in (json["collections"] as? [[String: Any]]) ?? [] {
            let name = (cd["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let collection: TuneCollection
            if let found = existingCollections.first(where: {
                $0.name.lowercased().trimmingCharacters(in: .whitespaces) == name.lowercased()
            }) {
                collection = found
            } else {
                collection = TuneCollection(name: name, about: cd["description"] as? String ?? "")
                collection.isFavourite = (cd["is_favourite"] as? Int ?? 0) != 0
                collection.onHitlist = (cd["on_hitlist"] as? Int ?? 0) != 0
                context.insert(collection)
                summary.collectionsCreated += 1
            }
            for tid in (cd["tune_ids"] as? [Int]) ?? [] {
                if let tune = idToTune[tid],
                   collection.tunes?.contains(where: { $0 === tune }) != true {
                    collection.tunes?.append(tune)
                }
            }
            // Sets in the collection. Absent from files written before
            // collections could hold them, and from any other writer's export —
            // so its absence means "no sets", not "something went wrong".
            for index in (cd["set_indexes"] as? [Int]) ?? [] {
                if let set = setForIndex[index],
                   collection.sets?.contains(where: { $0 === set }) != true {
                    collection.sets?.append(set)
                }
            }
        }

        return summary
    }

    // MARK: - Folder bundle (library + recordings)

    /// Import a folder written by `export-ceol-json.py`: `library.ceol.json`
    /// alongside a `media/` folder of recordings.
    ///
    /// A folder rather than a zip because iOS has no zip reader in Foundation,
    /// and adding a package for one import would be a poor trade. The document
    /// picker hands back a security-scoped folder URL, which is all we need.
    /// `progress` is called on the main actor with (done, total) as files are
    /// copied, so the screen can say something other than nothing.
    @MainActor
    public static func importFolder(url: URL,
                             context: ModelContext,
                             progress: @escaping (Int, Int) -> Void = { _, _ in }) async throws -> Summary {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Be forgiving about which folder was handed over. In order: this one,
        // its parent (in case `media` was picked by mistake — easily done,
        // it's the folder that looks like it holds the recordings), then one
        // level down (in case a folder *containing* the export was picked).
        let names = ["library.ceol.json", "ceol-library.ceol.json"]
        func libraryFile(in folder: URL) -> URL? {
            names.map { folder.appendingPathComponent($0) }
                 .first { FileManager.default.fileExists(atPath: $0.path) }
        }

        var searched = [url]
        if url.lastPathComponent == "media" { searched.append(url.deletingLastPathComponent()) }
        if let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) {
            searched.append(contentsOf: children.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            })
        }

        guard let jsonURL = searched.lazy.compactMap({ libraryFile(in: $0) }).first
        else { throw ImportError.noLibraryInFolder }
        let bundleFolder = jsonURL.deletingLastPathComponent()

        guard let data = try? Data(contentsOf: jsonURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ceol"] as? Int == 1 else { throw ImportError.notCeolFile }

        var summary = try importLibrary(json: json, context: context)
        // "media" is what export-ceol-json.py writes, but a folder dragged out
        // of the phone through Finder is called "Media" — that is what
        // MediaStore names it in the app's Documents. Both are accepted, and
        // any other single folder alongside the JSON is taken as the media
        // folder rather than refused: there is only ever one.
        let mediaFolder = Self.mediaFolder(beside: bundleFolder)
        summary.mediaAttached = await attachMedia(
            from: json,
            mediaFolder: mediaFolder,
            context: context,
            progress: progress)
        try? context.save()
        return summary
    }

    /// Where the recordings are, beside the library file.
    ///
    /// The Pi writes `media`. A folder dragged out of the phone in Finder is
    /// `Media`, because that is what `MediaStore` calls it inside Documents.
    /// On a case-insensitive disk those are the same folder and this never
    /// matters; on a case-sensitive one, the difference is the whole import
    /// silently attaching nothing.
    private static func mediaFolder(beside folder: URL) -> URL {
        let manager = FileManager.default
        for name in ["media", "Media"] {
            let candidate = folder.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        // Neither name: if there is exactly one folder sitting beside the
        // library file, that is what the recordings are in whatever it is
        // called. Better than refusing over a name.
        let children = (try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let folders = children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        if folders.count == 1 { return folders[0] }
        return folder.appendingPathComponent("media", isDirectory: true)
    }

    /// Create MediaItems for every attachment the export listed, copying files
    /// out of the bundle into the app's own store. Idempotent: re-importing
    /// the same folder won't duplicate anything.
    @MainActor
    private static func attachMedia(from json: [String: Any],
                                    mediaFolder: URL,
                                    context: ModelContext,
                                    progress: @escaping (Int, Int) -> Void) async -> Int {
        let tuneDicts = (json["tunes"] as? [[String: Any]]) ?? []
        guard tuneDicts.contains(where: { !(($0["media"] as? [[String: Any]]) ?? []).isEmpty })
        else { return 0 }

        // Everything here stays on the main actor because SwiftData models do,
        // but we yield between files so SwiftUI can redraw. Without that the
        // whole import is one uninterrupted block and the app simply appears
        // to have died — which is exactly how it looked.
        let totalFiles = tuneDicts.reduce(0) { sum, dict in
            sum + (((dict["media"] as? [[String: Any]]) ?? [])
                .filter { !(($0["filename"] as? String) ?? "").isEmpty }.count)
        }
        var filesDone = 0
        progress(0, totalFiles)

        let allTunes = (try? context.fetch(FetchDescriptor<Tune>())) ?? []
        // Match on title + notation, the same identity the importer uses.
        var byKey: [String: Tune] = [:]
        for tune in allTunes {
            byKey[tune.title.lowercased() + "|#|" + tune.abc] = tune
        }

        var attached = 0
        for dict in tuneDicts {
            let items = (dict["media"] as? [[String: Any]]) ?? []
            guard !items.isEmpty else { continue }
            let title = (dict["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let abc = dict["abc"] as? String ?? ""
            guard let tune = byKey[title.lowercased() + "|#|" + abc] else { continue }

            let existing = tune.media ?? []
            for item in items {
                let kind = MediaKind(rawValue: item["kind"] as? String ?? "") ?? .audio
                let filename = item["filename"] as? String ?? ""
                let urlString = item["url"] as? String ?? ""

                if !urlString.isEmpty {
                    guard !existing.contains(where: { $0.urlString == urlString }) else { continue }
                    let media = MediaItem(kind: kind, urlString: urlString)
                    media.tune = tune
                    context.insert(media)
                    attached += 1
                    continue
                }

                guard !filename.isEmpty else { continue }
                filesDone += 1
                progress(filesDone, totalFiles)
                // Let the run loop breathe: one frame per file keeps the
                // progress readable and the app alive to the watchdog.
                await Task.yield()
                let source = mediaFolder.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                // Remember where it came from, so importing the folder twice
                // doesn't attach everything twice. The Pi's own file names are
                // hex blobs, so they're no use as a display title — the tune's
                // name reads better.
                let origin = "pi:" + filename
                guard !existing.contains(where: { $0.notes == origin }) else { continue }
                guard let stored = MediaStore.shared.copyIn(from: source) else { continue }
                let media = MediaItem(kind: kind, title: title, filename: stored)
                media.notes = origin
                media.tune = tune
                context.insert(media)
                attached += 1
            }
        }
        return attached
    }

    /// Turn the Pi's `parent_id` / `is_default` into the iOS model's shared
    /// `groupID` plus one `isDefaultVersion` per group. Returns the number of
    /// groups rebuilt.
    ///
    /// Two details that matter:
    /// - A child whose parent didn't come across is left ungrouped rather than
    ///   made the root of a group of one.
    /// - Seven of the Pi's groups have no member flagged as default. Rather
    ///   than leave a group with none — sets would then have nothing to play —
    ///   the parent takes the role.
    @discardableResult
    private static func rebuildVersionGroups(from dicts: [[String: Any]],
                                             idToTune: [Int: Tune]) -> Int {
        var members: [Int: [Tune]] = [:]     // root id → every version in it
        var flaggedDefault: [Int: Tune] = [:]
        var rootsWithChildren = Set<Int>()

        for dict in dicts {
            guard let id = dict["id"] as? Int, let tune = idToTune[id] else { continue }
            let parent = dict["parent_id"] as? Int
            if let parent {
                guard idToTune[parent] != nil else { continue }   // orphan
                rootsWithChildren.insert(parent)
            }
            let root = parent ?? id
            members[root, default: []].append(tune)
            if (dict["is_default"] as? Int ?? 0) != 0 { flaggedDefault[root] = tune }
        }

        var rebuilt = 0
        for root in rootsWithChildren {
            // Deduplicate by identity first. On a re-import into an existing
            // library two Pi ids can resolve to the same tune (they were exact
            // duplicates in the file), and counting it twice would create a
            // "group" containing one tune.
            var seen = Set<ObjectIdentifier>()
            let group = (members[root] ?? []).filter { seen.insert(ObjectIdentifier($0)).inserted }
            guard group.count > 1 else { continue }
            let groupID = UUID()
            let chosen = flaggedDefault[root] ?? idToTune[root] ?? group[0]
            for tune in group {
                tune.groupID = groupID
                tune.isDefaultVersion = (tune === chosen)
            }
            rebuilt += 1
        }
        return rebuilt
    }

    /// Returns 1 if a new set was created, 0 if one with the same name existed.
    private static func createSet(named name: String, notes: String,
                                  tuneDicts: [[String: Any]],
                                  titleToTune: [String: Tune],
                                  context: ModelContext) -> Int {
        let existingSets = (try? context.fetch(FetchDescriptor<TuneSet>())) ?? []
        guard !existingSets.contains(where: {
            $0.name.lowercased().trimmingCharacters(in: .whitespaces) == name.lowercased()
        }) else { return 0 }

        let set = TuneSet(name: name)
        set.notes = notes
        context.insert(set)

        var position = 0
        let ordered = tuneDicts.sorted {
            (($0["_position"] as? Int) ?? 0) < (($1["_position"] as? Int) ?? 0)
        }
        for td in ordered {
            let key = (td["title"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard let tune = titleToTune[key] else { continue }
            let entry = SetEntry(position: position, tune: tune)
            entry.keyOverride = td["_key_override"] as? String ?? ""
            entry.tuneSet = set
            context.insert(entry)
            position += 1
        }
        return 1
    }

    // MARK: - File reading (handles Files-app security scoping)

    private static func readFileData(url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        return data
    }

    private static func readFile(url: URL) throws -> String {
        let data = try readFileData(url: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw ImportError.unreadable
    }
}
