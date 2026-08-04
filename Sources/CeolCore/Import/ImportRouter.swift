import Foundation
import SwiftData

/// Works out what you picked, so you don't have to.
///
/// The Add Tunes screen used to offer ten buttons organised by file format —
/// ABC file, folder of ABC files, Ceòl file, Ceòl folder, Recordings, PDFs,
/// Photos, a whole folder. To choose correctly you had to know what a
/// `.ceol.json` was and which of four folder options applied to yours; pick
/// wrong and the app refused, which reads as a dead button.
///
/// Format is the app's problem, not yours. This looks at what is actually in
/// what you picked and routes it. One button, no wrong answers.
///
/// It happens in two halves. `scan` reads the disk and runs off the main
/// thread; `classify` matches what it found against the library and runs on the
/// main actor, where SwiftData lives. They were one method, called straight
/// from the picker's callback on the main thread, and a folder import looked
/// like the app had hung: enumerating a folder is instant, but copying a
/// hundred recordings is not, and copying one that lives in iCloud and hasn't
/// been downloaded blocks until it arrives — forever, if you're offline.
public enum ImportRouter {

    public enum Outcome {
        /// A whole Ceòl library, exported from the web app or another phone.
        case ceolLibrary(URL, hasMedia: Bool)
        /// Notation, to go through the review screen.
        case notation([ABCImportPlan.Source])
        /// Recordings, photos, PDFs and video, to be matched to tunes.
        case media(candidates: [BulkImport.Candidate], skipped: [String])
        /// Both kinds in one go — notation first, then the media.
        case both(notation: [ABCImportPlan.Source], media: [BulkImport.Candidate])
        /// Nothing usable, and why.
        case nothing(String)
    }

    private static let notationExtensions = ["abc", "txt"]

    /// The same list as BulkImport's, repeated here because the scan runs off
    /// the main thread and BulkImport is @MainActor.
    private static let mediaExtensions = [
        "mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "ogg",
        "pdf",
        "jpg", "jpeg", "png", "heic", "heif", "tiff",
        "mp4", "mov", "m4v",
    ]

    // MARK: - What a scan found

    /// Nothing from SwiftData in here, so it can cross to a background thread.
    public struct Scan: Sendable {
        var ceolFile: URL?
        var ceolFolder: URL?
        var notation: [ABCImportPlan.Source] = []
        var media: [Scanned] = []
        var unusable: [String] = []
        /// Asked for from iCloud and never turned up.
        var stranded: [String] = []
    }

    public struct Scanned: Sendable {
        let url: URL
        let filename: String
        let ext: String
        /// Already copied into the app's own store — see BulkImport.Candidate.
        let stored: String
    }

    // MARK: - Reading the disk

    /// Read everything that was picked. Slow, so never on the main thread.
    ///
    /// `progress` is called from a background thread; marshal it yourself.
    public static func scan(_ picked: [URL],
                     progress: @escaping @Sendable (Int, Int) -> Void) async -> Scan {
        await Task.detached(priority: .userInitiated) { () -> Scan in
            var scan = Scan()

            for url in picked {
                // One scope per thing picked, held across everything read from
                // it. Files inside a picked folder have no scope of their own —
                // the lesson from the folder import that silently read nothing.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory ?? false
                let files = isFolder ? Self.contents(of: url) : [url]

                // A Ceòl export outranks everything: it IS the library, and
                // FileImports will bring its media across itself. Spotted
                // before anything else is read, otherwise every recording in
                // the folder gets copied into the store twice — once here and
                // once by the import — and the first copy is orphaned.
                if let export = files.first(where: {
                    $0.lastPathComponent.lowercased().hasSuffix(".ceol.json")
                }) {
                    if isFolder { scan.ceolFolder = url } else { scan.ceolFile = export }
                    continue
                }

                let total = files.count
                for (position, file) in files.enumerated() {
                    progress(position + 1, total)
                    switch await Self.inspect(file) {
                    case .notation(let source):
                        scan.notation.append(source)
                    case .media(let item):
                        scan.media.append(item)
                    case .unusable(let name):
                        scan.unusable.append(name)
                    case .stranded(let name):
                        scan.stranded.append(name)
                    case .ignore:
                        break
                    }
                }
            }
            return scan
        }.value
    }

    private enum Found {
        case notation(ABCImportPlan.Source)
        case media(Scanned)
        case unusable(String)
        case stranded(String)
        case ignore
    }

    private static func inspect(_ file: URL) async -> Found {
        let name = file.lastPathComponent
        let ext = file.pathExtension.lowercased()

        if notationExtensions.contains(ext) {
            guard await materialise(file) else { return .stranded(name) }
            guard let source = readText(file) else { return .ignore }
            return .notation(source)
        }
        if MusicXMLToABC.fileExtensions.contains(ext) {
            guard await materialise(file) else { return .stranded(name) }
            guard let data = try? Data(contentsOf: file),
                  let source = MusicXMLToABC.source(from: data, filename: name) else {
                return .unusable(name)
            }
            return .notation(source)
        }
        if mediaExtensions.contains(ext) {
            guard await materialise(file) else { return .stranded(name) }
            // Copy in now, while we are allowed to read it.
            guard let stored = MediaStore.shared.copyIn(from: file) else {
                return .unusable(name)
            }
            return .media(Scanned(url: file, filename: name, ext: ext, stored: stored))
        }
        return ext.isEmpty ? .ignore : .unusable(name)
    }

