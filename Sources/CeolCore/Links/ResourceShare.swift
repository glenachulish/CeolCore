import Foundation
import SwiftData
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

// FONN-RESOURCES-1
/// Sending links to someone else, and taking in what they send.
///
/// A copy, not a live share, for the reason `LibraryExport.shareFile` gives:
/// SwiftData's CloudKit store can't share records between iCloud accounts.
/// The file is a `.fonn` like a shared tune — same declared type, so tapping
/// it in Messages opens Fonn — with `"type": "links"` inside:
///
///     { "ceol": 1, "type": "links", "name": "Flute technique",
///       "folders": [ { "name": …, "description": …, "links": [ … ] } ],
///       "links": [ … ] }          // links in no folder
///
/// A link: `url`, and when set `title`, `notes`, `kind`, and `tunes` (titles,
/// matched to the other person's tunes by name). The same shape goes into a
/// full library backup under `resources`, so a backup keeps Resources too.
public enum ResourceShare {

    // MARK: - Writing

    /// The JSON for these folders (each with all its links) and these loose
    /// links.
    public static func payload(folders: [LinkFolder], loose: [SavedLink] = [],
                               name: String) -> [String: Any] {
        var out: [String: Any] = [
            "ceol": 1,
            "type": "links",
            "name": name,
            "exported_at": ISO8601DateFormatter().string(from: .now).prefix(10).description,
            "folders": folders.map(folderDict),
        ]
        if !loose.isEmpty { out["links"] = loose.map(linkDict) }
        return out
    }

    static func folderDict(_ folder: LinkFolder) -> [String: Any] {
        var dict: [String: Any] = ["name": folder.name, "links": folder.sortedLinks.map(linkDict)]
        if !folder.about.isEmpty { dict["description"] = folder.about }
        return dict
    }

    static func linkDict(_ link: SavedLink) -> [String: Any] {
        var dict: [String: Any] = ["url": link.urlString, "kind": link.kindRaw]
        if !link.title.isEmpty { dict["title"] = link.title }
        if !link.notes.isEmpty { dict["notes"] = link.notes }
        let tunes = link.sortedTunes.map(\.title).filter { !$0.isEmpty }
        if !tunes.isEmpty { dict["tunes"] = tunes }
        return dict
    }

