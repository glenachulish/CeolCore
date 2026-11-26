import Foundation
import SwiftData

// FONN-NOTYPE-1
/// Every tune with no type, gathered into one collection so each can be given
/// a type. Running it again refreshes the collection: tunes given a type since
/// drop out and newly imported untyped tunes come in, so the collection is a
/// to-do list that empties as you work through it.
///
/// Only the version the library shows (the default) is judged; the other
/// versions of a tune go with it.
public enum UntypedTunes {
    public static let collectionName = "No tune type"

    @MainActor
    public static func gather(in context: ModelContext) throws -> (collection: TuneCollection, count: Int) {
        let all = try context.fetch(FetchDescriptor<Tune>())
        let untyped = all.filter {
            $0.isDefaultVersion && $0.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let collection: TuneCollection
        if let existing = try context.fetch(FetchDescriptor<TuneCollection>())
            .first(where: { $0.name == collectionName }) {
            collection = existing
        } else {
            collection = TuneCollection(
                name: collectionName,
                about: "Tunes with no type yet. Give each one a type and it leaves this collection.")
            context.insert(collection)
        }
        collection.tunes = untyped
        try context.save()
        return (collection, untyped.count)
    }

    /// FONN-NOTYPELIVE-1: a tune given a type leaves the collection there and
    /// then, rather than at the next gather. Callum gave tunes their types in
    /// Details and they stayed put, which made the collection useless as a
    /// to-do list. The collection holds the version the library shows, and a
    /// type can be set on another version (or on a new version saved from
    /// Edit ABC), so every member of the same version group goes with it.
    /// Call after setting `type`; tunes still without one are left. Not
    /// @MainActor: UnknownTunes.adopt calls it from a plain function, and
    /// every caller is on the main thread with the tunes anyway.
    /// Returns the members it took out (FONN-QUICKTYPE-1, for Undo).
    @discardableResult
    public static func release(_ tunes: [Tune]) -> [Tune] {
        let typed = tunes.filter { !$0.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let context = typed.first?.modelContext,
              let collection = try? context.fetch(FetchDescriptor<TuneCollection>())
                .first(where: { $0.name == collectionName }),
              var members = collection.tunes, !members.isEmpty else { return [] }
        let groups = Set(typed.compactMap(\.groupID))
        let isReleased: (Tune) -> Bool = { member in
            typed.contains { $0 === member } || (member.groupID.map(groups.contains) ?? false)
        }
        let removed = members.filter(isReleased)
        guard !removed.isEmpty else { return [] }
        members.removeAll(where: isReleased)
        collection.tunes = members
        try? context.save()
        return removed
    }

    // FONN-QUICKTYPE-1
    /// The types offered by the quick Type button on a tune with none,
    /// commonest first (the iPhone's details list, in its order).
    public static let commonTypes = [
        "reel", "jig", "hornpipe", "slip jig", "polka", "waltz", "march", "strathspey",
        "slide", "hop jig", "air", "slow air",
        "mazurka", "barndance", "schottische", "highland", "set dance",
    ]

    /// What one quick Type tap changed, so it can be put back.
    public struct QuickTypeChange {
        public let title: String
        public let type: String
        let versions: [Tune]
        let removed: [Tune]
    }

    /// FONN-QUICKTYPE-1: give a tune a type from its row, without opening
    /// Details. Every version of the tune still without a type gets it (as
    /// Find Types on The Session does), and the tune leaves "No tune type".
    @MainActor
    @discardableResult
    public static func setType(_ type: String, on tune: Tune) -> QuickTypeChange? {
        let clean = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty, let context = tune.modelContext else { return nil }
        var versions = [tune]
        if let group = tune.groupID {
            let all = (try? context.fetch(FetchDescriptor<Tune>())) ?? []
            versions = all.filter { $0.groupID == group }
            if !versions.contains(where: { $0 === tune }) { versions.append(tune) }
        }
        let changed = versions.filter {
            $0.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !changed.isEmpty else { return nil }
        for version in changed {
            version.type = clean
            version.updatedAt = Date()
        }
        try? context.save()
        let removed = release(changed)
        return QuickTypeChange(title: tune.title, type: clean, versions: changed, removed: removed)
    }

    /// Puts a quick Type back: no type again, and back in "No tune type" if
    /// it was taken out.
    @MainActor
    public static func undo(_ change: QuickTypeChange) {
        guard let context = (change.versions.first ?? change.removed.first)?.modelContext else { return }
        for version in change.versions {
            version.type = ""
            version.updatedAt = Date()
        }
        if !change.removed.isEmpty,
           let collection = try? context.fetch(FetchDescriptor<TuneCollection>())
            .first(where: { $0.name == collectionName }) {
            var members = collection.tunes ?? []
            for tune in change.removed where !members.contains(where: { $0 === tune }) {
                members.append(tune)
            }
            collection.tunes = members
        }
        try? context.save()
    }
}
