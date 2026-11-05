import Foundation
import SwiftData

/// Six tunes to open the app with.
///
/// Fonn used to ship empty, on the principle that a tune library should be
/// yours rather than somebody else's tune book. That principle is right and
/// the conclusion was wrong: an app that opens to nothing gives a new reader —
/// and an App Store reviewer — no idea what it is for, and it is a poor first
/// thirty seconds for something people have paid for.
///
/// So: three Scottish tunes, three Irish, one set, in a collection called
/// "Starter tunes" that can be deleted in a single action. The point is still
/// your own library; these are just something to press play on.
///
/// ## On copyright, which is not where people expect
///
/// The *melodies* are public domain several times over — all six are in print
/// by the 1880s (Kerr's *Merry Melodies*, the Skye Collection) or by 1903
/// (O'Neill's *Music of Ireland*). What can carry a fresh copyright is a
/// particular **transcription**, which is why none of this came from
/// thesession.org, from FluteFling, or from any modern book: those are other
/// people's settings, and The Session's are ODbL, which would put an
/// attribution obligation on a paid app.
///
/// These settings were written out for this purpose and checked bar by bar
/// against abcjs before shipping.
public enum StarterLibrary {

    /// Set once the seed has run, so deleting the starter tunes makes them
    /// stay deleted.
    ///
    /// In UserDefaults rather than in the store, deliberately. It is a fact
    /// about *this install*, not about the library — and if it synced, a
    /// second device would refuse to seed even when its own store was empty.
    private static let seededKey = "ceol.starterSeeded"

    public static var hasSeeded: Bool {
        get { UserDefaults.standard.bool(forKey: seededKey) }
        set { UserDefaults.standard.set(newValue, forKey: seededKey) }
    }

    /// The bundled library file.
    /// Named `starter-library.json` and not `starter.ceol.json`: a two-part
    /// extension makes `url(forResource:withExtension:)` ambiguous, and the
    /// importer reads the contents rather than the name — it checks for
    /// `"ceol": 1` inside — so the filename is free to be unambiguous.
    static var file: URL? {
        Bundle.module.url(forResource: "starter-library", withExtension: "json",
                          subdirectory: "Seed")
    }

    /// Put the starter tunes in, if this library has never had them and has
    /// nothing else either.
    ///
    /// **Both conditions matter.** The flag alone is not enough: a reinstall
    /// clears UserDefaults, and if CloudKit is about to deliver 1,800 tunes we
    /// would be adding six strangers to somebody's established library. The
    /// emptiness check is what prevents that — and the caller waits a moment
    /// before asking, so a sync that is already on its way gets to win.
    ///
    /// It is still a race, and an honest one: on a very slow connection a
    /// returning reader could see the six appear alongside their own. They
    /// arrive in a named collection precisely so that is a tidy-up rather than
    /// a puzzle.
    @discardableResult
    @MainActor
    public static func seedIfNeeded(context: ModelContext) -> Bool {
        guard !hasSeeded else { return false }

        let existing = (try? context.fetchCount(FetchDescriptor<Tune>())) ?? 0
        guard existing == 0 else {
            // Somebody's library is already here. Never seed over it, and
            // don't ask again.
            hasSeeded = true
            return false
        }

        guard let file else { return false }
        // The starter tunes are the app's gift to a new reader, not something
        // they added, so they neither use up the free version's allowance nor
        // are refused by it.
        guard let summary = try? TuneAllowance.shared.uncounted({
                  try FileImports.importCeolJSON(url: file, context: context)
              }),
              summary.tunesImported > 0 else {
            // A failed seed is not worth a second attempt on every launch, but
            // it is worth another go next install, so the flag stays off.
            return false
        }

        hasSeeded = true
        return true
    }

    // MARK: - On request

