import Foundation
import SwiftData

/// Works out what an ABC import would do, before it does any of it.
///
/// The old importer had one rule: if a tune with that title already exists,
/// skip it. That is wrong for the commonest case in trad music — you already
/// have The Bunny's Hat, and the file you've been sent is a *different setting*
/// of it. Skipping loses the thing you wanted; adding a second top-level tune
/// clutters the library with something that isn't a separate tune at all. The
/// right answer is a version of what you have, and only you can confirm that.
///
/// So this decides nothing on its own: it proposes, the review screen shows the
/// proposals, and nothing is written until you say so.
public enum ABCImportPlan {

    /// What should happen to one tune found in a file.
    public enum Decision: Equatable {
        /// Nothing in the library resembles it.
        case newTune
        /// The title matches something you already have — add as another
        /// setting of it, rather than a second tune with the same name.
        case version(of: PersistentIdentifier)
        /// Same title AND the same notes. Nothing to gain.
        case duplicate(of: PersistentIdentifier)
        /// Leave it out.
        case skip
    }

    public struct Item: Identifiable {
        public let id = UUID()
        /// Which file it came from — a folder import can hold dozens.
        public let source: String
        public let parsed: ABCParser.ParsedTune
        /// What we propose, and what you've chosen if you changed it.
        public var decision: Decision
        /// The tune it would join, for showing a name in the list.
        public var matchTitle: String?
        /// The set this tune belongs to, where the file was a set.
        public var setName: String?
        /// Where it sat in that set, so the running order can be rebuilt.
        public var setPosition: Int = 0

        public var title: String { parsed.title }
    }

    /// Read the files and work out a proposal for every tune in them.
    ///
    /// Matching is by title, through the same normalising the library search
    /// uses — accents folded, punctuation dropped, a leading "The" ignored — so
    /// "The Bunny's Hat", "Bunny's Hat, The" and "bunnys hat" all find each
    /// other. Being generous here is safe because nothing is written yet.
    public static func build(from sources: [Source], context: ModelContext) -> [Item] {
        let library = (try? context.fetch(FetchDescriptor<Tune>())) ?? []

        // Every tune of that name, not the first one found.
        //
        // Four tunes in this library are called "Bunny's Hat, The", with
        // different notes. Keeping one representative per name meant an exact
        // copy of the second was compared against the first, came out
        // different, and was proposed as a new setting of something you
        // already had verbatim. The notes have to be checked against all of
        // them.
        var byTitle: [String: [Tune]] = [:]
        for tune in library {
            for name in [tune.title] + tune.aliases {
                for variant in TitleMatching.variants(of: name) {
                    byTitle[variant, default: []].append(tune)
                }
            }
        }

        var items: [Item] = []
        for source in sources {
            let name = source.name
            var positionInSet = 0
            for block in ABCParser.splitTunes(source.text) {
                let parsed = ABCParser.parse(block)
                guard !parsed.abc.isEmpty,
                      !parsed.title.isEmpty,
                      parsed.title != "Untitled" else { continue }

                var decision = Decision.newTune
                var matchTitle: String?
                let candidates = TitleMatching.variants(of: parsed.title)
                    .flatMap { byTitle[$0] ?? [] }
                if !candidates.isEmpty {
                    let incoming = normalisedABC(parsed.abc)
                    // Already have these exact notes under this name?
                    if let twin = candidates.first(where: { normalisedABC($0.abc) == incoming }) {
                        matchTitle = twin.title
                        decision = .duplicate(of: twin.persistentModelID)
                    } else {
                        // Join the default of the group where there is one, so
                        // the new setting files under the tune you actually see.
                        let parent = candidates.first(where: { $0.isDefaultVersion })
                            ?? candidates[0]
                        matchTitle = parent.title
                        decision = .version(of: parent.persistentModelID)
                    }
                }
                items.append(Item(source: name, parsed: parsed,
                                  decision: decision, matchTitle: matchTitle,
                                  setName: source.setName,
                                  setPosition: positionInSet))
                positionInSet += 1
            }
        }
        return items
    }

