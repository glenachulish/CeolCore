import SwiftUI
import SwiftData

// FONN-SESSIONTYPES-1
/// Types for tunes that have none, from thesession.org.
///
/// Callum had ~200 tunes in "No tune type" and asked for their types to be
/// taken from The Session rather than set one by one. A tune that came from
/// The Session (its id, or a thesession.org/tunes/N link) is fetched by id,
/// which is exact. Any other is searched by name and only an exact match of
/// the name (or one of its other names), "The" either end and punctuation
/// aside, is offered. Where The Session has several tunes of that name with
/// different types, the best known is offered but left unticked.
///
/// One click per tune (Callum's choice): each found tune has its own Set
/// button, which sets that tune at once and becomes Undo. Nothing is set in
/// bulk. One request at a time with a pause between, so a long list
/// doesn't hammer the site.
public enum SessionTypes {

    public struct Match: Sendable {
        public let type: String
        public let sessionName: String
        public let byLink: Bool
        public let ambiguous: Bool
    }

    /// The Session's tune number for a tune that came from there.
    static func sessionID(of tune: Tune) -> Int? {
        if let id = tune.theSessionID, id > 0 { return id }
        guard let range = tune.sourceURL.range(of: #"thesession\.org/tunes/(\d+)"#,
                                               options: .regularExpression) else { return nil }
        let digits = tune.sourceURL[range].split(separator: "/").last.map(String.init) ?? ""
        return Int(digits)
    }

    static func match(title: String, aliases: [String], sessionID: Int?) async throws -> Match? {
        if let sessionID {
            let detail = try await TheSessionAPI.tune(id: sessionID)
            let type = detail.type.trimmingCharacters(in: .whitespaces).lowercased()
            return type.isEmpty ? nil
                : Match(type: type, sessionName: detail.name, byLink: true, ambiguous: false)
        }
        let names = ([title] + aliases).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var wanted = Set<String>()
        for name in names { wanted.formUnion(TitleMatching.variants(of: TitleDisplay.plain(name))) }
        wanted.remove("")
        guard !wanted.isEmpty else { return nil }
        // Hyphens for spaces ("Dark-Water") would find nothing.
        let query = TitleDisplay.plain(title).replacingOccurrences(of: "-", with: " ")
        let results = try await TheSessionAPI.search(query)
        let hits = results.filter { !wanted.isDisjoint(with: TitleMatching.variants(of: $0.name)) }
            .filter { !$0.type.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let best = hits.max(by: { $0.tunebooks < $1.tunebooks }) else { return nil }
        let types = Set(hits.map { $0.type.lowercased() })
        return Match(type: best.type.trimmingCharacters(in: .whitespaces).lowercased(),
                     sessionName: best.name, byLink: false, ambiguous: types.count > 1)
    }
}

public struct SessionTypeLookupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    struct Proposal: Identifiable {
        let id: PersistentIdentifier
        let tune: Tune
        let match: SessionTypes.Match
        /// What each version's type was before Set, for Undo. Empty until set.
        var before: [(tune: Tune, type: String)] = []
        var isSet: Bool { !before.isEmpty }
    }

    enum Stage: Equatable {
        case starting
        case looking(done: Int, of: Int)
        case ready
        case failed(String)
    }

    @State private var stage: Stage = .starting
    @State private var proposals: [Proposal] = []
    @State private var notFound: [String] = []