    /// The starter file as shipped, parsed. nil only if the build is broken.
    static var shipped: [String: Any]? {
        guard let file,
              let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// The starter tunes' titles, compared the way `key(_:)` compares them.
    /// Read once: the library screen asks on every redraw.
    static let shippedKeys: [String] = {
        ((StarterLibrary.shipped?["tunes"] as? [[String: Any]]) ?? [])
            .compactMap { $0["title"] as? String }
            .map { StarterLibrary.key($0) }
    }()

    /// How many starter tunes there are. Six, unless the file changes.
    public static var total: Int { shippedKeys.count }

    /// How a title is compared when asking whether a starter tune is here.
    ///
    /// By title alone, not by title and notation the way the importer matches
    /// duplicates. A starter tune somebody has corrected, or added a version
    /// to, is still *that tune*; matching on notation would hand them the
    /// shipped setting back as a second copy beside their own.
    static func key(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// How many starter tunes a library with these titles is missing.
    public static func missingCount<S: Sequence>(presentTitles: S) -> Int
    where S.Element == String {
        let present = Set(presentTitles.map(key))
        return shippedKeys.filter { !present.contains($0) }.count
    }

    /// `json` cut down to the tunes whose titles are not in `present`.
    ///
    /// Sets and collections are cut down to match, or asking for two missing
    /// tunes would also re-file four the reader had deliberately taken out of
    /// "Starter tunes". A set comes back only if *every* tune in it is being
    /// added: half a set is worse than none, and a set the reader deleted
    /// while keeping its tunes was a decision. A collection left with nothing
    /// in it is dropped, so asking when nothing is missing makes nothing.
    ///
    /// Mirrored by `tools/verify_starter_missing.py`.
    static func onlyMissing(_ json: [String: Any], present: Set<String>) -> [String: Any] {
        let tunes = ((json["tunes"] as? [[String: Any]]) ?? []).filter {
            !present.contains(key($0["title"] as? String ?? ""))
        }
        let keptIDs = Set(tunes.compactMap { $0["id"] as? Int })

        var newIndex: [Int: Int] = [:]
        var sets: [[String: Any]] = []
        for (oldIndex, set) in ((json["sets"] as? [[String: Any]]) ?? []).enumerated() {
            let wanted = ((set["entries"] as? [[String: Any]]) ?? [])
                .compactMap { $0["tune_id"] as? Int }
            guard !wanted.isEmpty, wanted.allSatisfy(keptIDs.contains) else { continue }
            newIndex[oldIndex] = sets.count
            sets.append(set)
        }

        var collections: [[String: Any]] = []
        for var c in (json["collections"] as? [[String: Any]]) ?? [] {
            let ids = ((c["tune_ids"] as? [Int]) ?? []).filter(keptIDs.contains)
            let setIndexes = ((c["set_indexes"] as? [Int]) ?? []).compactMap { newIndex[$0] }
            guard !ids.isEmpty || !setIndexes.isEmpty else { continue }
            c["tune_ids"] = ids
            if c["set_indexes"] != nil { c["set_indexes"] = setIndexes }
            collections.append(c)
        }

        var out = json
        out["tunes"] = tunes
        out["sets"] = sets
        out["collections"] = collections
        return out
    }

    public struct NotInBuild: LocalizedError {
        public var errorDescription: String? {
            "The starter tunes are missing from this copy of Fonn."
        }
    }

    /// Add whichever starter tunes this library is missing, with their set
    /// and collection.
    ///
    /// The way in for anyone the automatic seed missed, or who deleted the
    /// starter tunes and wants them back. A tap cannot race an iCloud sync the
    /// way the launch-time seed can, so it is safe in either storage mode.
    /// Tunes already here are left exactly as they are; see `onlyMissing`.
    /// Like the seed, these never count towards the free version's 20.
    @discardableResult
    @MainActor
    public static func addMissing(context: ModelContext) throws -> FileImports.Summary {
        guard let json = shipped else { throw NotInBuild() }
        let present = Set(((try? context.fetch(FetchDescriptor<Tune>())) ?? []).map { key($0.title) })
        let trimmed = onlyMissing(json, present: present)
        guard !((trimmed["tunes"] as? [[String: Any]]) ?? []).isEmpty else {
            return FileImports.Summary()
        }
        let summary = try TuneAllowance.shared.uncounted {
            try FileImports.importLibrary(json: trimmed, context: context)
        }
        try context.save()
        // So the automatic seed cannot add them a second time later.
        hasSeeded = true
        return summary
    }
}