    /// Make sure a file is really on the device before touching it.
    ///
    /// A folder in iCloud Drive hands out real-looking URLs for files whose
    /// contents are still in the cloud. Reading or copying one triggers the
    /// download and blocks until it finishes, with no timeout — which on the
    /// main thread is indistinguishable from a hang. Ask for it, wait with a
    /// limit, and say so when it doesn't arrive.
    ///
    /// Only iCloud advertises itself this way. Dropbox and Google Drive come
    /// through File Provider extensions that don't set these keys, so their
    /// files still download on demand inside the copy — which is why the whole
    /// scan runs off the main thread rather than relying on this.
    private static func materialise(_ url: URL, timeout: TimeInterval = 45) async -> Bool {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey,
                                         .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else { return true }
        if values.ubiquitousItemDownloadingStatus == .current { return true }

        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus
            if status == .current { return true }
        }
        return false
    }

    /// Everything in a folder, with iCloud's placeholders resolved back to the
    /// names they stand for.
    ///
    /// A file that hasn't been downloaded can appear as a hidden
    /// `.Cooley's.mp3.icloud` stub. `.skipsHiddenFiles` dropped those without a
    /// word, so a folder straight out of iCloud came back half empty and the
    /// missing tunes looked like a matching failure.
    private static func contents(of folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []) else { return [] }

        var files: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let real = String(name.dropFirst().dropLast(".icloud".count))
                files.append(url.deletingLastPathComponent().appendingPathComponent(real))
                continue
            }
            if name == "__MACOSX" { continue }
            if name.hasPrefix(".") { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            if isDirectory { continue }
            files.append(url)
        }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Matching it to the library

    /// Turn a scan into a proposal. Main actor: it touches SwiftData.
    public static func classify(_ scan: Scan, in context: ModelContext) -> Outcome {
        if let folder = scan.ceolFolder { return .ceolLibrary(folder, hasMedia: true) }
        if let file = scan.ceolFile { return .ceolLibrary(file, hasMedia: false) }

        let tunes = (try? context.fetch(FetchDescriptor<Tune>())) ?? []
        let index = TitleMatching.Index(tunes: tunes)

        let media: [BulkImport.Candidate] = scan.media.map { found in
            let title = TitleMatching.title(fromFilename: found.filename)
            let match = title.isEmpty ? nil : index.match(title)
            return BulkImport.Candidate(url: found.url,
                                        filename: found.filename,
                                        title: title,
                                        kind: MediaStore.kind(forExtension: found.ext),
                                        match: match,
                                        action: match == nil ? .create : .attach,
                                        stored: found.stored)
        }

        let leftBehind = scan.stranded.map { "\($0) — still in iCloud" } + scan.unusable

        switch (scan.notation.isEmpty, media.isEmpty) {
        case (false, false): return .both(notation: scan.notation, media: media)
        case (false, true):  return .notation(scan.notation)
        case (true, false):  return .media(candidates: media, skipped: leftBehind)
        case (true, true):   return .nothing(explainNothing(scan))
        }
    }

    /// Match again, after notation has been imported.
    ///
    /// A folder often holds a tune's notation and a recording of it together.
    /// The recording is matched before the tune exists, so it comes back
    /// unmatched and would become a second, empty tune of the same name. Run
    /// after the notation lands, this finds the tune that now exists.
    public static func rematch(_ candidates: [BulkImport.Candidate],
                        in context: ModelContext) -> [BulkImport.Candidate] {
        let tunes = (try? context.fetch(FetchDescriptor<Tune>())) ?? []
        let index = TitleMatching.Index(tunes: tunes)
        return candidates.map { candidate in
            guard candidate.match == nil, !candidate.title.isEmpty,
                  let found = index.match(candidate.title) else { return candidate }
            var updated = candidate
            updated.match = found
            updated.action = .attach
            return updated
        }
    }

    private static func explainNothing(_ scan: Scan) -> String {
        if !scan.stranded.isEmpty {
            let count = scan.stranded.count
            return """
                \(count) file\(count == 1 ? "" : "s") in there \(count == 1 ? "is" : "are") still in iCloud and didn't download.

                Open the folder in the Files app, wait for the cloud arrows to clear, and try again.
                """
        }
        if !scan.unusable.isEmpty {
            return """
                Nothing in there that Ceòl can use.

                It takes ABC notation (.abc), MusicXML (.xml, .musicxml, .mxl), recordings, photos, PDFs, video, and Ceòl exports (.ceol.json).
                """
        }
        return "That folder is empty."
    }

    private static func readText(_ url: URL) -> ABCImportPlan.Source? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
        // A .txt that isn't ABC shouldn't masquerade as notation.
        guard text.contains("K:") || text.contains("X:") else { return nil }
        return ABCImportPlan.Source(name: url.lastPathComponent, text: text)
    }
}
