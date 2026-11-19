import SwiftUI
import SwiftData
import CoreTransferable
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// FONN-RESOURCES-1
// The Resources screens, shared by both apps as SoundPanel is, so iOS and the
// Mac can't drift apart: the iPhone shows `ResourcesBrowser` as a tab, the Mac
// in a window of its own (Window ▸ Resources).

// MARK: - Browser

/// Folders, "All links" and "Not in a folder"; search across everything; +,
/// Paste, and dropping a link from Safari (Mac, iPad) to save one.
public struct ResourcesBrowser: View {
    @Environment(\.modelContext) private var context
    @Query private var folders: [LinkFolder]
    @Query(sort: \SavedLink.createdAt, order: .reverse) private var links: [SavedLink]
    /// FONN-TOLEARN-1: for the Tunes to Learn row's count.
    @Query private var toLearn: [TuneToLearn]

    @State private var search = ""
    @State private var editing: LinkEditTarget?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renaming: LinkFolder?
    @State private var renameText = ""
    @State private var deletingFolder: LinkFolder?
    @State private var notice: String?

    public init() {}

    private var sortedFolders: [LinkFolder] {
        folders.sorted { TitleDisplay.precedes($0.name, $1.name) }
    }

    private var unfiledCount: Int { links.filter { ($0.folders ?? []).isEmpty }.count }