    /// The `.fonn` file's bytes and name, for the share sheet.
    public static func file(folders: [LinkFolder], loose: [SavedLink] = [],
                            name: String) -> LinksFile {
        let json = payload(folders: folders, loose: loose, name: name)
        let data = (try? JSONSerialization.data(withJSONObject: json,
                                                options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return LinksFile(data: data, name: name)
    }

    /// The same links as plain text, for someone without Fonn: a heading per
    /// folder, then one link a line.
    public static func text(folders: [LinkFolder], loose: [SavedLink] = [], name: String) -> String {
        var lines: [String] = [name, ""]
        func add(_ links: [SavedLink]) {
            for link in links {
                lines.append("• \(link.displayTitle)")
                lines.append("  \(link.urlString)")
                if !link.notes.isEmpty { lines.append("  \(link.notes)") }
            }
        }
        for folder in folders {
            if folders.count > 1 || !loose.isEmpty { lines.append(folder.name.uppercased()) }
            add(folder.sortedLinks)
            lines.append("")
        }
        add(loose)
        lines.append("")
        lines.append("Sent from Fonn")
        return lines.joined(separator: "\n")
    }

    // MARK: - Reading

    /// Take in a shared links file, or the `resources` part of a backup.
    /// Folders are matched by name and links by address, so taking the same
    /// file twice changes nothing, and a link you already have just gains the
    /// folder and tunes.
    public static func take(_ json: [String: Any], into context: ModelContext,
                            summary: inout FileImports.Summary) {
        var folders = (try? context.fetch(FetchDescriptor<LinkFolder>())) ?? []
        let tunes = ((try? context.fetch(FetchDescriptor<Tune>())) ?? []).filter(\.isDefaultVersion)
        var tuneByTitle: [String: Tune] = [:]
        for tune in tunes {
            let key = tune.title.lowercased().trimmingCharacters(in: .whitespaces)
            if tuneByTitle[key] == nil { tuneByTitle[key] = tune }
        }

        func takeLink(_ dict: [String: Any], folder: LinkFolder?) {
            guard let url = ResourceLinks.url(from: dict["url"] as? String ?? "") else { return }
            let before = ResourceLinks.existing(url.absoluteString, in: context)
            let (link, isNew) = ResourceLinks.save(url, title: dict["title"] as? String ?? "",
                                                   folder: folder, in: context)
            if isNew {
                summary.linksAdded += 1
                if let raw = dict["kind"] as? String, let kind = LinkKind(rawValue: raw) { link.kind = kind }
                link.notes = dict["notes"] as? String ?? ""
            } else if before != nil {
                summary.linksAlreadyThere += 1
                if link.notes.isEmpty { link.notes = dict["notes"] as? String ?? "" }
            }
            for title in (dict["tunes"] as? [String]) ?? [] {
                let key = title.lowercased().trimmingCharacters(in: .whitespaces)
                guard let tune = tuneByTitle[key],
                      !(link.tunes ?? []).contains(where: { $0 === tune }) else { continue }
                link.tunes = (link.tunes ?? []) + [tune]
            }
        }

        for fd in (json["folders"] as? [[String: Any]]) ?? [] {
            let name = (fd["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let folder: LinkFolder
            if let have = folders.first(where: { $0.name.lowercased() == name.lowercased() }) {
                folder = have
            } else {
                folder = LinkFolder(name: name, about: fd["description"] as? String ?? "")
                context.insert(folder)
                folders.append(folder)
                summary.linkFoldersCreated += 1
            }
            for ld in (fd["links"] as? [[String: Any]]) ?? [] { takeLink(ld, folder: folder) }
        }
        for ld in (json["links"] as? [[String: Any]]) ?? [] { takeLink(ld, folder: nil) }
        // FONN-TOLEARN-1: present only in a library backup.
        if let list = json["to_learn"] as? [[String: Any]] {
            _ = TunesToLearn.take(list, into: context)
        }
        try? context.save()
    }

    /// A shared links file, as `FileImports.importCeolJSON` meets it.
    static func importFile(json: [String: Any], context: ModelContext) -> FileImports.Summary {
        var summary = FileImports.Summary()
        summary.linksOnly = true
        take(json, into: context, summary: &summary)
        return summary
    }

    /// Everything in Resources, for a library backup.
    public static func backup(context: ModelContext) -> [String: Any]? {
        let folders = ((try? context.fetch(FetchDescriptor<LinkFolder>())) ?? [])
            .sorted { TitleDisplay.precedes($0.name, $1.name) }
        let loose = ((try? context.fetch(FetchDescriptor<SavedLink>())) ?? [])
            .filter { ($0.folders ?? []).isEmpty }
            .sorted { $0.createdAt > $1.createdAt }
        // FONN-TOLEARN-1: Tunes to Learn goes with Resources in a backup.
        let toLearn = TunesToLearn.backup(context: context)
        guard !folders.isEmpty || !loose.isEmpty || !toLearn.isEmpty else { return nil }
        var out = payload(folders: folders, loose: loose, name: "Resources")
        if !toLearn.isEmpty { out["to_learn"] = toLearn }
        return out
    }
}

extension UTType {
    /// The `.fonn` type both apps declare (UTExportedTypeDeclarations).
    public static let fonnFile = UTType(exportedAs: "com.glenachulish.fonn.tunes")
}

/// A links file ready for `ShareLink`. Holds bytes rather than the folders
/// themselves, so it is Sendable and the share sheet can write it whenever it
/// likes.
public struct LinksFile: Transferable, Sendable {
    public let data: Data
    public let name: String

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .fonnFile) { file in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("CeolExport", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safe = file.name
                .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
                .joined(separator: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url = folder.appendingPathComponent((safe.isEmpty ? "Links" : String(safe.prefix(80)))
                                                    + "." + LibraryExport.fonnFileExtension)
            try? FileManager.default.removeItem(at: url)
            try file.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
