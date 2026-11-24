import SwiftUI
import SwiftData

// FONN-SETPATTERN-1
/// The circle-of-fifths set builder, one step at a time, the same on the
/// phone and the Mac:
///   1. choose a pattern and the filters (type, stars, hitlist, favourites,
///      collection);
///   2. choose the opening tune;
///   3. at each step, only the tunes that make the pattern's next move are
///      offered, each with a Select button;
///   4. save — with a name, or as the tunes in order joined by " / ".
public struct SetPatternBuilderView: View {
    var opening: Tune?
    var onSaved: (TuneSet) -> Void
    /// FONN-SETPREVIEW-1: the app's own set player, given a name and tunes in
    /// order. The Mac shows it beside every step; the phone opens it as a
    /// sheet. Nil leaves the builder as it was, with no preview.
    var preview: ((_ name: String, _ tunes: [Tune]) -> AnyView)?

    public init(opening: Tune? = nil,
                onSaved: @escaping (TuneSet) -> Void = { _ in },
                preview: ((_ name: String, _ tunes: [Tune]) -> AnyView)? = nil) {
        self.opening = opening
        self.onSaved = onSaved
        self.preview = preview
    }

    private enum Stage { case setup, choosing, finishing }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var allTunes: [Tune]
    @Query(sort: \TuneCollection.name) private var collections: [TuneCollection]

    @State private var stage: Stage = .setup
    @State private var patternID = SetPattern.all[0].id
    @State private var filter = SetBuilderFilter()
    @State private var picked: [Tune] = []
    @State private var freeMove: SetMove = .same
    @State private var search = ""
    @State private var name = ""
    @State private var seeded = false
    /// FONN-SETPREVIEW-1: a tune being tried after the set so far.
    @State private var candidate: Tune?
    @State private var showingPreview = false

    private static let types = ["reel", "jig", "slip jig", "hornpipe", "polka", "slide",
                                "strathspey", "march", "barndance", "highland", "mazurka",
                                "waltz", "air"]

    private var pattern: SetPattern {
        SetPattern.all.first { $0.id == patternID } ?? SetPattern.all[0]
    }

