import Foundation
import SwiftData

/// Bringing in a folder of files at once — recordings, PDFs of sheet music, or
/// photographs of it.
///
/// All three work the same way, which is the Pi's design and a good one: work
/// out a title for each file, look for a tune of that name, and propose either
/// attaching the file to that tune or creating a new one. You see the whole
/// list before anything happens and can correct any row.
///
/// The value is in not doing it a hundred times by hand. With a thousand tunes
/// in the library, a folder of session recordings named after the tunes lands
/// almost entirely on the right ones.
@MainActor
public enum BulkImport {

    public enum Action: String, CaseIterable, Identifiable {
        case attach, create, skip
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .attach: return "Attach"
            case .create: return "New tune"
            case .skip:   return "Skip"
            }
        }
    }

    /// One file, and what we propose doing with it.
    public struct Candidate: Identifiable {
        public let id = UUID()
        public let url: URL
        public let filename: String
        /// Editable — the proposed title, from the filename or from the
        /// writing on a photograph.
        public var title: String
        public var kind: MediaKind
        /// The tune we think this belongs to, if any.
        public var match: Tune?
        public var action: Action
        /// Set when the file has already been copied into the app's own store.
        ///
        /// Needed for folder imports: the security scope belongs to the folder
        /// you picked, and the files inside it have none of their own. By the
        /// time you have reviewed the list and tapped Import, that scope is
        /// long closed and every read comes back empty — the same mistake that
        /// made the ABC folder import look like it hadn't recognised a folder.
        /// So a folder's files are copied in while the door is open, and commit
        /// uses what is already here.
        public var stored: String? = nil

        public var matchTitle: String? { match?.title }

        public init(url: URL, filename: String, title: String, kind: MediaKind,
                    match: Tune?, action: Action, stored: String? = nil) {
            self.url = url
            self.filename = filename
            self.title = title
            self.kind = kind
            self.match = match
            self.action = action
            self.stored = stored
        }
    }

    /// What each source will accept.
    public static let audioExtensions = ["mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "ogg"]
    public static let documentExtensions = ["pdf"]
    public static let imageExtensions = ["jpg", "jpeg", "png", "heic", "heif", "tiff"]


    /// Everything the app can attach to a tune.
    public static let mediaExtensions =
        audioExtensions + documentExtensions + imageExtensions
        + ["mp4", "mov", "m4v"]

    /// What a folder holds, copied in and matched to tunes by filename.
    ///
    /// Returns the candidates plus the names of any files it had to leave
    /// behind, so the screen can say so rather than quietly dropping them.
    public static func planFolder(_ folder: URL, in context: ModelContext)
        -> (candidates: [Candidate], notation: [String], ignored: [String]) {

        let tunes = (try? context.fetch(FetchDescriptor<Tune>())) ?? []
        let index = TitleMatching.Index(tunes: tunes)

        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return ([], [], []) }

        var candidates: [Candidate] = []
        var notation: [String] = []
        var ignored: [String] = []

        for case let url as URL in walker {
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent
            if ["xml", "musicxml", "mxl"].contains(ext) { notation.append(name); continue }
            if ["abc"].contains(ext) { notation.append(name); continue }
            guard mediaExtensions.contains(ext) else {
                if !ext.isEmpty { ignored.append(name) }
                continue
            }
            // Copy now, while we are still allowed to read it.
            guard let stored = MediaStore.shared.copyIn(from: url) else {
                ignored.append(name); continue
            }
            let title = TitleMatching.title(fromFilename: name)
            let match = title.isEmpty ? nil : index.match(title)
            candidates.append(Candidate(url: url,
                                        filename: name,
                                        title: title,
                                        kind: MediaStore.kind(forExtension: ext),
                                        match: match,
                                        action: match == nil ? .create : .attach,
                                        stored: stored))
        }
        return (candidates.sorted { $0.filename < $1.filename }, notation, ignored)
    }

    /// Work out what to do with each file, without touching anything.
    public static func plan(urls: [URL], titles: [URL: String] = [:], in context: ModelContext) -> [Candidate] {
        let tunes = (try? context.fetch(FetchDescriptor<Tune>())) ?? []
        let index = TitleMatching.Index(tunes: tunes)

        return urls.map { url in
            let filename = url.lastPathComponent
            // A title read off a photograph beats one guessed from the
            // filename, which for a photo is usually "IMG_4032".
            let title = titles[url] ?? TitleMatching.title(fromFilename: filename)
            let ext = url.pathExtension.lowercased()
            let kind = MediaStore.kind(forExtension: ext)
            let match = title.isEmpty ? nil : index.match(title)
            return Candidate(url: url,
                             filename: filename,
                             title: title,
                             kind: kind,
                             match: match,
                             action: match == nil ? .create : .attach)
        }
    }

    public struct Result {
        public var attached = 0
        public var created = 0
        public var skipped = 0
        public var failed = 0

        public var summary: String {
            var parts: [String] = []
            if created > 0 { parts.append("\(created) new \(created == 1 ? "tune" : "tunes")") }
            if attached > 0 { parts.append("\(attached) attached") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            if failed > 0 { parts.append("\(failed) couldn't be read") }
            return parts.isEmpty ? "Nothing to do" : parts.joined(separator: ", ")
        }
    }

    /// Do it. Files are copied into the app's own store, so the originals can
    /// go wherever they like afterwards.
    public static func commit(_ candidates: [Candidate],
                       collectionNamed collectionName: String?,
                       in context: ModelContext) -> Result {
        var result = Result()
        var touched: [Tune] = []

        for candidate in candidates {
            guard candidate.action != .skip else { result.skipped += 1; continue }

            // A folder import has already brought the file in — see Candidate.
            // Files picked individually still carry their own security scope,
            // so they are copied here.
            let stored: String
            if let already = candidate.stored {
                stored = already
            } else {
                let scoped = candidate.url.startAccessingSecurityScopedResource()
                defer { if scoped { candidate.url.stopAccessingSecurityScopedResource() } }
                guard let copied = MediaStore.shared.copyIn(from: candidate.url) else {
                    result.failed += 1
                    continue
                }
                stored = copied
            }

            let tune: Tune
            switch candidate.action {
            case .attach:
                guard let matched = candidate.match else {
                    MediaStore.shared.delete(filename: stored)
                    result.failed += 1
                    continue
                }
                tune = matched
                result.attached += 1
            case .create:
                tune = Tune(title: candidate.title.isEmpty ? "Untitled" : candidate.title,
                            abc: "")
                context.insert(tune)
                result.created += 1
            case .skip:
                continue
            }

            let media = MediaItem(kind: candidate.kind,
                                  title: candidate.title,
                                  filename: stored)
            media.notes = "Imported from \(candidate.filename)"
            media.tune = tune
            context.insert(media)
            touched.append(tune)
        }

        // A folder brought in together is usually a thing — a session, a book,
        // a workshop — so offer to keep it as one.
        if let name = collectionName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, !touched.isEmpty {
            let collection = existingCollection(named: name, in: context)
                ?? {
                    let made = TuneCollection(name: name)
                    context.insert(made)
                    return made
                }()
            for tune in touched where !(collection.tunes ?? []).contains(where: {
                $0.persistentModelID == tune.persistentModelID
            }) {
                collection.tunes = (collection.tunes ?? []) + [tune]
            }
        }

        try? context.save()
        return result
    }

    private static func existingCollection(named name: String,
                                           in context: ModelContext) -> TuneCollection? {
        let all = (try? context.fetch(FetchDescriptor<TuneCollection>())) ?? []
        return all.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }
}