    private var found: [SavedLink] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return links.filter { link in
            link.displayTitle.localizedCaseInsensitiveContains(needle)
                || link.urlString.localizedCaseInsensitiveContains(needle)
                || link.notes.localizedCaseInsensitiveContains(needle)
                || link.sortedFolders.contains { $0.name.localizedCaseInsensitiveContains(needle) }
                || link.sortedTunes.contains { $0.title.localizedCaseInsensitiveContains(needle) }
        }
    }

    public var body: some View {
        NavigationStack {
            list
                .navigationTitle("Resources")
                .searchable(text: $search, prompt: "Search links")
                .toolbar { toolbar }
                .dropDestination(for: URL.self) { urls, _ in
                    save(urls, into: nil)
                    return true
                }
                .sheet(item: $editing) { target in
                    ResourceEditor(target: target)
                }
                .alert("New folder", isPresented: $showNewFolder) {
                    TextField("Name", text: $newFolderName)
                    Button("Cancel", role: .cancel) { newFolderName = "" }
                    Button("Make") { makeFolder() }
                }
                .alert("Rename folder", isPresented: Binding(
                    get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                    TextField("Name", text: $renameText)
                    Button("Cancel", role: .cancel) { renaming = nil }
                    Button("Rename") {
                        let name = renameText.trimmingCharacters(in: .whitespaces)
                        if let renaming, !name.isEmpty { renaming.name = name; try? context.save() }
                        renaming = nil
                    }
                }
                .confirmationDialog(
                    "Delete “\(deletingFolder?.name ?? "")”?",
                    isPresented: Binding(get: { deletingFolder != nil },
                                         set: { if !$0 { deletingFolder = nil } }),
                    titleVisibility: .visible
                ) {
                    Button("Delete Folder", role: .destructive) {
                        if let deletingFolder { context.delete(deletingFolder); try? context.save() }
                        deletingFolder = nil
                    }
                } message: {
                    Text("Its links stay in Resources.")
                }
                .alert(notice ?? "", isPresented: Binding(
                    get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                    Button("OK") { notice = nil }
                }
        }
    }

    @ViewBuilder private var list: some View {
        if !found.isEmpty || !search.trimmingCharacters(in: .whitespaces).isEmpty {
            List {
                ForEach(found) { link in
                    ResourceRowLink(link: link, showFolders: true, edit: { editing = .init(link: link) })
                }
            }
        } else {
            List {
                // FONN-TOLEARN-1: names you mean to learn, typed in.
                Section {
                    NavigationLink {
                        TunesToLearnList()
                    } label: {
                        countedLabel("Tunes to Learn", "checklist",
                                     toLearn.filter { !$0.isLearnt }.count)
                    }
                }
                Section {
                    NavigationLink {
                        ResourceLinkList(scope: .all)
                    } label: {
                        countedLabel("All links", "tray.full", links.count)
                    }
                    NavigationLink {
                        ResourceLinkList(scope: .unfiled)
                    } label: {
                        countedLabel("Not in a folder", "tray", unfiledCount)
                    }
                } footer: {
                    // FONN-TOLEARN-1: was a full-screen overlay, which would now
                    // cover the Tunes to Learn row.
                    if links.isEmpty && folders.isEmpty {
                        Text("Keep articles, videos and recordings here, in folders of your own. Share a page to Fonn from Safari or YouTube, paste a link, or tap +.")
                    }
                }
                if !sortedFolders.isEmpty {
                    Section("Folders") {
                        ForEach(sortedFolders) { folder in
                            NavigationLink {
                                ResourceLinkList(scope: .folder(folder))
                            } label: {
                                countedLabel(folder.name, "folder", folder.links?.count ?? 0)
                            }
                            .contextMenu { folderMenu(folder) }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button(role: .destructive) { deletingFolder = folder } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button { startRename(folder) } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func folderMenu(_ folder: LinkFolder) -> some View {
        Button { startRename(folder) } label: { Label("Rename…", systemImage: "pencil") }
        ResourceShareMenu(folders: [folder], name: folder.name)
        Divider()
        Button(role: .destructive) { deletingFolder = folder } label: {
            Label("Delete Folder…", systemImage: "trash")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { editing = .init() } label: { Label("New Link…", systemImage: "link.badge.plus") }
                Button { showNewFolder = true } label: { Label("New Folder…", systemImage: "folder.badge.plus") }
                if !sortedFolders.isEmpty || unfiledCount > 0 {
                    Divider()
                    ResourceShareMenu(folders: sortedFolders,
                                      loose: links.filter { ($0.folders ?? []).isEmpty },
                                      name: "Resources",
                                      title: "Share All Resources")
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        ToolbarItem(placement: .automatic) {
            PasteButton(payloadType: URL.self) { urls in
                Task { @MainActor in save(urls, into: nil) }
            }
            .labelStyle(.iconOnly)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if links.isEmpty && folders.isEmpty && search.isEmpty {
            ContentUnavailableView {
                Label("No links yet", systemImage: "books.vertical")
            } description: {
                Text("Keep articles, videos and recordings here, in folders of your own. Share a page to Fonn from Safari or YouTube, paste a link, or tap +.")
            }
        }
    }

    private func countedLabel(_ title: String, _ symbol: String, _ count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func startRename(_ folder: LinkFolder) {
        renameText = folder.name
        renaming = folder
    }

    private func makeFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        newFolderName = ""
        guard !name.isEmpty else { return }
        context.insert(LinkFolder(name: name))
        try? context.save()
    }

    private func save(_ urls: [URL], into folder: LinkFolder?) {
        notice = ResourceLinkList.saveDropped(urls, into: folder, context: context)
    }
}

// MARK: - A list of links

/// The links in one folder, all of them, or those in no folder.
public struct ResourceLinkList: View {
    public enum Scope: Hashable {
        case all, unfiled
        case folder(LinkFolder)
    }

    let scope: Scope
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedLink.createdAt, order: .reverse) private var allLinks: [SavedLink]
    @State private var kind: LinkKind?
    @State private var editing: LinkEditTarget?
    @State private var notice: String?

    public init(scope: Scope) { self.scope = scope }

    private var folder: LinkFolder? {
        if case .folder(let f) = scope { return f }
        return nil
    }

    private var title: String {
        switch scope {
        case .all: return "All links"
        case .unfiled: return "Not in a folder"
        case .folder(let f): return f.name
        }
    }

    private var inScope: [SavedLink] {
        switch scope {
        case .all: return allLinks
        case .unfiled: return allLinks.filter { ($0.folders ?? []).isEmpty }
        case .folder(let f): return allLinks.filter { ($0.folders ?? []).contains { $0 === f } }
        }
    }

    private var shown: [SavedLink] {
        guard let kind else { return inScope }
        return inScope.filter { $0.kind == kind }
    }

    public var body: some View {
        List {
            if let about = folder?.about, !about.isEmpty {
                Text(about).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(shown) { link in
                ResourceRowLink(link: link, showFolders: folder == nil,
                                edit: { editing = .init(link: link) })
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            context.delete(link)
                            try? context.save()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        if let folder {
                            Button {
                                link.folders = (link.folders ?? []).filter { $0 !== folder }
                                try? context.save()
                            } label: {
                                Label("Remove", systemImage: "folder.badge.minus")
                            }
                            .tint(.orange)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button { editing = .init(link: link) } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
            }
        }
        .navigationTitle(title)
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView(kind == nil ? "No links here" : "Nothing of that kind here",
                                       systemImage: kind?.systemImage ?? "link",
                                       description: Text(folder == nil ? "" : "Tap + to add one, or file a link here from its Edit screen."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = .init(folder: folder) } label: {
                    Label("New Link", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker("Show", selection: $kind) {
                        Text("Everything").tag(LinkKind?.none)
                        ForEach(LinkKind.allCases) { k in
                            Label(k.label, systemImage: k.systemImage).tag(LinkKind?.some(k))
                        }
                    }
                    if !inScope.isEmpty {
                        Divider()
                        if let folder {
                            ResourceShareMenu(folders: [folder], name: folder.name)
                        } else {
                            ResourceShareMenu(folders: [], loose: inScope, name: title)
                        }
                    }
                } label: {
                    Label("More", systemImage: kind == nil ? "ellipsis.circle"
                                                           : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            notice = Self.saveDropped(urls, into: folder, context: context)
            return true
        }
        .sheet(item: $editing) { target in
            ResourceEditor(target: target)
        }
        .alert(notice ?? "", isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        }
    }

    /// Links dropped or pasted in: saved, titles fetched afterwards. Returns
    /// what to tell you, or nil when there is nothing worth saying.
    static func saveDropped(_ urls: [URL], into folder: LinkFolder?, context: ModelContext) -> String? {
        let web = urls.compactMap { ResourceLinks.url(from: $0.absoluteString) }
        guard !web.isEmpty else { return "That isn't a web link Fonn can keep." }
        var added: [SavedLink] = []
        for url in web {
            let (link, isNew) = ResourceLinks.save(url, folder: folder, in: context)
            if isNew { added.append(link) }
        }
        try? context.save()
        for link in added {
            Task { @MainActor in await ResourceLinks.fillTitle(link, in: context) }
        }
        if added.isEmpty { return web.count == 1 ? "You already have that link." : nil }
        return nil
    }
}

// MARK: - One link

/// A link's row: tap to open it inside Fonn (FONN-RESOURCES-2), Edit and the
/// rest in the context menu.
struct ResourceRowLink: View {
    let link: SavedLink
    var showFolders = false
    let edit: () -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context
    @State private var opened: OpenedLink?

    private func open() {
        guard let url = link.webURL else { return }
        opened = OpenedLink(url: url)
    }

    var body: some View {
        Button(action: open) {
            ResourceRow(link: link, showFolders: showFolders)
        }
        .buttonStyle(.plain)
        .opensResourceLinks($opened)
        .contextMenu {
            if let url = link.webURL {
                Button(action: open) { Label("Open", systemImage: "rectangle.portrait.and.arrow.forward") }
                Button { openURL(url) } label: {
                    #if os(macOS)
                    Label("Open in Browser", systemImage: "safari")
                    #else
                    Label("Open Outside Fonn", systemImage: "safari")
                    #endif
                }
            }
            Button(action: edit) { Label("Edit…", systemImage: "pencil") }
            if let url = link.webURL {
                ShareLink(item: url) { Label("Share Link…", systemImage: "square.and.arrow.up") }
                Button { ResourceClipboard.copy(url) } label: { Label("Copy Link", systemImage: "doc.on.doc") }
            }
            Divider()
            Button(role: .destructive) {
                context.delete(link)
                try? context.save()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

public struct ResourceRow: View {
    let link: SavedLink
    var showFolders = false

    public init(link: SavedLink, showFolders: Bool = false) {
        self.link = link
        self.showFolders = showFolders
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: link.kind.systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.displayTitle).lineLimit(2)
                Text(link.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !link.notes.isEmpty {
                    Text(link.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                let tunes = link.sortedTunes.map { TitleDisplay.plain($0.title) }
                if !tunes.isEmpty {
                    Label(tunes.joined(separator: ", "), systemImage: "music.note")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if showFolders, !link.sortedFolders.isEmpty {
                    Label(link.sortedFolders.map(\.name).joined(separator: ", "), systemImage: "folder")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

// MARK: - Sharing

/// "Send to someone with Fonn" (a .fonn file) and "Share as a list" (plain
/// text, for anyone), as menu items.
struct ResourceShareMenu: View {
    let folders: [LinkFolder]
    var loose: [SavedLink] = []
    let name: String
    var title = "Share"

    var body: some View {
        Menu {
            ShareLink(item: ResourceShare.file(folders: folders, loose: loose, name: name),
                      preview: SharePreview("\(name) — links for Fonn")) {
                Label("Send to Someone with Fonn…", systemImage: "music.note.house")
            }
            ShareLink(item: ResourceShare.text(folders: folders, loose: loose, name: name)) {
                Label("Share as a List of Links…", systemImage: "list.bullet")
            }
        } label: {
            Label(title, systemImage: "square.and.arrow.up")
        }
    }
}

enum ResourceClipboard {
    static func copy(_ url: URL) {
        #if canImport(UIKit)
        UIPasteboard.general.url = url
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #endif
    }
}

// MARK: - Adding and editing

/// What the editor opens on: a link to change, or a new one, perhaps already
/// in a folder or against a tune.
public struct LinkEditTarget: Identifiable {
    public let id = UUID()
    var link: SavedLink?
    var folder: LinkFolder?
    var tune: Tune?
    var url: URL?

    public init(link: SavedLink? = nil, folder: LinkFolder? = nil, tune: Tune? = nil, url: URL? = nil) {
        self.link = link
        self.folder = folder
        self.tune = tune
        self.url = url
    }
}

struct ResourceEditor: View {
    let target: LinkEditTarget
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var folders: [LinkFolder]
    @Query(filter: #Predicate<Tune> { $0.isDefaultVersion }) private var tunes: [Tune]

    @State private var address = ""
    @State private var title = ""
    @State private var notes = ""
    @State private var kind: LinkKind = .article
    @State private var kindChosen = false
    @State private var chosenFolders: [LinkFolder] = []
    @State private var chosenTunes: [Tune] = []
    @State private var newFolder = ""
    @State private var tuneSearch = ""
    @State private var fetching = false
    @State private var confirmDelete = false
    @State private var loaded = false

    private var url: URL? { ResourceLinks.url(from: address) }

    private var sortedFolders: [LinkFolder] {
        folders.sorted { TitleDisplay.precedes($0.name, $1.name) }
    }

    private var tuneMatches: [Tune] {
        let needle = tuneSearch.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return [] }
        return tunes
            .filter { tune in
                !chosenTunes.contains { $0 === tune }
                    && (tune.title.localizedCaseInsensitiveContains(needle)
                        || tune.aliases.contains { $0.localizedCaseInsensitiveContains(needle) })
            }
            .sorted { TitleDisplay.precedes($0.title, $1.title) }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            form
                .navigationTitle(target.link == nil ? "New Link" : "Edit Link")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }.disabled(url == nil)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
        .onAppear(perform: load)
    }

    private var form: some View {
        Form {
            Section {
                TextField("https://…", text: $address)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit(fetchTitleIfNeeded)
                    .onChange(of: address) {
                        if !kindChosen, let url { kind = LinkKind.guess(for: url) }
                    }
                if !address.isEmpty && url == nil {
                    Text("That doesn't look like a web address.")
                        .font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Address")
            }

            Section {
                TextField("Title", text: $title)
                Button {
                    fetchTitle()
                } label: {
                    HStack {
                        Text("Get the Title from the Page")
                        if fetching { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(url == nil || fetching)
                Picker("What it is", selection: Binding(
                    get: { kind }, set: { kind = $0; kindChosen = true })) {
                    ForEach(LinkKind.allCases) { k in
                        Label(k.label, systemImage: k.systemImage).tag(k)
                    }
                }
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...8)
            } header: {
                Text("About it")
            }

            Section {
                ForEach(sortedFolders) { folder in
                    Toggle(folder.name, isOn: Binding(
                        get: { chosenFolders.contains { $0 === folder } },
                        set: { on in
                            if on { chosenFolders.append(folder) }
                            else { chosenFolders.removeAll { $0 === folder } }
                        }))
                }
                HStack {
                    TextField("New folder", text: $newFolder)
                        .onSubmit(addFolder)
                    Button("Add", action: addFolder)
                        .disabled(newFolder.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Folders")
            } footer: {
                Text("A link can be in more than one folder, or none.")
            }

            Section {
                ForEach(chosenTunes) { tune in
                    HStack {
                        Label(TitleDisplay.plain(tune.title), systemImage: "music.note")
                        Spacer()
                        Button {
                            chosenTunes.removeAll { $0 === tune }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                TextField("Find a tune…", text: $tuneSearch)
                    .autocorrectionDisabled()
                ForEach(tuneMatches) { tune in
                    Button {
                        chosenTunes.append(tune)
                        tuneSearch = ""
                    } label: {
                        Label(TitleDisplay.plain(tune.title), systemImage: "plus.circle")
                    }
                }
            } header: {
                Text("Tunes")
            } footer: {
                Text("The link shows on these tunes' Details as well as here.")
            }

            if target.link != nil {
                Section {
                    Button("Delete Link", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete this link?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Link", role: .destructive) {
                if let link = target.link { context.delete(link); try? context.save() }
                dismiss()
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let link = target.link {
            address = link.urlString
            title = link.title
            notes = link.notes
            kind = link.kind
            kindChosen = true
            chosenFolders = link.sortedFolders
            chosenTunes = link.sortedTunes
        } else {
            if let url = target.url { address = url.absoluteString }
            if let folder = target.folder { chosenFolders = [folder] }
            if let tune = target.tune { chosenTunes = [tune] }
        }
    }

    private func addFolder() {
        let name = newFolder.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newFolder = ""
        if let have = folders.first(where: { $0.name.lowercased() == name.lowercased() }) {
            if !chosenFolders.contains(where: { $0 === have }) { chosenFolders.append(have) }
            return
        }
        let folder = LinkFolder(name: name)
        context.insert(folder)
        chosenFolders.append(folder)
    }

    private func fetchTitleIfNeeded() {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { fetchTitle() }
    }

    private func fetchTitle() {
        guard let url, !fetching else { return }
        fetching = true
        Task { @MainActor in
            if let found = await LinkTitles.title(for: url) { title = found }
            fetching = false
        }
    }

    private func save() {
        guard let url else { return }
        let link: SavedLink
        if let existing = target.link {
            link = existing
            link.urlString = url.absoluteString
        } else if let same = ResourceLinks.existing(url.absoluteString, in: context) {
            // The address is already in Resources: this becomes an edit of
            // that link, keeping its folders and tunes as well as these.
            link = same
            chosenFolders += same.sortedFolders.filter { f in !chosenFolders.contains { $0 === f } }
            chosenTunes += same.sortedTunes.filter { t in !chosenTunes.contains { $0 === t } }
        } else {
            link = SavedLink(urlString: url.absoluteString)
            context.insert(link)
        }
        link.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        link.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        link.kind = kind
        link.folders = chosenFolders
        link.tunes = chosenTunes
        try? context.save()
        if link.title.isEmpty {
            Task { @MainActor in await ResourceLinks.fillTitle(link, in: context) }
        }
        dismiss()
    }
}

// MARK: - On a tune

/// The tune's links in Resources, for its Details, with "Add a Link…".
public struct TuneResourcesSection: View {
    let tune: Tune
    @State private var editing: LinkEditTarget?

    public init(tune: Tune) { self.tune = tune }

    private var links: [SavedLink] {
        (tune.savedLinks ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    public var body: some View {
        Section {
            ForEach(links) { link in
                ResourceRowLink(link: link, showFolders: true, edit: { editing = .init(link: link) })
            }
            Button {
                editing = .init(tune: tune)
            } label: {
                Label("Add a Link…", systemImage: "link.badge.plus")
            }
            // On the button rather than the Section: a Form lays out what a
            // section is wrapped in unpredictably.
            .sheet(item: $editing) { target in
                ResourceEditor(target: target)
            }
        } header: {
            Text("Resources")
        } footer: {
            Text("Links kept in Resources: articles, videos, recordings. Different from attachments, which belong to the tune.")
        }
    }
}
