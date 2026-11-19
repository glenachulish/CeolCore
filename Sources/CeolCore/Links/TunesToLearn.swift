import Foundation
import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// FONN-TOLEARN-1
// Tunes to Learn: a plain list of tune names you mean to learn, typed in (or
// pasted as a list), kept in Resources on both apps. Not tunes in the library:
// a name is all you have when someone says "you should learn The Mason's
// Apron", and the library is for tunes with music.
//
// CloudKit rules, as in Models.swift: every attribute defaulted, no unique
// constraints. **A new record type (CD_TuneToLearn) needs Deploy Schema
// Changes to Production before a TestFlight build ships it.**

@Model
public final class TuneToLearn {
    public var uuid: UUID = UUID()
    public var title: String = ""
    public var notes: String = ""
    public var createdAt: Date = Date()
    /// When you ticked it off; nil while it is still to learn.
    public var learntAt: Date? = nil

    public init(title: String = "", notes: String = "") {
        self.title = title
        self.notes = notes
    }

    public var isLearnt: Bool { learntAt != nil }
}

public enum TunesToLearn {

    /// One name per line, so a pasted list becomes one entry each. Bullets,
    /// numbers and stray spaces at the start of a line are dropped.
    public static func names(in text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { line in
            var s = line.trimmingCharacters(in: .whitespaces)
            while let first = s.first, "-•*·–".contains(first) {
                s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if let dot = s.firstIndex(where: { $0 == "." || $0 == ")" }),
               !s[s.startIndex..<dot].isEmpty,
               s[s.startIndex..<dot].allSatisfy(\.isNumber) {
                s = String(s[s.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            }
            return s.isEmpty ? nil : s
        }
    }

    /// How two names are compared: spoken form, case and spacing ignored, so
    /// "Kesh, The" and "the kesh" are the same tune.
    public static func key(_ title: String) -> String {
        TitleDisplay.spoken(title).lowercased()
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Add these names, skipping any already on the list (learnt or not).
    /// Returns how many were added.
    @discardableResult
    public static func add(_ names: [String], in context: ModelContext) -> Int {
        let have = Set(((try? context.fetch(FetchDescriptor<TuneToLearn>())) ?? []).map { key($0.title) })
        var seen = have
        var added = 0
        for name in names {
            let k = key(name)
            guard !k.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k)
            context.insert(TuneToLearn(title: name))
            added += 1
        }
        if added > 0 { try? context.save() }
        return added
    }

    /// For a library backup, under `resources` ▸ `to_learn`.
    public static func backup(context: ModelContext) -> [[String: Any]] {
        let all = ((try? context.fetch(FetchDescriptor<TuneToLearn>())) ?? [])
            .sorted { $0.createdAt < $1.createdAt }
        let stamp = ISO8601DateFormatter()
        return all.map { item in
            var dict: [String: Any] = ["title": item.title,
                                       "added": stamp.string(from: item.createdAt)]
            if !item.notes.isEmpty { dict["notes"] = item.notes }
            if let learnt = item.learntAt { dict["learnt"] = stamp.string(from: learnt) }
            return dict
        }
    }

    /// Restore from a backup. A name already on the list is left alone.
    public static func take(_ list: [[String: Any]], into context: ModelContext) -> Int {
        var seen = Set(((try? context.fetch(FetchDescriptor<TuneToLearn>())) ?? []).map { key($0.title) })
        let stamp = ISO8601DateFormatter()
        var added = 0
        for dict in list {
            let title = (dict["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let k = key(title)
            guard !k.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k)
            let item = TuneToLearn(title: title, notes: dict["notes"] as? String ?? "")
            if let s = dict["added"] as? String, let d = stamp.date(from: s) { item.createdAt = d }
            if let s = dict["learnt"] as? String, let d = stamp.date(from: s) { item.learntAt = d }
            context.insert(item)
            added += 1
        }
        return added
    }

    /// The list as plain text, for sending to someone.
    public static func text(_ items: [TuneToLearn]) -> String {
        let lines = items.map { item -> String in
            item.notes.isEmpty ? item.title : "\(item.title) (\(item.notes))"
        }
        return (["Tunes to learn"] + lines).joined(separator: "\n")
    }
}

// MARK: - The list

/// Type a name and press Return to add it; paste a list to add each line.
/// Tick a tune off once you have it. A name matching a tune already in the
/// library says so.
public struct TunesToLearnList: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TuneToLearn.createdAt) private var items: [TuneToLearn]
    @Query(filter: #Predicate<Tune> { $0.isDefaultVersion }) private var tunes: [Tune]

    @State private var newName = ""
    @State private var editing: TuneToLearn?
    @State private var editTitle = ""
    @State private var editNotes = ""
    @State private var opened: OpenedLink?
    @State private var showLearnt = false
    @State private var notice: String?
    @FocusState private var typing: Bool

    public init() {}

    private var toLearn: [TuneToLearn] { items.filter { !$0.isLearnt } }
    private var learnt: [TuneToLearn] {
        items.filter(\.isLearnt).sorted { ($0.learntAt ?? .distantPast) > ($1.learntAt ?? .distantPast) }
    }

    private var libraryKeys: Set<String> { Set(tunes.map { TunesToLearn.key($0.title) }) }

    public var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                    TextField("Add a tune to learn", text: $newName, axis: .vertical)
                        .focused($typing)
                        .onSubmit(addTyped)
                        .submitLabel(.done)
                        // A list pasted into the field arrives with its line
                        // breaks: add every line, as Paste a List does.
                        .onChange(of: newName) {
                            if newName.contains("\n") { addTyped() }
                        }
                }
            } footer: {
                if items.isEmpty {
                    Text("Type a name and press Return. To add several at once, paste a list with one tune per line.")
                }
            }

            if !toLearn.isEmpty {
                Section("To learn (\(toLearn.count))") {
                    ForEach(toLearn) { row($0) }
                        .onDelete { offsets in delete(offsets.map { toLearn[$0] }) }
                }
            }

            if !learnt.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showLearnt) {
                        ForEach(learnt) { row($0) }
                            .onDelete { offsets in delete(offsets.map { learnt[$0] }) }
                    } label: {
                        Text("Learnt (\(learnt.count))")
                    }
                }
            }
        }
        .navigationTitle("Tunes to Learn")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { pasteList() } label: {
                        Label("Paste a List", systemImage: "doc.on.clipboard")
                    }
                    if !toLearn.isEmpty {
                        ShareLink(item: TunesToLearn.text(toLearn)) {
                            Label("Share the List…", systemImage: "square.and.arrow.up")
                        }
                    }
                    if !learnt.isEmpty {
                        Divider()
                        Button(role: .destructive) { delete(learnt) } label: {
                            Label("Clear Learnt Tunes", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .opensResourceLinks($opened)
        .alert("Edit", isPresented: Binding(get: { editing != nil },
                                            set: { if !$0 { editing = nil } })) {
            TextField("Name", text: $editTitle)
            TextField("Notes (who, where heard)", text: $editNotes)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") {
                let name = editTitle.trimmingCharacters(in: .whitespaces)
                if let editing, !name.isEmpty {
                    editing.title = name
                    editing.notes = editNotes.trimmingCharacters(in: .whitespaces)
                    try? context.save()
                }
                editing = nil
            }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil },
                                                  set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        }
    }

    private func row(_ item: TuneToLearn) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                item.learntAt = item.isLearnt ? nil : Date()
                try? context.save()
            } label: {
                Image(systemName: item.isLearnt ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isLearnt ? AnyShapeStyle(Color.green) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isLearnt ? "Mark as still to learn" : "Mark as learnt")

            VStack(alignment: .leading, spacing: 2) {
                Text(TitleDisplay.spoken(item.title))
                    .foregroundStyle(item.isLearnt ? .secondary : .primary)
                if !item.notes.isEmpty {
                    Text(item.notes).font(.caption).foregroundStyle(.secondary)
                }
                if libraryKeys.contains(TunesToLearn.key(item.title)) {
                    Label("In your library", systemImage: "music.note.list")
                        .font(.caption).foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button { startEdit(item) } label: { Label("Edit…", systemImage: "pencil") }
            Button { lookUp(item) } label: {
                Label("Look Up on thesession.org", systemImage: "magnifyingglass")
            }
            Button {
                item.learntAt = item.isLearnt ? nil : Date()
                try? context.save()
            } label: {
                Label(item.isLearnt ? "Still to Learn" : "Learnt",
                      systemImage: item.isLearnt ? "circle" : "checkmark.circle")
            }
            Divider()
            Button(role: .destructive) { delete([item]) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        #if os(iOS)
        .swipeActions(edge: .leading) {
            Button { startEdit(item) } label: { Label("Edit", systemImage: "pencil") }
                .tint(.blue)
        }
        #endif
    }

    private func addTyped() {
        let names = TunesToLearn.names(in: newName)
        newName = ""
        let added = TunesToLearn.add(names, in: context)
        if added < names.count {
            let skipped = names.count - added
            notice = skipped == 1 && names.count == 1
                ? "That tune is already on the list."
                : "\(skipped) already on the list, so left out."
        }
        typing = true
    }

    private func pasteList() {
        #if canImport(UIKit)
        let text = UIPasteboard.general.string ?? ""
        #elseif canImport(AppKit)
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        #endif
        let names = TunesToLearn.names(in: text)
        guard !names.isEmpty else {
            notice = "There is no text to paste. Copy a list of tune names, one per line, first."
            return
        }
        let added = TunesToLearn.add(names, in: context)
        let skipped = names.count - added
        notice = (added == 1 ? "Added 1 tune." : "Added \(added) tunes.")
            + (skipped > 0 ? " \(skipped) already on the list." : "")
    }

    private func startEdit(_ item: TuneToLearn) {
        editTitle = item.title
        editNotes = item.notes
        editing = item
    }

    private func lookUp(_ item: TuneToLearn) {
        var parts = URLComponents(string: "https://thesession.org/tunes/search")!
        parts.queryItems = [URLQueryItem(name: "q", value: TitleDisplay.spoken(item.title))]
        if let url = parts.url { opened = OpenedLink(url: url) }
    }

    private func delete(_ going: [TuneToLearn]) {
        for item in going { context.delete(item) }
        try? context.save()
    }
}
