import Testing
import Foundation
import SwiftData
@testable import CeolCore

/// Adding the starter tunes on request. Mirrored, rules only, by
/// `tools/verify_starter_missing.py`, which has run; these have not been
/// compiled where they were written.
@MainActor
struct StarterMissingTests {

    private func library() throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainer(
            for: Tune.self, TuneSet.self, SetEntry.self,
                TuneCollection.self, MediaItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (container, container.mainContext)
    }

    private func count<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<T>())) ?? -1
    }

    @Test("the starter file is in the package and has six tunes")
    func shippedIsThere() {
        #expect(StarterLibrary.shipped != nil)
        #expect(StarterLibrary.total == 6)
    }

    @Test("an empty library is missing all six, a full one none, however spelt")
    func counting() {
        #expect(StarterLibrary.missingCount(presentTitles: [String]()) == 6)
        let shouted = StarterLibrary.shippedKeys.map { "  " + $0.uppercased() + " " }
        #expect(StarterLibrary.missingCount(presentTitles: shouted) == 0)
    }

    @Test("into an empty library: six tunes, one set, one collection")
    func intoEmpty() throws {
        let (_, context) = try library()
        let summary = try StarterLibrary.addMissing(context: context)
        #expect(summary.tunesImported == 6)
        #expect(count(Tune.self, context) == 6)
        #expect(count(TuneSet.self, context) == 1)
        #expect(count(TuneCollection.self, context) == 1)
        StarterLibrary.hasSeeded = false
    }

    @Test("asking twice adds nothing the second time")
    func twice() throws {
        let (_, context) = try library()
        try StarterLibrary.addMissing(context: context)
        let again = try StarterLibrary.addMissing(context: context)
        #expect(again.tunesImported == 0)
        #expect(count(Tune.self, context) == 6)
        #expect(count(TuneSet.self, context) == 1)
        #expect(count(TuneCollection.self, context) == 1)
        StarterLibrary.hasSeeded = false
    }

    @Test("an edited starter tune is left alone, and a deleted one comes back")
    func editedAndDeleted() throws {
        let (_, context) = try library()
        try StarterLibrary.addMissing(context: context)
        let tunes = try context.fetch(FetchDescriptor<Tune>(sortBy: [SortDescriptor(\.title)]))
        tunes[0].abc += "\n% my own ending"
        let editedABC = tunes[0].abc
        let gone = tunes[1].title
        context.delete(tunes[1])
        try context.save()

        let summary = try StarterLibrary.addMissing(context: context)
        #expect(summary.tunesImported == 1)
        let after = try context.fetch(FetchDescriptor<Tune>())
        #expect(after.count == 6)
        #expect(after.contains { $0.title == gone })
        #expect(after.filter { $0.title == tunes[0].title }.count == 1)
        #expect(after.first { $0.title == tunes[0].title }?.abc == editedABC)
        #expect(count(TuneCollection.self, context) == 1)
        StarterLibrary.hasSeeded = false
    }

    @Test("they do not use up the free version's allowance")
    func uncounted() throws {
        let (_, context) = try library()
        let before = TuneAllowance.shared.used
        try StarterLibrary.addMissing(context: context)
        #expect(TuneAllowance.shared.used == before)
        StarterLibrary.hasSeeded = false
    }
}