    /// Carry out the decisions. Returns what happened, for the confirmation.
    @discardableResult
    public static func apply(_ items: [Item], context: ModelContext,
                      makeSets: Bool = true) -> FileImports.Summary {
        var summary = FileImports.Summary()
        /// The tune each item ended up as, so a set can be built from them —
        /// including the ones that turned out to be duplicates, because a set
        /// wants the tune you already have, not a second copy of it.
        var landed: [(item: Item, tune: Tune)] = []

        for item in items {
            switch item.decision {
            case .skip:
                summary.tunesSkipped += 1

            case .duplicate(let id):
                summary.tunesSkipped += 1
                if let existing = context.model(for: id) as? Tune {
                    landed.append((item, existing))
                }

            case .newTune:
                let tune = make(from: item.parsed)
                context.insert(tune)
                landed.append((item, tune))
                summary.tunesImported += 1

            case .version(let id):
                guard let existing = context.model(for: id) as? Tune else {
                    let tune = make(from: item.parsed)
                    context.insert(tune)
                    landed.append((item, tune))
                    summary.tunesImported += 1
                    continue
                }
                let addition = make(from: item.parsed)
                // Join the existing tune's version group, keeping whatever is
                // already the default. An import should never quietly change
                // which setting you see when you open a tune.
                // Join the existing tune's group. If it wasn't in one it
                // becomes the first member and stays the default — an import
                // must never quietly change which setting you see.
                let group = existing.groupID ?? UUID()
                existing.groupID = group
                existing.isDefaultVersion = true
                addition.groupID = group
                addition.isDefaultVersion = false
                addition.versionLabel = versionLabel(for: item.parsed, source: item.source)
                context.insert(addition)
                landed.append((item, addition))
                summary.tunesImported += 1
                summary.versionGroups += 1
            }
        }

        if makeSets { summary.setsCreated += buildSets(from: landed, context: context) }
        return summary
    }

    /// Join the tunes that came out of one set back into a set.
    ///
    /// A MusicXML export of a set is one file with the tunes written out in
    /// order. Split into separate tunes, the running order — the thing that
    /// made it a set — is the part that gets lost, and it is not recoverable
    /// afterwards from the tunes themselves. It is recorded here while it is
    /// still known.
    private static func buildSets(from landed: [(item: Item, tune: Tune)],
                                  context: ModelContext) -> Int {
        var byName: [String: [(item: Item, tune: Tune)]] = [:]
        for entry in landed {
            guard let name = entry.item.setName, !name.isEmpty else { continue }
            byName[name, default: []].append(entry)
        }

        var made = 0
        for (name, entries) in byName {
            // One tune is not a set — the others were skipped, or it was never
            // one to begin with.
            guard entries.count > 1 else { continue }
            let existing = (try? context.fetch(FetchDescriptor<TuneSet>()))?
                .first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
            if existing != nil { continue }

            let set = TuneSet(name: name)
            context.insert(set)
            for (position, entry) in entries.sorted(by: { $0.item.setPosition < $1.item.setPosition })
                .enumerated() {
                let slot = SetEntry(position: position, tune: entry.tune)
                slot.tuneSet = set
                context.insert(slot)
            }
            made += 1
        }
        return made
    }

    // MARK: - Bits

    private static func make(from parsed: ABCParser.ParsedTune) -> Tune {
        let tune = Tune(title: parsed.title, type: parsed.type,
                        key: parsed.key, mode: parsed.mode, abc: parsed.abc)
        tune.composer = parsed.composer
        tune.aliases = parsed.aliases
        return tune
    }

    /// Something to tell one setting from another in the versions list. The key
    /// is the most useful single fact when the titles are by definition equal.
    private static func versionLabel(for parsed: ABCParser.ParsedTune, source: String) -> String {
        let key = [parsed.key, parsed.mode].filter { !$0.isEmpty }.joined()
        if !key.isEmpty { return key }
        return (source as NSString).deletingPathExtension
    }

    /// Compare the notes, not the paperwork: headers, whitespace and case all
    /// differ between sources for music that is identical.
    private static func normalisedABC(_ abc: String) -> String {
        abc.components(separatedBy: .newlines)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { return false }
                // Drop header fields (X:, T:, S:, Z: …), keep the music.
                if t.count > 1, t.dropFirst().hasPrefix(":"),
                   let first = t.first, first.isLetter { return false }
                return true
            }
            .joined()
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }


    /// A file's name and its contents, read while we were allowed to.
    ///
    /// Sendable because ImportRouter's scan builds these off the main thread.
    public struct Source: Sendable {
        public let name: String
        public let text: String
        /// Set when the file was a set rather than a single tune — several
        /// tunes written out one after another, as MusicXML exports of a set
        /// are. The tunes go in individually and are joined into a set of this
        /// name, so the running order survives the import.
        public var setName: String? = nil

        public init(name: String, text: String, setName: String? = nil) {
            self.name = name
            self.text = text
            self.setName = setName
        }
    }

    /// Every .abc file in a folder, read there and then.
    ///
    /// The first version returned URLs and read them later. That cannot work:
    /// the security scope belongs to the folder you picked, and files inside it
    /// have no scope of their own. Closing the folder's scope and then opening
    /// the children gave empty strings, no tunes, and a review screen saying it
    /// had found nothing — which looked like the folder not being recognised.
    /// The contents are taken while the door is open.
    public static func abcSources(in folder: URL) -> [Source] {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { ["abc", "txt"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { read($0) }
    }

    /// The same for files picked directly, which DO carry their own scope.
    public static func sources(for urls: [URL]) -> [Source] { urls.compactMap { read($0) } }

    private static func read(_ url: URL) -> Source? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
        return text.isEmpty ? nil : Source(name: url.lastPathComponent, text: text)
    }
}
