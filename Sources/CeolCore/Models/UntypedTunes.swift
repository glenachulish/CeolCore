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
    public static func release(_ tunes: [Tune]) {
        let typed = tunes.filter { !$0.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let context = typed.first?.modelContext,
              let collection = try? context.fetch(FetchDescriptor<TuneCollection>())
                .first(where: { $0.name == collectionName }),
              var members = collection.tunes, !members.isEmpty else { return }
        let groups = Set(typed.compactMap(\.groupID))
        let before = members.count
        members.removeAll { member in
            typed.contains { $0 === member } || (member.groupID.map(groups.contains) ?? false)
        }
        guard members.count != before else { return }
        collection.tunes = members
        try? context.save()
    }
}
