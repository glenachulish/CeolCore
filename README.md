# CeolCore

The shared foundation of **Fonn** — a library for traditional tunes. One copy
of the models, the ABC tooling and the importers, used by the iPhone app and
the Mac app so the two can never drift apart.

Consumed as a **local Swift package** by:

| | |
|---|---|
| `~/Ceol/ios` | Fonn for iOS, and the CeolShare extension |
| `~/Ceol/mac` | Fonn for macOS |

## Why a package and not a folder

Both apps need the same SwiftData models, and eventually the same CloudKit
schema — which means byte-identical model definitions. Two copies kept in step
by hand is two copies that drift. This is the single copy.

## What's in it

| | |
|---|---|
| `Models` | `Tune`, `TuneSet`, `SetEntry`, `TuneCollection`, `MediaItem` |
| `ABC` | `ABCParser`, `ABCTools`, `SetABCBuilder`, `TitleMatching`, `CircleOfFifths` |
| `Import` | `MusicXMLToABC`, `ABCImportPlan`, `ImportRouter`, `TheSessionAPI`, `FileImports` / `LibraryExport` (the `.ceol.json` format) |
| `Resources` | abcjs, the sheet-music pages, the bundled soundfonts |

The views stay in the apps. Anything here must build on both platforms, so
nothing UIKit-shaped comes in.

## Things that will bite

**`Resources` is `.copy`, not `.process`.** The HTML loads its scripts with
relative tags and the web view is given read access to the page's own
directory. `.process` may flatten or rename, and then the page loads, abcjs
doesn't, and you get an empty sheet of music with nothing in the console.

**Tools version is 5.9 on purpose.** 6.0 turns on the Swift 6 language mode and
strict concurrency; both apps are still Swift 5, and several things here —
`MediaStore.shared`, `ImportRouter.Scan` crossing threads — are rejected on
sight. Migrating is its own job.

**Member Import Visibility catches *members*, not types.** Both apps build with
`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`, and the rule is
narrower than it first looks: a top-level declaration — `ObservableObject`,
`@Published`, `@StateObject` — is found through any transitive import and needs
nothing spelled out. A *member* is not. These have each cost a build:

| what was used | why it failed | the import needed |
|---|---|---|
| `tune.persistentModelID` | property on `PersistentModel` | `SwiftData` |
| `@StateObject var x = …` | its `init(wrappedValue:)` | `Combine` |
| `UTType.json` | static member | `UniformTypeIdentifiers` |

So the check worth running on a new file is not "does it mention `@Published`"
— that is a false positive, as several dozen iOS files prove by compiling. It
is "does it call a *member* of a type whose module is not imported here".

**A blank line ends a tune in ABC.** Inserting a line break where one already
exists silently truncates the music. See `ceolApplyBreaks` in `abc.html`.

**SF Symbol names fail at runtime, not at build.** A wrong name draws nothing.

**Long SwiftUI bodies defeat the type-checker**, and the error lands on
whichever line happens to be last — not on the cause. Split view bodies *and*
modifier chains.

## Testing

`tools/abc-harness` runs the real library export through abcjs under jsdom.
Several bugs in the engraving were only ever found that way, and several
confident theories were wrong until tested. Use it before changing anything
about how music is laid out.
