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
        guard let summary = try? FileImports.importCeolJSON(url: file, context: context),
              summary.tunesImported > 0 else {
            // A failed seed is not worth a second attempt on every launch, but
            // it is worth another go next install, so the flag stays off.
            return false
        }

        hasSeeded = true
        return true
    }
}
