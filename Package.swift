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
            name: "CeolCore"

            // The abcjs pages and library arrive here at step 4 of the move,
            // once the six Bundle.main.url(forResource:) call sites in the iOS
            // app have been changed over in the same pass. Until then this
            // stays commented out — an empty Resources folder is a build error,
            // and a half-done move is a blank sheet-music view with nothing in
            // the console.
            //
            // When it goes in it must be .copy, NOT .process:
            // abc.html and set.html load their scripts with a relative
            // <script src="abcjs-basic-min.js">, and loadFileURL(_:
            // allowingReadAccessTo:) grants the containing directory.
            // .process may rearrange that layout, and the scripts then
            // silently stop resolving.
            //
            // resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "CeolCoreTests",
            dependencies: ["CeolCore"]
        ),
    ]
)
