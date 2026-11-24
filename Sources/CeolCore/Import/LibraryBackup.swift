import Foundation
import SwiftData

/// FONN-BACKUP-1: a whole-library backup, recordings included.
///
/// `LibraryExport` writes the library as one `.ceol.json`, which is text: the
/// tunes, sets, collections and version groups. The recordings, PDFs and photos
/// attached to tunes are files, so they were never in it, and an "export" that
/// silently leaves out every recording is not a backup.
///
/// This writes the folder that `FileImports.importFolder` already reads, on
/// both platforms:
///
///     Fonn backup 2026-11-22 1045/
///         library.ceol.json
///         media/
///             <each attached file, under its stored name>
///
/// So restoring needs no new code: Add to Library ▸ the folder (Mac), or
/// Import ▸ Folder (iPhone). The importer matches each file to its tune by the
/// `media` entries in the JSON, which name the same files.
///
/// Attached files live in iCloud Drive on both apps and may not be on this
/// device (the Mac's "Keep recordings on this Mac" is off by default). A
/// coordinated read downloads such a file before handing it over, so a backup
/// on a Mac that has never played a recording still gets it. Files that can't
/// be had (deleted, or offline and not downloaded) are counted, not fatal.
public enum LibraryBackup {

    public static let jsonName = "library.ceol.json"
    public static let mediaFolderName = "media"

    public struct Summary: Sendable {
        public var folder: URL
        public var tunes = 0
        public var sets = 0
        public var collections = 0
        public var filesCopied = 0
        /// Named by a tune but not on disk and not in iCloud.
        public var filesMissing = 0
        /// There, but the copy failed (disk full, permissions).
        public var filesFailed = 0
        public var bytes: Int64 = 0

        /// One sentence for an alert or a footer.
        public var description: String {
            var s = "\(tunes) tunes, \(sets) sets, \(collections) collections"
            s += " and \(filesCopied) attached files (\(MediaStore.formatSize(bytes)))"
            s += " in \"\(folder.lastPathComponent)\"."
            if filesMissing > 0 {
                s += " \(filesMissing) attached file\(filesMissing == 1 ? " was" : "s were") missing and left out."
            }
            if filesFailed > 0 {
                s += " \(filesFailed) file\(filesFailed == 1 ? "" : "s") couldn't be copied."
            }
            return s
        }
    }

    /// Writes a new backup folder inside `parent` and returns what went in.
    ///
    /// The JSON is made on the main actor, where the models live; the copying
    /// runs off it, from a plain list of names and paths, so the window stays
    /// responsive through a few hundred recordings.
    @MainActor
    public static func write(into parent: URL, context: ModelContext,
                             date: Date = .now) async throws -> Summary {
        let data = try LibraryExport.libraryJSON(context: context)

        let tunes = (try? context.fetch(FetchDescriptor<Tune>())) ?? []
        // The `media` entries first; then files a tune's notes name as
        // /api/uploads/NAME, which the folder importer also reads, when the
        // app actually holds them.
        var names = Set<String>()
        for tune in tunes {
            for item in tune.media ?? [] where !item.filename.isEmpty {
                names.insert(item.filename)
            }
            for name in LinkedText.uploadedFilenames(in: tune.notes)
            where MediaStore.shared.exists(name) {
                names.insert(name)
            }
        }
        let sources = names.sorted().map { ($0, MediaStore.shared.url(for: $0)) }

        let folder = freshFolder(in: parent, date: date)
        let mediaDir = folder.appendingPathComponent(mediaFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(jsonName), options: .atomic)

        var summary = Summary(folder: folder)
        summary.tunes = tunes.filter(\.isDefaultVersion).count
        summary.sets = (try? context.fetchCount(FetchDescriptor<TuneSet>())) ?? 0
        summary.collections = (try? context.fetchCount(FetchDescriptor<TuneCollection>())) ?? 0

        let copied = await Task.detached(priority: .userInitiated) {
            copy(sources, into: mediaDir)
        }.value
        summary.filesCopied = copied.copied
        summary.filesMissing = copied.missing
        summary.filesFailed = copied.failed
        summary.bytes = copied.bytes
        return summary
    }

    /// "Fonn backup 2026-11-22 1045", or "… 1045 (2)" if that is taken, so a
    /// second backup in the same minute never lands inside the first.
    static func freshFolder(in parent: URL, date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let base = "Fonn backup " + formatter.string(from: date)
        var url = parent.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(base) (\(n))", isDirectory: true)
            n += 1
        }
        return url
    }

    /// Copies each file into `dir` under its own name.
    ///
    /// Through NSFileCoordinator rather than a bare copy: for a file kept in
    /// iCloud Drive but not downloaded, a coordinated read fetches it first.
    /// A bare `copyItem` would find only the placeholder and fail.
    static func copy(_ sources: [(String, URL)], into dir: URL)
        -> (copied: Int, missing: Int, failed: Int, bytes: Int64) {
        let fm = FileManager()
        var copied = 0, missing = 0, failed = 0
        var bytes: Int64 = 0
        for (name, source) in sources {
            let destination = dir.appendingPathComponent(name)
            let inCloud = (try? source.resourceValues(forKeys: [.isUbiquitousItemKey]))?
                .isUbiquitousItem == true
            if !inCloud && !fm.fileExists(atPath: source.path) {
                missing += 1
                continue
            }
            if inCloud { try? fm.startDownloadingUbiquitousItem(at: source) }

            var ok = false
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges],
                                           error: &coordinationError) { readable in
                do {
                    if fm.fileExists(atPath: destination.path) {
                        try fm.removeItem(at: destination)
                    }
                    try fm.copyItem(at: readable, to: destination)
                    ok = true
                } catch {
                    ok = false
                }
            }
            if ok {
                copied += 1
                let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?
                    .int64Value ?? 0
                bytes += size
            } else if fm.fileExists(atPath: source.path) {
                failed += 1
            } else {
                missing += 1
            }
        }
        return (copied, missing, failed, bytes)
    }
}