    /// The move wanted next, or nil once the pattern is complete.
    private var nextMove: Int? {
        guard !picked.isEmpty else { return nil }
        guard let moves = pattern.moves else { return freeMove.rawValue }
        let step = picked.count - 1
        return step < moves.count ? moves[step] : nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch stage {
            case .setup: setup
            case .choosing: choosing
            case .finishing: finishing
            }
        }
        #if os(macOS)
        .frame(minWidth: preview == nil ? 640 : 1000,
               idealWidth: preview == nil ? 720 : 1180,
               minHeight: 640, idealHeight: 780)
        #else
        .sheet(isPresented: $showingPreview) {
            if let preview { preview(previewName, previewTunes) }
        }
        #endif
        .onAppear {
            guard !seeded else { return }
            seeded = true
            if let opening { picked = [opening] }
        }
    }

    // MARK: - Header and progress

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Build a Set").font(.headline)
                Spacer()
                if stage == .choosing && !picked.isEmpty {
                    Button {
                        picked.removeLast()
                        candidate = nil
                        if picked.isEmpty && opening == nil { search = "" }
                    } label: {
                        Label("Back", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    // Keeps the title centred.
                    Button("Cancel") {}.hidden()
                }
            }
            if !picked.isEmpty && stage != .setup {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(picked.enumerated()), id: \.offset) { i, tune in
                            Text("\(i + 1). \(TitleDisplay.plain(tune.title))  \(CircleOfFifths.badge(CircleOfFifths.keyName(of: tune)))")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color.green.opacity(0.16), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    // MARK: - 1. Pattern and filters

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("1. Choose a pattern")
                    .font(.title3.weight(.semibold))
                ForEach(SetPattern.all) { p in
                    Button {
                        patternID = p.id
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: patternID == p.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(patternID == p.id ? Color.green : Color.secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(p.name).font(.body.weight(.semibold))
                                    if let n = p.tuneCount {
                                        Text("\(n) tunes").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text(p.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(patternID == p.id ? Color.green.opacity(0.10) : Color.secondary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Text("2. Which tunes to draw from")
                    .font(.title3.weight(.semibold))
                filters

                Button {
                    search = ""
                    stage = .choosing
                } label: {
                    Text(picked.isEmpty ? "Choose the opening tune"
                                        : "Start with \u{201C}\(TitleDisplay.plain(picked[0].title))\u{201D}")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut(.defaultAction)
                if opening != nil && !picked.isEmpty {
                    Button("Choose a different opening tune") {
                        picked = []
                        stage = .choosing
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Type").frame(width: 90, alignment: .leading)
                Picker("Type", selection: $filter.type) {
                    Text("Any type").tag("")
                    ForEach(Self.types, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden()
                Spacer()
            }
            HStack {
                Text("Stars").frame(width: 90, alignment: .leading)
                Picker("Stars", selection: $filter.minRating) {
                    Text("Any").tag(0)
                    ForEach(1...5, id: \.self) { n in
                        Text(String(repeating: "★", count: n) + (n < 5 ? " or more" : "")).tag(n)
                    }
                }
                .labelsHidden()
                Spacer()
            }
            HStack {
                Text("Collection").frame(width: 90, alignment: .leading)
                Picker("Collection", selection: $filter.collectionID) {
                    Text("All tunes").tag(UUID?.none)
                    ForEach(collections) { c in Text(c.name).tag(UUID?.some(c.uuid)) }
                }
                .labelsHidden()
                Spacer()
            }
            Toggle("Only tunes on my hitlist", isOn: $filter.hitlistOnly)
            Toggle("Only favourites", isOn: $filter.favouritesOnly)
        }
    }

    // MARK: - Preview (FONN-SETPREVIEW-1)

    /// While choosing: the set so far, then the tune being tried. At the end:
    /// the set as it will be saved.
    private var previewTunes: [Tune] {
        guard stage == .choosing, let candidate,
              !picked.contains(where: { $0.persistentModelID == candidate.persistentModelID })
        else { return picked }
        return picked + [candidate]
    }

    private var previewName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? "Preview" : typed
    }

    private var previewCaption: String {
        if stage == .finishing { return "The whole set, as it will be saved. Press ▶ to hear it." }
        if let candidate, stage == .choosing {
            let what = picked.isEmpty ? "" : "The set so far, then "
            return what + "\u{201C}\(TitleDisplay.plain(candidate.title))\u{201D}. Select it to keep it."
        }
        if picked.isEmpty { return "Click the eye beside a tune to see and hear it here." }
        return "The set so far. Click the eye beside a tune to try it next."
    }

    private var previewPane: some View {
        let tunes = previewTunes
        let playable = tunes.contains { $0.hasNotation }
        return VStack(alignment: .leading, spacing: 0) {
            Text(previewCaption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            if let preview, playable {
                preview(previewName, tunes)
                    .id(tunes.map(\.persistentModelID))
            } else {
                Text(tunes.isEmpty ? "Nothing to show yet." : "These tunes have no notation to show.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The step beside its preview on the Mac; on its own on the phone.
    @ViewBuilder
    private func withPreview<Content: View>(_ content: Content) -> some View {
        #if os(macOS)
        if preview != nil {
            HStack(spacing: 0) {
                content.frame(minWidth: 380, idealWidth: 420, maxWidth: 480, maxHeight: .infinity)
                Divider()
                previewPane
            }
        } else {
            content
        }
        #else
        content
        #endif
    }

    // MARK: - 2/3. Choosing the tunes

    private var choosing: some View {
        withPreview(choosingList)
    }

    private var choosingList: some View {
        let pool = SetPatternLogic.pool(allTunes, filter: filter, collections: collections, excluding: picked)
        let offered: [Tune] = {
            let base: [Tune]
            if picked.isEmpty {
                base = SetPatternLogic.openers(in: pool)
            } else if let move = nextMove, let last = picked.last {
                base = SetPatternLogic.candidates(after: last, move: move, in: pool)
            } else {
                base = []
            }
            let q = search.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return base }
            return base.filter { $0.title.lowercased().contains(q) }
        }()
        return VStack(alignment: .leading, spacing: 8) {
            stepTitle
                .padding(.horizontal, 16)
            if pattern.moves == nil && !picked.isEmpty {
                Picker("Next move", selection: $freeMove) {
                    ForEach(SetMove.allCases) { Text($0.label).tag($0) }
                }
                .padding(.horizontal, 16)
            }
            HStack {
                TextField("Search these tunes", text: $search)
                    .textFieldStyle(.roundedBorder)
                if picked.count >= 2 {
                    Button("Finish") { stage = .finishing }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                }
            }
            .padding(.horizontal, 16)
            if offered.isEmpty {
                emptyHelp
            } else {
                List(offered, id: \.persistentModelID) { tune in
                    row(tune)
                }
                .listStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var stepTitle: some View {
        if picked.isEmpty {
            Text("Choose the opening tune").font(.title3.weight(.semibold))
        } else if let move = nextMove, let last = picked.last {
            let count = pattern.tuneCount.map { " of \($0)" } ?? ""
            VStack(alignment: .leading, spacing: 2) {
                Text("Tune \(picked.count + 1)\(count): \(SetMove.describe(move).lowercased())")
                    .font(.title3.weight(.semibold))
                if let sig = SetPatternLogic.target(after: last, move: move) {
                    Text("From \(CircleOfFifths.badge(CircleOfFifths.keyName(of: last))): \(SetPatternLogic.keysLabel(atSignature: sig))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if move != SetMove.anyKey.rawValue {
                    Text("\u{201C}\(TitleDisplay.plain(last.title))\u{201D} has no key on the circle, so the next tune can't be worked out from it. Go Back, or choose Free and Any key.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var emptyHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(picked.isEmpty ? "No tunes match the filters." : "No tunes make that move with these filters.")
                .font(.headline)
            Text("Try loosening the filters, or the Free pattern, which lets you choose a different move at each step.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Change pattern or filters") { stage = .setup }
                if picked.count >= 2 {
                    Button("Finish with \(picked.count) tunes") { stage = .finishing }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ tune: Tune) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(TitleDisplay.plain(tune.title)).lineLimit(2)
                HStack(spacing: 6) {
                    let detail = [tune.type.capitalized,
                                  CircleOfFifths.badge(CircleOfFifths.keyName(of: tune))]
                        .filter { !$0.isEmpty }
                    Text(detail.joined(separator: " · "))
                    if tune.rating > 0 {
                        Text(String(repeating: "★", count: tune.rating)).foregroundStyle(.yellow)
                    }
                    if tune.isFavourite { Image(systemName: "heart.fill").foregroundStyle(.red) }
                    if tune.onHitlist { Image(systemName: "target").foregroundStyle(.orange) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if preview != nil {
                Button {
                    candidate = tune
                    #if os(iOS)
                    showingPreview = true
                    #endif
                } label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.bordered)
                .help("See and hear it after the set so far")
            }
            Button("Select") { select(tune) }
                .buttonStyle(.borderedProminent)
                .tint(.green)
        }
        .padding(.vertical, 2)
        .listRowBackground(candidate?.persistentModelID == tune.persistentModelID
                           ? Color.green.opacity(0.12) : Color.clear)
    }

    private func select(_ tune: Tune) {
        picked.append(tune)
        candidate = nil
        search = ""
        if let count = pattern.tuneCount, picked.count >= count {
            stage = .finishing
        }
    }

    // MARK: - 4. Saving

    private var finishing: some View {
        withPreview(finishingForm)
    }

    private var finishingForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Your set").font(.title3.weight(.semibold))
                ForEach(Array(picked.enumerated()), id: \.offset) { i, tune in
                    HStack {
                        Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(TitleDisplay.plain(tune.title))
                        Spacer()
                        Text(CircleOfFifths.badge(CircleOfFifths.keyName(of: tune)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if i + 1 < picked.count,
                       let a = SetPatternLogic.signature(of: tune),
                       let b = SetPatternLogic.signature(of: picked[i + 1]) {
                        Text("   \u{2193} \(SetMove.describe(b - a).lowercased())")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                #if os(iOS)
                if preview != nil {
                    Button {
                        candidate = nil
                        showingPreview = true
                    } label: {
                        Label("See and hear the whole set", systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                #endif
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.headline)
                    TextField(SetPatternLogic.defaultName(picked), text: $name)
                        .textFieldStyle(.roundedBorder)
                    Text("Leave it empty to name the set after its tunes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    let set = SetPatternLogic.save(picked, named: name, in: context)
                    onSaved(set)
                    dismiss()
                } label: {
                    Text("Save the set").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut(.defaultAction)
                HStack {
                    Button("Add another tune") {
                        // Carries on freely from the last tune.
                        patternID = "free"
                        freeMove = .same
                        stage = .choosing
                    }
                    Spacer()
                    Button("Back") {
                        if pattern.tuneCount != nil { picked.removeLast() }
                        stage = .choosing
                    }
                }
            }
            .padding(16)
        }
    }
}
