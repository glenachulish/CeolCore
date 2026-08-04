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
                // It also keeps Resources/soundfont/ as a directory, which is
                // what CeolResources.soundfont(folder:note:) looks in.
                .copy("Resources"),
            ]
        ),
        .testTarget(
            name: "CeolCoreTests",
            dependencies: ["CeolCore"]
        ),
    ]
)
