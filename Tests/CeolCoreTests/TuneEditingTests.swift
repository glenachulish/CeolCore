import Testing
import Foundation
import SwiftData
@testable import CeolCore

/// The rules for saving an edited tune.
///
/// These matter more than most tests in the package because they are the only
/// code in it that can silently change what a set plays. A version group is
/// invisible in the tune list — the list shows one row per group — so an edit
/// that joins the wrong group, or takes over a set it should not have, leaves
/// no trace anyone would notice until they played the set.
///
/// Both apps call these, which is the point of them being here.
struct TuneEditingTests {

    /// A fresh in-memory library. Every test gets its own, so nothing carries
    /// between them.
    private func library() throws -> ModelContext {
        let container = try ModelContainer(
            for: Tune.self, TuneSet.self, SetEntry.self,
                TuneCollection.self, MediaItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func tune(_ title: String, abc: String = "X:1\nK:D\nDED|",
                      in context: ModelContext) -> Tune {
        let t = Tune(title: title, type: "reel", key: "D", mode: "major", abc: abc)
        context.insert(t)
        return t
    }

    // MARK: - Saving over

    @Test("saving over replaces the notation and leaves one tune")
    func inPlaceKeepsOneTune() throws {
        let context = try library()
        let t = tune("The Butterfly", in: context)
        try context.save()

        VersionTools.saveEditInPlace(t, abc: "X:1\nK:D\nFED|", in: context)

        #expect(t.abc == "X:1\nK:D\nFED|")
        let all = try context.fetch(FetchDescriptor<Tune>())
        #expect(all.count == 1)
    }

    // MARK: - Saving as a version

    @Test("saving as a version leaves the original alone and groups the two")
    func versionJoinsAGroup() throws {
        let context = try library()
        let original = tune("The Butterfly", in: context)
        try context.save()

        let outcome = VersionTools.saveEdited(original, abc: "X:1\nK:D\nFED|",
                                              named: "My setting", in: context)

        #expect(original.abc == "X:1\nK:D\nDED|")
        #expect(outcome.version.abc == "X:1\nK:D\nFED|")
        #expect(original.groupID != nil)
        #expect(outcome.version.groupID == original.groupID)
        #expect(VersionTools.versions(of: original, in: context).count == 2)
    }

    /// The difference from `saveTransposed`, which deliberately does not.
    @Test("the edit becomes the version the library shows")
    func editBecomesDefault() throws {
        let context = try library()
        let original = tune("The Butterfly", in: context)
        try context.save()

        let outcome = VersionTools.saveEdited(original, abc: "X:1\nK:D\nFED|",
                                              named: "My setting", in: context)

        #expect(outcome.version.isDefaultVersion)
        #expect(!original.isDefaultVersion)
    }

    @Test("an empty name falls back to the tune's own, marked as edited")
    func emptyNameFallsBack() throws {
        let context = try library()
        let original = tune("The Butterfly", in: context)
        try context.save()

        let outcome = VersionTools.saveEdited(original, abc: "X:1\nK:D\nFED|",
                                              named: "   ", in: context)

        #expect(outcome.name == "The Butterfly (edited)")
        #expect(outcome.version.title == "The Butterfly (edited)")
    }

    @Test("what the tune is carries over to the version")
    func detailsCarryOver() throws {
        let context = try library()
        let original = tune("The Butterfly", in: context)
        original.composer = "Trad"
        original.notes = "From Mary's playing"
        original.rating = 4
        original.isFavourite = true
        original.onHitlist = true
        original.aliases = ["Butterfly, The"]
        try context.save()

        let outcome = VersionTools.saveEdited(original, abc: "X:1\nK:D\nFED|",
                                              named: "My setting", in: context)
        let edited = outcome.version

        #expect(edited.composer == "Trad")
        #expect(edited.notes == "From Mary's playing")
        #expect(edited.rating == 4)
        #expect(edited.isFavourite)
        #expect(edited.onHitlist)
        #expect(edited.aliases == ["Butterfly, The"])
        // A version of a tune is notation in its own right, not a display
        // offset applied to somebody else's.
        #expect(edited.transpose == 0)
    }

    // MARK: - Sets

    /// The consequence worth testing: a set pointing at the tune you edited
    /// should end up playing the edit, and the count reported should say so.
    @Test("sets follow the edit, and are counted")
    func setsFollowTheEdit() throws {
        let context = try library()
        let original = tune("The Butterfly", in: context)

        let set = TuneSet(name: "Tuesday")
        context.insert(set)
        let entry = SetEntry(position: 0, repeats: 1, tune: original)
        entry.tuneSet = set
        context.insert(entry)
        try context.save()

        let outcome = VersionTools.saveEdited(original, abc: "X:1\nK:D\nFED|",
                                              named: "My setting", in: context)

        #expect(outcome.setsRepointed == 1)
        #expect(entry.tune === outcome.version)
    }

    @Test("a tune in no sets reports nothing moved")
    func noSetsNothingMoved() throws {
        let context = try library()
        let original = tune("The Butterfly", in: context)
        try context.save()

        let outcome = VersionTools.saveEdited(original, abc: "X:1\nK:D\nFED|",
                                              named: "My setting", in: context)

        #expect(outcome.setsRepointed == 0)
    }

    /// Editing the second setting of a tune that already has versions should
    /// add a third to the same group, not start a new one.
    @Test("editing a version adds to the group it is already in")
    func editingAVersionStaysInTheGroup() throws {
        let context = try library()
        let first = tune("The Butterfly", in: context)
        try context.save()

        let second = VersionTools.saveEdited(first, abc: "X:1\nK:D\nFED|",
                                             named: "Second", in: context).version
        let third = VersionTools.saveEdited(second, abc: "X:1\nK:D\nAED|",
                                            named: "Third", in: context).version

        #expect(third.groupID == first.groupID)
        #expect(VersionTools.versions(of: first, in: context).count == 3)
        #expect(third.isDefaultVersion)
        #expect(!second.isDefaultVersion)
    }
}
