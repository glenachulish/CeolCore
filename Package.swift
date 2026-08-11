// swift-tools-version: 5.9
//
// Deliberately 5.9 and not 6.0.
//
// The Xcode 26 package template writes tools-version 6.0, which turns on the
// Swift 6 language mode and strict concurrency checking. Both apps are
// SWIFT_VERSION = 5.0, and the code moving in here has several things Swift 6
// rejects on sight: MediaStore.shared is a non-Sendable singleton, and
// ImportRouter.Scan / ABCImportPlan.Source cross to a background thread.
//
// None of that is wrong today, and none of it is what this refactor is about.
// Migrating to Swift 6 is its own job, worth doing once the round-trip test
// below is in place to catch what it breaks.

import PackageDescription

let package = Package(
    name: "CeolCore",

    // SwiftData's floor is iOS 17 / macOS 14, which is also what the brief
    // asks for and what the iOS app already targets.
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],

    products: [
        .library(name: "CeolCore", targets: ["CeolCore"]),
    ],

    targets: [
        .target(
            name: "CeolCore",
            resources: [
                // .copy, NOT .process — and this is not a style preference.
                //
                // abc.html and set.html load their scripts with relative tags,
                // <script src="abcjs-basic-min.js">, and the web view is given
                // read access to the page's own directory. .copy preserves the
                // folder exactly, so the scripts sit beside the page and
                // resolve. .process is free to flatten or rename, and then the
                // page loads, the scripts do not, abcjs is undefined, and you
                // get an empty sheet of music with nothing in the console.
                //
                // It also keeps Web/soundfont/ as a directory, which is what
                // CeolResources.soundfont(folder:note:) looks in.
                //
                // The folder is called Web and NOT Resources, which matters and
                // is not obvious. .copy puts the directory at the top level of
                // the built resource bundle, beside Info.plist. On macOS that
                // is harmless — a macOS bundle is a deep one and everything
                // lands inside Contents/. An iOS bundle is shallow, and a
                // top-level directory named Resources is exactly how codesign
                // recognises an old-style deep bundle. It therefore reads the
                // bundle as a malformed one and refuses to sign it:
                //
                //     CeolCore_CeolCore.bundle: bundle format unrecognized,
                //     invalid, or unsuitable
                //
                // which stops the iOS build dead, long after every line of
                // Swift has compiled. The Mac build never sees it. Any name
                // that is not one of the bundle-reserved ones — Resources,
                // Contents, Frameworks, PlugIns, Versions — will do.
                .copy("Web"),
            ]
        ),
        .testTarget(
            name: "CeolCoreTests",
            dependencies: ["CeolCore"]
        ),
    ]
)