    public init() {}

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Types from The Session")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
        // Cancelled by SwiftUI if the sheet closes halfway.
        .task { if stage == .starting { await lookUp() } }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .starting, .looking:
            VStack(spacing: 14) {
                if case .looking(let done, let total) = stage {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    Text("Looking up \(done) of \(total) on thesession.org…")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                Text("One tune at a time, so as not to overload the site. Nothing changes until you choose.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let why):
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                Text(why).multilineTextAlignment(.center)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            results
        }
    }

    private var setCount: Int { proposals.filter(\.isSet).count }

    private var results: some View {
        Form {
            if proposals.isEmpty && notFound.isEmpty {
                Section { Label("Every tune has a type.", systemImage: "checkmark.circle") }
            }
            if !proposals.isEmpty {
                Section {
                    ForEach($proposals) { $proposal in
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(TitleDisplay.spoken(proposal.tune.title))
                                Text(describe(proposal.match))
                                    .font(.caption)
                                    .foregroundStyle(proposal.match.ambiguous ? .orange : .secondary)
                            }
                            Spacer(minLength: 8)
                            if proposal.isSet {
                                Label(proposal.match.type.capitalized, systemImage: "checkmark")
                                    .font(.callout)
                                    .foregroundStyle(.green)
                                Button("Undo") { undo($proposal) }
                                    .buttonStyle(.borderless)
                            } else {
                                Button("Set \(proposal.match.type.capitalized)") { set($proposal) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                } header: {
                    Text("Found: \(proposals.count) · set: \(setCount)")
                } footer: {
                    Text("Each Set button sets that one tune and takes it out of \u{201C}\(UntypedTunes.collectionName)\u{201D}. A tune found only by its name could be a different tune of the same name; orange ones especially.")
                }
            }
            if !notFound.isEmpty {
                Section {
                    ForEach(notFound, id: \.self) { Text($0).foregroundStyle(.secondary) }
                } header: {
                    Text("Not found: \(notFound.count)")
                } footer: {
                    Text("No tune of exactly this name on The Session. These stay in \u{201C}\(UntypedTunes.collectionName)\u{201D} for you to type yourself.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func describe(_ match: SessionTypes.Match) -> String {
        let type = match.type.capitalized
        if match.byLink { return "\(type), from its thesession.org link" }
        if match.ambiguous {
            return "\(type)? The Session has several tunes called \u{201C}\(match.sessionName)\u{201D}; this is the best known"
        }
        return "\(type), as \u{201C}\(match.sessionName)\u{201D} on The Session"
    }

    @MainActor
    private func lookUp() async {
        let all = (try? context.fetch(FetchDescriptor<Tune>())) ?? []
        let untyped = all
            .filter { $0.isDefaultVersion && $0.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { TitleDisplay.precedes($0.title, $1.title) }
        guard !untyped.isEmpty else { stage = .ready; return }
        var found: [Proposal] = []
        var missing: [String] = []
        var failures = 0
        for (index, tune) in untyped.enumerated() {
            if Task.isCancelled { return }
            stage = .looking(done: index, of: untyped.count)
            do {
                if let match = try await SessionTypes.match(title: tune.title, aliases: tune.aliases,
                                                            sessionID: SessionTypes.sessionID(of: tune)) {
                    found.append(Proposal(id: tune.persistentModelID, tune: tune, match: match))
                } else {
                    missing.append(TitleDisplay.spoken(tune.title))
                }
            } catch {
                if Task.isCancelled { return }
                failures += 1
                missing.append(TitleDisplay.spoken(tune.title))
                // Five failures before a single success: the site, or the
                // connection, isn't there. Say so rather than grind on.
                if failures >= 5 && found.isEmpty {
                    stage = .failed("Couldn't reach thesession.org: \(error.localizedDescription)")
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        proposals = found
        notFound = missing
        stage = .ready
    }

    /// Every version of a tune, so the type is the same whichever is shown.
    private func versions(of tune: Tune, in all: [Tune]) -> [Tune] {
        guard let group = tune.groupID else { return [tune] }
        let members = all.filter { $0.groupID == group }
        return members.isEmpty ? [tune] : members
    }

    /// Sets one tune (all its versions without a type), at once.
    private func set(_ proposal: Binding<Proposal>) {
        let all = (try? context.fetch(FetchDescriptor<Tune>())) ?? []
        var before: [(tune: Tune, type: String)] = []
        for version in versions(of: proposal.wrappedValue.tune, in: all)
        where version.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            before.append((tune: version, type: version.type))
            version.type = proposal.wrappedValue.match.type
            version.updatedAt = Date()
        }
        guard !before.isEmpty else { return }
        try? context.save()
        UntypedTunes.release(before.map { $0.tune })
        proposal.wrappedValue.before = before
    }

    /// Puts that tune's type back. It doesn't go back into the collection by
    /// itself: Gather Tunes with No Type does that.
    private func undo(_ proposal: Binding<Proposal>) {
        for item in proposal.wrappedValue.before {
            item.tune.type = item.type
            item.tune.updatedAt = Date()
        }
        try? context.save()
        proposal.wrappedValue.before = []
    }
}
