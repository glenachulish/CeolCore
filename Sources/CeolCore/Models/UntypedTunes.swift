import Foundation
import SwiftUI
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
    /// FONN-REGIONTYPES-1: the types Fonn offers, by tradition. The first
    /// group is the commonest, in the iPhone details list's old order; the
    /// others are the dances of the Breton, Galician and Asturian, and Nordic
    /// traditions, which The Session has no types for (its tunes from them
    /// come in as reel, jig, waltz…).
    public struct TypeGroup: Identifiable {
        public let name: String
        public let types: [String]
        public var id: String { name }
    }

    public static let typeGroups: [TypeGroup] = [
        TypeGroup(name: "Irish, Scottish, English", types: [
            "reel", "jig", "hornpipe", "slip jig", "polka", "waltz", "march", "strathspey",
            "slide", "hop jig", "air", "slow air",
            "mazurka", "barndance", "schottische", "highland", "set dance", "three-two",
        ]),
        TypeGroup(name: "Breton", types: [
            "an dro", "hanter dro", "gavotte", "plinn", "laridé", "kas a-barh", "fisel", "ridée",
        ]),
        TypeGroup(name: "Galician and Asturian", types: [
            "muiñeira", "jota", "alborada", "pasodoble",
        ]),
        TypeGroup(name: "Nordic", types: [
            "polska", "gånglåt", "schottis", "reinlender", "springar", "halling", "hambo",
        ]),
    ]

    /// Every type above, in order.
    public static let commonTypes: [String] = typeGroups.flatMap(\.types)

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

// FONN-NOTYPEPAGE-1
/// At the top of a tune's page while it has no type: look at the music (or
/// the PDF), then choose the type here. `onTyped` is told what changed, so
/// a page opened from "No tune type" can go back to the list.
public struct NoTypeBanner: View {
    @Bindable var tune: Tune
    let onTyped: (UntypedTunes.QuickTypeChange) -> Void

    public init(tune: Tune, onTyped: @escaping (UntypedTunes.QuickTypeChange) -> Void) {
        self.tune = tune
        self.onTyped = onTyped
    }

    public var body: some View {
        if tune.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "tag.fill")
                    .font(.title3).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No type yet")
                        .font(.subheadline.weight(.semibold))
                    Text("Look at the music, then choose its type.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Menu {
                    TypeMenuItems { type in
                        if let change = UntypedTunes.setType(type, on: tune) { onTyped(change) }
                    }
                } label: {
                    Label("Type", systemImage: "chevron.down")
                }
                .fixedSize()
                #if os(iOS)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                #endif
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.1))
        }
    }
}

/// FONN-REGIONTYPES-1: the type choices for a Menu: the commonest types,
/// then one submenu per tradition, so the list stays short on a phone.
public struct TypeMenuItems: View {
    let onPick: (String) -> Void

    public init(onPick: @escaping (String) -> Void) {
        self.onPick = onPick
    }

    public var body: some View {
        ForEach(UntypedTunes.typeGroups) { group in
            if group.id == UntypedTunes.typeGroups.first?.id {
                ForEach(group.types, id: \.self) { type in
                    Button(type.capitalized) { onPick(type) }
                }
            } else {
                Menu(group.name) {
                    ForEach(group.types, id: \.self) { type in
                        Button(type.capitalized) { onPick(type) }
                    }
                }
            }
        }
    }
}
