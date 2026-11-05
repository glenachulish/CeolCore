import Testing
import Foundation
import SwiftData
@testable import CeolCore

// FONN-SETFILTER-1
@Suite("Filtering sets")
struct SetFilterTests {

    private func library() throws -> ModelContext {
        let container = try ModelContainer(
            for: Tune.self, TuneSet.self, SetEntry.self,
                TuneCollection.self, MediaItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func set(_ name: String, _ tunes: [(String, String, String)],
                     in context: ModelContext) -> TuneSet {
        let s = TuneSet(name: name)
        context.insert(s)
        for (i, (title, type, key)) in tunes.enumerated() {
            let t = Tune(title: title, type: type, key: key, mode: "major", abc: "X:1\nK:\(key)\nDED|")
            context.insert(t)
            let e = SetEntry(position: i, repeats: 1, tune: t)
            e.tuneSet = s
            context.insert(e)
        }
        return s
    }

    @Test("a type finds every set with a tune of that type, mixed sets included")
    func typeContains() throws {
        let c = try library()
        let reels = set("Reels", [("A", "reel", "D"), ("B", "reel", "G")], in: c)
        let mixed = set("Mixed", [("C", "jig", "D"), ("D", "reel", "A")], in: c)
        let jigs = set("Jigs", [("E", "jig", "G")], in: c)
        var f = SetListFilter()
        f.type = "reel"
        #expect(f.matches(reels))
        #expect(f.matches(mixed))
        #expect(!f.matches(jigs))
    }

    @Test("stars, hitlist and favourite are the set's own")
    func ownMarks() throws {
        let c = try library()
        let s = set("Tuesday", [("A", "reel", "D")], in: c)
        s.rating = 3
        var f = SetListFilter()
        f.minRating = 4
        #expect(!f.matches(s))
        f.minRating = 3
        #expect(f.matches(s))
        f.hitlist = true
        #expect(!f.matches(s))
    }

    @Test("a recording on a tune in the set counts")
    func mediaOnTunes() throws {
        let c = try library()
        let s = set("With recording", [("A", "reel", "D")], in: c)
        var f = SetListFilter()
        f.content = .audio
        #expect(!f.matches(s))
        let item = MediaItem(kind: .audio, title: "Take 1", filename: "x.m4a")
        item.tune = s.orderedEntries.first?.tune
        c.insert(item)
        #expect(f.matches(s))
    }

    @Test("the chip names the type with the right article")
    func chipLabel() {
        var f = SetListFilter()
        f.type = "Air"
        #expect(f.active.first?.label == "Has an air")
        f.type = "reel"
        #expect(f.active.first?.label == "Has a reel")
    }

    // FONN-OPENHERE-1: "Open Fonn here" saves the filter as JSON.
    @Test func survivesBeingSaved() throws {
        var f = SetListFilter()
        f.type = "jig"
        f.key = "D"
        f.minRating = 4
        f.content = .audio
        f.inCollection = .notInCollection
        let data = try JSONEncoder().encode(f)
        #expect(try JSONDecoder().decode(SetListFilter.self, from: data) == f)
    }

    // FONN-OPENHERE-2: the Mac's Open Fonn Here saves the tune filter the same way.
    @Test func tuneFilterSurvivesBeingSaved() throws {
        var f = TuneFilter()
        f.type = "reel"
        f.key = "G"
        f.minRating = 4
        f.hitlist = true
        f.content = .audio
        f.inSet = .notInSet
        let data = try JSONEncoder().encode(f)
        #expect(try JSONDecoder().decode(TuneFilter.self, from: data) == f)
    }
}
