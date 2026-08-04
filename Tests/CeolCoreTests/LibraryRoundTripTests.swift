import Testing
import Foundation
@testable import CeolCore

/// The regression net for the whole refactor.
///
/// These numbers are the real library — `~/Ceol/ceol-library.ceol.json`,
/// counted straight out of the JSON:
///
///     tunes 1571   sets 113   collections 19
///     version groups (distinct parent_id) 222
///     set entries 306
///     tunes with media 221   media items 360
///
/// The point is to run this BEFORE anything moves, to establish that the
/// current code produces them, and again after. A refactor that changes any of
/// them has broken something.
///
/// 222 is the one to watch. `FileImports.rebuildVersionGroups` carries a
/// comment recording an earlier bug that cost 39 groups without a word — that
/// is exactly the kind of failure a count catches and reading the code does not.
///
/// Fleshed out once Models.swift and FileImports.swift are in the package.
struct LibraryRoundTripTests {

    /// Where the real library lives. Not bundled — it is 1.4 MB and it is the
    /// user's own data, so the test reads it in place and skips if it has moved.
    static var libraryURL: URL {
        URL(filePath: NSHomeDirectory())
            .appending(path: "Ceol/ceol-library.ceol.json")
    }

    @Test("the package is attached")
    func packageAttaches() {
        #expect(CeolCore.marker == "CeolCore attached")
    }

    // TODO: once Models + FileImports are in the package —
    //
    // @Test("importing the real library gives the expected counts")
    // func importCounts() throws {
    //     let container = try ModelContainer(
    //         for: Tune.self, TuneSet.self, SetEntry.self,
    //             TuneCollection.self, MediaItem.self,
    //         configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    //     let context = ModelContext(container)
    //     let summary = try FileImports.importCeolJSON(url: Self.libraryURL,
    //                                                  context: context)
    //     #expect(summary.tunesImported == 1571)
    //     #expect(summary.setsCreated == 113)
    //     #expect(summary.collectionsCreated == 19)
    //     #expect(summary.versionGroups == 222)
    // }
    //
    // @Test("export then re-import is stable")
    // func roundTrip() throws {
    //     ... export with LibraryExport.libraryJSON, import the result into a
    //     second in-memory container, assert the same six numbers. Round-trip
    //     stability is the property Stage 1 depends on: the Mac writes this
    //     file back for the phone to read.
    // }
}
