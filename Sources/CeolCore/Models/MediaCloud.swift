import Foundation

/// The media folder, moved into iCloud Drive.
///
/// The tune database syncs through CloudKit, which SwiftData does for us. The
/// recordings, photographs and PDFs do not: they are ordinary files with the
/// database holding only their names, and a name is no use on a device that
/// hasn't got the file. Without this, a tune shows its recording on the phone
/// and nothing on the iPad — which is exactly the half-synced library that
/// makes people stop trusting sync altogether.
///
/// `MediaStore.setRoot(_:)` was written for this. All that was missing was
/// somewhere to point it.
///
/// ## Why `Documents/`
///
/// The ubiquity container has a `Documents` subfolder with a particular
/// meaning: what is inside it appears in the Files app and in iCloud Drive on
/// the Mac. Anything outside it syncs but stays invisible. Recordings the
/// reader made should be theirs to see, so `Documents/Media` it is —
/// `MediaStore` appends the `Media` part itself, so the root handed to it is
/// the `Documents` folder.
///
/// ## Two traps, both of which bite silently
///
/// `url(forUbiquityContainerIdentifier:)` **blocks** — first call on a fresh
/// install can take seconds while the daemon sets the container up — so every
/// path into it here goes through a detached task and nothing calls it on the
/// main thread.
///
/// It also returns **nil** rather than throwing when the iCloud entitlement is
/// missing or the reader has iCloud switched off. Every failure below
/// therefore leaves `MediaStore` exactly as it was, on the device's own
/// Documents folder, and the app carries on working. Not syncing is a
/// disappointment; losing the files is not recoverable.
public enum MediaCloud {

    /// What happened, in terms a Settings screen can say out loud.
    public enum Outcome: Sendable, Equatable {
        /// Still on this device only, and why.
        case unavailable(String)
        /// The media folder is in iCloud Drive. `moved` is how many files this
        /// launch put there; `kept` is how many were left where they were
        /// because something of that name was already in iCloud.
        case ready(moved: Int, kept: Int)

        public var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        public var summary: String {
            switch self {
            case .unavailable(let why):
                return why
            case .ready(let moved, let kept):
                if moved == 0 && kept == 0 { return "Recordings are in iCloud Drive." }
                var parts = ["Recordings are in iCloud Drive"]
                if moved > 0 { parts.append("\(moved) moved there") }
                if kept > 0 { parts.append("\(kept) already there") }
                return parts.joined(separator: " — ") + "."
            }
        }
    }

    // MARK: - Finding the folder

    /// The app's iCloud Drive `Documents` folder, or nil if there isn't one.
    ///
    /// **Blocking. Never call this on the main thread.**
    public static func documentsRoot() -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: documents,
                                                 withIntermediateDirectories: true)
        return documents
    }

    // MARK: - Moving in

    /// Point `MediaStore` at iCloud Drive, bringing this device's existing
    /// files with it.
    ///
    /// Safe to call on every launch. Once the move has happened the folder scan
    /// finds nothing to do and the whole thing costs one directory listing.
    ///
    /// Call it only when the reader has sync switched on. Moving somebody's
    /// recordings into iCloud because the app felt like it would be a decision
    /// taken on their behalf about their storage and their bill.
    @discardableResult
    public static func adopt() async -> Outcome {
        let outcome = await Task.detached(priority: .utility) { () -> Outcome in
            guard FileManager.default.ubiquityIdentityToken != nil else {
                return .unavailable("Not signed in to iCloud on this device.")
            }
            guard let documents = documentsRoot() else {
                return .unavailable("iCloud Drive isn't available to this app.")
            }

            // Read the current folder BEFORE the root moves — this is the
            // folder the files are in now, and after `setRoot` it is not.
            let source = MediaStore.shared.folder
            let destination = documents.appendingPathComponent("Media", isDirectory: true)
            try? FileManager.default.createDirectory(at: destination,
                                                     withIntermediateDirectories: true)

            var moved = 0
            var kept = 0

            if source.standardizedFileURL != destination.standardizedFileURL,
               let names = try? FileManager.default.contentsOfDirectory(atPath: source.path) {
                for name in names where !name.hasPrefix(".") {
                    let from = source.appendingPathComponent(name)
                    let to = destination.appendingPathComponent(name)

                    // Something of that name is already in iCloud. Media files
                    // are named with a UUID, so the same name is the same file
                    // — put there by another device that got here first. Leave
                    // the local copy alone rather than delete it: a duplicate
                    // costs disk, and deleting the wrong file costs a
                    // recording.
                    if FileManager.default.fileExists(atPath: to.path) {
                        kept += 1
                        continue
                    }

                    // `setUbiquitous` rather than `moveItem`, because this is
                    // the API that means "this file now belongs to iCloud" —
                    // it registers the item with the daemon and removes the
                    // local original as one operation. A plain move into the
                    // container usually works and occasionally leaves a file
                    // that never uploads.
                    do {
                        try FileManager.default.setUbiquitous(true, itemAt: from,
                                                              destinationURL: to)
                        moved += 1
                    } catch {
                        kept += 1
                    }
                }
            }

            MediaStore.shared.setRoot(documents)
            return .ready(moved: moved, kept: kept)
        }.value

        // Left where Settings can read it.
        //
        // A sync that quietly does nothing is the worst kind. On 2 September
        // the files moved correctly and the iCloud Drive folder stayed
        // invisible — the Info.plist was missing
        // `NSUbiquitousContainerIsDocumentScopePublic` — and from inside the
        // app "moved but hidden" and "never ran" looked exactly the same. They
        // should never look the same again.
        UserDefaults.standard.set(outcome.summary, forKey: lastOutcomeKey)
        return outcome
    }

    /// What `adopt()` last did, for the Settings screen. Nil before it has run.
    public static var lastOutcome: String? {
        UserDefaults.standard.string(forKey: lastOutcomeKey)
    }

    private static let lastOutcomeKey = "ceol.media.iCloudOutcome"

    // MARK: - Getting a file back down

    /// Is this file actually on this device, as opposed to merely known about?
    ///
    /// A file in iCloud that has not been downloaded is a *placeholder*: it has
    /// a name, a size and a modification date, and no bytes. Handing one to
    /// AVPlayer gives you a recording that plays silence — no error, no
    /// warning, just nothing — which is the single most confusing thing that
    /// can happen to somebody whose sync is working perfectly well.
    public static func isDownloaded(_ filename: String) -> Bool {
        guard !filename.isEmpty else { return false }
        let url = MediaStore.shared.url(for: filename)
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard let status = values?.ubiquitousItemDownloadingStatus else {
            // Not an iCloud item at all: the ordinary local case, where being
            // on disk is the whole question.
            return FileManager.default.fileExists(atPath: url.path)
        }
        return status != .notDownloaded
    }

    /// Ask iCloud for a file and wait a while for it.
    ///
    /// Returns true when the bytes are there. Returns false on a timeout, which
    /// is a real outcome rather than an error — a recording being fetched over
    /// a slow connection is a thing to say, not a thing to crash on.
    @discardableResult
    public static func ensureDownloaded(_ filename: String,
                                        timeout: TimeInterval = 25) async -> Bool {
        guard !filename.isEmpty else { return false }
        if isDownloaded(filename) { return true }

        let url = MediaStore.shared.url(for: filename)
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if isDownloaded(filename) { return true }
        }
        return false
    }

    /// How much of the library is still waiting to come down, for a Settings
    /// line that answers "why can't I hear anything yet".
    public static func awaiting(_ filenames: [String]) -> Int {
        filenames.filter { !$0.isEmpty && !isDownloaded($0) }.count
    }
}
