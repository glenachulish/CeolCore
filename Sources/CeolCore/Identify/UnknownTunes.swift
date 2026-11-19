import Foundation
import SwiftUI
import SwiftData
import AVFoundation
// @Published and ObservableObject are Combine's (Member Import Visibility).
import Combine

// FONN-UNKNOWN-1
// A tune you don't know, heard at a session: record it, and it goes into the
// library as "Unknown Tune 1" (or the lowest number not in use) with the
// recording attached. Later, ask FolkFriend what it is, or a friend, then
// choose the ABC (thesession.org, or pasted) and the placeholder becomes that
// tune — title, type, key and music — with the recording kept.
//
// No new model: an unknown tune is an ordinary Tune whose title is
// "Unknown Tune <n>". Renaming it by hand makes it an ordinary tune.

public enum UnknownTunes {
    public static let prefix = "Unknown Tune"
    public static let folkFriend = URL(string: "https://folkfriend.app")!

    /// 3 for "Unknown Tune 3"; nil for any other title.
    public static func number(of title: String) -> Int? {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard t.lowercased().hasPrefix(prefix.lowercased() + " ") else { return nil }
        let rest = t.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, rest.allSatisfy(\.isNumber) else { return nil }
        return Int(rest)
    }

    public static func isUnknown(_ tune: Tune) -> Bool { number(of: tune.title) != nil }

    /// The lowest number not already taken, so deleting Unknown Tune 2 makes
    /// 2 free again.
    public static func nextTitle(in context: ModelContext) -> String {
        let used = Set(((try? context.fetch(FetchDescriptor<Tune>())) ?? []).compactMap { number(of: $0.title) })
        var n = 1
        while used.contains(n) { n += 1 }
        return "\(prefix) \(n)"
    }

    /// Make the placeholder tune with its recording. Nil when the free
    /// version's allowance is used up.
    @MainActor
    public static func make(recording filename: String, in context: ModelContext) -> Tune? {
        guard TuneAllowance.shared.admit() else { return nil }
        let when = Date.now.formatted(date: .abbreviated, time: .shortened)
        let tune = Tune(title: nextTitle(in: context))
        tune.notes = "Recorded at a session, \(when)."
        context.insert(tune)
        let item = MediaItem(kind: .audio, title: "Session recording, \(when)", filename: filename)
        context.insert(item)
        item.tune = tune
        try? context.save()
        return tune
    }

    /// The recordings attached to this tune, for sending to FolkFriend or a
    /// friend.
    public static func recordingURLs(of tune: Tune) -> [URL] {
        (tune.media ?? [])
            .filter { $0.kind == .audio && !$0.filename.isEmpty && MediaStore.shared.exists($0.filename) }
            .sorted { $0.createdAt < $1.createdAt }
            .map { MediaStore.shared.url(for: $0.filename) }
    }

    // MARK: - Choosing what it is

    /// The placeholder becomes this setting from thesession.org.
    public static func adopt(_ tune: Tune, detail: TheSessionAPI.TuneDetail,
                             setting: TheSessionAPI.Setting, in context: ModelContext) {
        let was = tune.title
        tune.title = detail.name
        tune.type = detail.type
        tune.key = setting.key
        tune.mode = setting.mode
        tune.abc = setting.abc
        tune.aliases = detail.aliases
        tune.theSessionID = detail.id
        tune.theSessionSettingID = String(setting.id)
        tune.sourceURL = "https://thesession.org/tunes/\(detail.id)"
        tune.transcribedBy = setting.member
        note(tune, "Was \(was). Music from thesession.org, setting \(setting.index).")
        try? context.save()
    }

    /// The placeholder becomes this ABC. A title-less ABC leaves the name as
    /// it is, so the tune stays unknown until you name it.
    public static func adopt(_ tune: Tune, abc: String, in context: ModelContext) {
        let parsed = ABCParser.parse(abc)
        let was = tune.title
        if !parsed.title.isEmpty && parsed.title != "Untitled" { tune.title = parsed.title }
        if !parsed.type.isEmpty { tune.type = parsed.type }
        if !parsed.key.isEmpty { tune.key = parsed.key; tune.mode = parsed.mode }
        if !parsed.composer.isEmpty { tune.composer = parsed.composer }
        if !parsed.aliases.isEmpty { tune.aliases = parsed.aliases }
        tune.abc = parsed.abc
        note(tune, "Was \(was). Music pasted as ABC.")
        try? context.save()
    }

    /// The tune is already in the library: give it the recordings, and leave
    /// the placeholder empty for `removeLater`.
    public static func moveRecordings(from unknown: Tune, to existing: Tune, in context: ModelContext) {
        for item in unknown.media ?? [] { item.tune = existing }
        note(existing, "Session recording added from \(unknown.title).")
        try? context.save()
    }

    /// Delete the emptied placeholder once whatever was showing it has gone:
    /// deleting a record still on screen is a crash, not an error.
    @MainActor
    public static func removeLater(_ tune: Tune, in context: ModelContext) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard isUnknown(tune), (tune.media ?? []).isEmpty else { return }
            context.delete(tune)
            try? context.save()
        }
    }

    /// "thesession.org/tunes/27#setting27" → (27, 27); "…/tunes/27" → (27, nil).
    public static func sessionLink(in text: String) -> (tune: Int, setting: Int?)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.lowercased().contains("thesession.org/tunes/"),
              let range = s.range(of: #"tunes/(\d+)"#, options: .regularExpression) else { return nil }
        let idText = s[range].dropFirst("tunes/".count)
        guard let id = Int(idText) else { return nil }
        var setting: Int?
        if let r = s.range(of: #"setting(\d+)"#, options: .regularExpression) {
            setting = Int(s[r].dropFirst("setting".count))
        }
        return (id, setting)
    }

    private static func note(_ tune: Tune, _ line: String) {
        let stamp = Date.now.formatted(date: .abbreviated, time: .omitted)
        let entry = "\(line) (\(stamp))"
        tune.notes = tune.notes.isEmpty ? entry : tune.notes + "\n" + entry
    }
}

// MARK: - Recording

/// Records from the microphone into the media store. The iPhone keeps
/// recording with the screen locked (the app already has background audio)
/// and the screen is kept awake while it records.
@MainActor
public final class SessionRecorder: NSObject, ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var level: Float = 0
    @Published public var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var tempURL: URL?

    public override init() { super.init() }

    /// Told when recording starts and stops. The phone app keeps the screen
    /// awake with it: `UIApplication.shared` can't be named here, because
    /// CeolCore is linked into the share extension too.
    @MainActor public static var recordingChanged: ((Bool) -> Void)?

    public func start() {
        requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else { self.permissionDenied = true; return }
            self.begin()
        }
    }

    private func requestPermission(_ done: @escaping (Bool) -> Void) {
        #if os(iOS)
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { done(granted) }
        }
        #else
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { done(granted) }
        }
        #endif
    }

    private func begin() {
        // Whatever was playing stops: one player at a time, and a recording
        // of the session shouldn't have Fonn's flute on it.
        // Same name both apps give it (SetSheetView, AppleMusicStrip).
        NotificationCenter.default.post(name: Notification.Name("ceolStopAllPlayback"), object: nil)
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
        SessionRecorder.recordingChanged?(true)
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            guard rec.record() else { finishSession(); return }
            recorder = rec
            tempURL = url
            isRecording = true
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            finishSession()
        }
    }

    private func tick() {
        guard let rec = recorder, rec.isRecording else { return }
        rec.updateMeters()
        elapsed = rec.currentTime
        level = max(0, min(1, (rec.averagePower(forChannel: 0) + 60) / 60))
    }

    /// Stop and file the recording in the media store; its filename.
    public func stopAndSave() -> String? {
        stopRecorder()
        defer { recorder = nil; finishSession() }
        guard let url = tempURL, let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return try? MediaStore.shared.save(data, extension: "m4a")
    }

    public func cancel() {
        stopRecorder()
        if let url = tempURL { try? FileManager.default.removeItem(at: url) }
        recorder = nil
        finishSession()
    }

    private func stopRecorder() {
        timer?.invalidate(); timer = nil
        recorder?.stop()
        isRecording = false
        level = 0
    }

    private func finishSession() {
        SessionRecorder.recordingChanged?(false)
        // The phone app hands the audio session back to playback when the
        // sheet closes (AudioSession.shared.refresh, in its onDismiss).
    }
}

/// Record a tune you don't know. Saves it as the next "Unknown Tune n".
public struct RecordUnknownTuneSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = SessionRecorder()
    @State private var name = ""
    @State private var overLimit = false
    let onSaved: (Tune) -> Void

    public init(onSaved: @escaping (Tune) -> Void) { self.onSaved = onSaved }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 0)
                Text(name).font(.headline).foregroundStyle(.secondary)
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.15))
                        .frame(width: 150, height: 150)
                        .scaleEffect(1 + CGFloat(recorder.level) * 0.35)
                        .animation(.easeOut(duration: 0.1), value: recorder.level)
                    Image(systemName: recorder.isRecording ? "waveform" : "mic")
                        .font(.system(size: 50))
                        .foregroundStyle(recorder.isRecording ? Color.red : Color.secondary)
                }
                Text(MediaStore.formatDuration(recorder.elapsed))
                    .font(.system(size: 38, weight: .light, design: .rounded))
                    .monospacedDigit()

                if overLimit {
                    Text("The free version of Fonn holds \(TuneAllowance.freeLimit) tunes, so there is no room for another. Unlock the full version in Settings to keep recording new tunes.")
                        .font(.callout).multilineTextAlignment(.center)
                        .foregroundStyle(.secondary).padding(.horizontal)
                } else if recorder.permissionDenied {
                    Text(micOffText)
                        .font(.callout).multilineTextAlignment(.center)
                        .foregroundStyle(.secondary).padding(.horizontal)
                } else {
                    Text(recorder.isRecording
                         ? recordingText
                         : "Start when the tune starts. Stop when it ends, and it goes into your library with the recording, ready to identify later.")
                        .font(.callout).multilineTextAlignment(.center)
                        .foregroundStyle(.secondary).padding(.horizontal)
                }

                Button(action: tapped) {
                    Label(recorder.isRecording ? "Stop and save" : "Start recording",
                          systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : .accentColor)
                .padding(.horizontal, 32)
                .disabled(recorder.permissionDenied || overLimit)
                .keyboardShortcut(.defaultAction)
                Spacer(minLength: 0)
            }
            .padding(.vertical)
            .navigationTitle("Record an Unknown Tune")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { recorder.cancel(); dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
        .interactiveDismissDisabled(recorder.isRecording)
        .onAppear {
            name = UnknownTunes.nextTitle(in: context)
            overLimit = TuneAllowance.shared.isAtLimit
        }
    }

    private var recordingText: String {
        #if os(iOS)
        "Recording. You can lock the phone; it carries on."
        #else
        "Recording."
        #endif
    }

    private var micOffText: String {
        #if os(iOS)
        "Microphone access is off for Fonn. Turn it on in Settings ▸ Privacy & Security ▸ Microphone."
        #else
        "Microphone access is off for Fonn. Turn it on in System Settings ▸ Privacy & Security ▸ Microphone."
        #endif
    }

    private func tapped() {
        guard recorder.isRecording else { recorder.start(); return }
        guard let filename = recorder.stopAndSave() else { dismiss(); return }
        if let tune = UnknownTunes.make(recording: filename, in: context) {
            onSaved(tune)
        } else {
            MediaStore.shared.delete(filename: filename)
        }
        dismiss()
    }
}

// MARK: - Identifying

/// Shown at the top of an unknown tune's page: what it is, and the way to
/// say what it really is.
public struct UnknownTuneBanner: View {
    @Bindable var tune: Tune
    let onMoved: (Tune) -> Void
    @State private var identifying = false

    /// `onMoved` is called when the recording went to a tune already in the
    /// library: show that tune, so the empty placeholder can be removed.
    public init(tune: Tune, onMoved: @escaping (Tune) -> Void) {
        self.tune = tune
        self.onMoved = onMoved
    }

    public var body: some View {
        if UnknownTunes.isUnknown(tune) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not identified yet").font(.subheadline.weight(.semibold))
                    Text("Ask FolkFriend or a friend what it is, then choose the music.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Identify\u{2026}") { identifying = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
            .sheet(isPresented: $identifying) {
                IdentifyTuneSheet(tune: tune, onMoved: onMoved)
            }
        }
    }
}

/// Send the recording to FolkFriend or a friend, then choose the music:
/// search thesession.org, paste a thesession.org link or ABC, or pick a tune
/// already in the library.
public struct IdentifyTuneSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var tune: Tune
    let onMoved: (Tune) -> Void

    @Query(filter: #Predicate<Tune> { $0.isDefaultVersion }) private var library: [Tune]

    @State private var search = ""
    @State private var results: [TheSessionAPI.SearchResult] = []
    @State private var searching = false
    @State private var detail: TheSessionAPI.TuneDetail?
    @State private var loadingDetail = false
    @State private var pasted = ""
    @State private var problem: String?
    @State private var opened: OpenedLink?
    @State private var alreadyHave: AlreadyHave?

    private struct AlreadyHave: Identifiable {
        let existing: Tune
        let detail: TheSessionAPI.TuneDetail?
        let setting: TheSessionAPI.Setting?
        let abc: String?
        var id: ObjectIdentifier { ObjectIdentifier(existing) }
    }

    public init(tune: Tune, onMoved: @escaping (Tune) -> Void) {
        self.tune = tune
        self.onMoved = onMoved
    }

    public var body: some View {
        NavigationStack {
            Form {
                askSection
                if let detail { settingsSection(detail) } else { chooseSection }
                if detail == nil, !libraryMatches.isEmpty { librarySection }
                if let problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Identify \(tune.title)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(detail == nil ? "Close" : "Back") {
                        if detail == nil { dismiss() } else { detail = nil }
                    }
                }
            }
            .opensResourceLinks($opened)
            .confirmationDialog(
                "“\(TitleDisplay.spoken(alreadyHave?.existing.title ?? ""))” is already in your library",
                isPresented: Binding(get: { alreadyHave != nil }, set: { if !$0 { alreadyHave = nil } }),
                titleVisibility: .visible,
                presenting: alreadyHave
            ) { have in
                Button("Add the Recording to It") { moveTo(have.existing) }
                Button("Keep as a Separate Tune") { adoptAnyway(have) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The recording can join the tune you already have, and \(tune.title) goes.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }

    // MARK: Sections

    private var askSection: some View {
        Section {
            Button { opened = OpenedLink(url: UnknownTunes.folkFriend) } label: {
                Label("Open FolkFriend", systemImage: "ear")
            }
            let recordings = UnknownTunes.recordingURLs(of: tune)
            if !recordings.isEmpty {
                ShareLink(items: recordings) {
                    Label(recordings.count == 1 ? "Send the Recording…" : "Send the Recordings…",
                          systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("1 · Find out what it is")
        } footer: {
            Text("FolkFriend listens to a tune and suggests matches from thesession.org. Play the recording to it from another phone or speaker, or give it the file if it offers to open one (Send the Recording ▸ Save to Files). Or send the recording to a friend who might know it.")
        }
    }

    private var chooseSection: some View {
        Section {
            HStack {
                TextField("Name of the tune", text: $search)
                    .onSubmit { Task { await runSearch() } }
                    #if os(iOS)
                    .submitLabel(.search)
                    #endif
                if searching {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Search") { Task { await runSearch() } }
                        .disabled(search.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            ForEach(results) { result in
                Button { Task { await load(result.id, setting: nil) } } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(TitleDisplay.spoken(result.name)).foregroundStyle(.primary)
                            Text([result.type.capitalized,
                                  result.tunebooks > 0 ? "in \(result.tunebooks) tunebooks" : ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if loadingDetail { ProgressView("Getting the settings…") }

            VStack(alignment: .leading, spacing: 6) {
                Text("Or paste a thesession.org link (FolkFriend gives these) or ABC:")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $pasted)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 70)
                HStack {
                    #if os(iOS)
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in pasted = strings.joined(separator: "\n") }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    #endif
                    Spacer()
                    Button("Use This") { Task { await usePasted() } }
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } header: {
            Text("2 · Choose the music")
        }
    }

    private func settingsSection(_ detail: TheSessionAPI.TuneDetail) -> some View {
        Section {
            ForEach(detail.settings) { setting in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Setting \(setting.index) · \(setting.displayKey)").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Use This") { use(detail, setting) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    Text([setting.member.isEmpty ? "" : "by \(setting.member)",
                          setting.votes > 0 ? "\(setting.votes) votes" : ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(firstBars(setting.abc))
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("\(TitleDisplay.spoken(detail.name)) · \(detail.type.capitalized)")
        } footer: {
            Text("Pick the setting nearest to what was played. The others can be added later as versions from thesession.org.")
        }
    }

    private var librarySection: some View {
        Section("Already in your library") {
            ForEach(libraryMatches) { existing in
                Button { moveTo(existing) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(TitleDisplay.spoken(existing.title)).foregroundStyle(.primary)
                            Text([existing.type.capitalized, existing.key].filter { !$0.isEmpty }
                                .joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Add the Recording").font(.caption).foregroundStyle(.tint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Working

    private var libraryMatches: [Tune] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 3 else { return [] }
        return library
            .filter { $0 !== tune && !UnknownTunes.isUnknown($0) }
            .filter { TitleDisplay.spoken($0.title).localizedCaseInsensitiveContains(needle) }
            .sorted { TitleDisplay.precedes($0.title, $1.title) }
            .prefix(6).map { $0 }
    }

    private func runSearch() async {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        problem = nil
        searching = true
        defer { searching = false }
        do {
            results = try await TheSessionAPI.search(q)
            if results.isEmpty { problem = "Nothing on thesession.org called that. Try fewer words, or another name for it." }
        } catch {
            problem = "Couldn't reach thesession.org: \(error.localizedDescription)"
        }
    }

    private func load(_ id: Int, setting: Int?) async {
        problem = nil
        loadingDetail = true
        defer { loadingDetail = false }
        do {
            let loaded = try await TheSessionAPI.tune(id: id)
            if let setting, let match = loaded.settings.first(where: { $0.id == setting }) {
                use(loaded, match)
            } else {
                detail = loaded
            }
        } catch {
            problem = "Couldn't get that tune from thesession.org: \(error.localizedDescription)"
        }
    }

    private func usePasted() async {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let link = UnknownTunes.sessionLink(in: text) {
            await load(link.tune, setting: link.setting)
        } else if text.range(of: #"(?m)^\s*K:"#, options: .regularExpression) != nil {
            let abc = ABCParser.splitTunes(text).first ?? text
            let parsed = ABCParser.parse(abc)
            if let existing = existingTune(sessionID: nil, title: parsed.title) {
                alreadyHave = AlreadyHave(existing: existing, detail: nil, setting: nil, abc: abc)
            } else {
                UnknownTunes.adopt(tune, abc: abc, in: context)
                dismiss()
            }
        } else if !text.contains("\n"), text.count < 80 {
            search = text
            await runSearch()
        } else {
            problem = "That isn't a thesession.org link or ABC. ABC needs at least a K: line."
        }
    }

    private func use(_ detail: TheSessionAPI.TuneDetail, _ setting: TheSessionAPI.Setting) {
        if let existing = existingTune(sessionID: detail.id, title: detail.name) {
            alreadyHave = AlreadyHave(existing: existing, detail: detail, setting: setting, abc: nil)
            return
        }
        UnknownTunes.adopt(tune, detail: detail, setting: setting, in: context)
        dismiss()
    }

    private func adoptAnyway(_ have: AlreadyHave) {
        if let d = have.detail, let s = have.setting {
            UnknownTunes.adopt(tune, detail: d, setting: s, in: context)
        } else if let abc = have.abc {
            UnknownTunes.adopt(tune, abc: abc, in: context)
        }
        dismiss()
    }

    private func moveTo(_ existing: Tune) {
        let placeholder = tune
        UnknownTunes.moveRecordings(from: placeholder, to: existing, in: context)
        dismiss()
        onMoved(existing)
        UnknownTunes.removeLater(placeholder, in: context)
    }

    private func existingTune(sessionID: Int?, title: String) -> Tune? {
        let key = TunesToLearn.key(title)
        return library.first { other in
            guard other !== tune else { return false }
            if let sessionID, other.theSessionID == sessionID { return true }
            return !key.isEmpty && TunesToLearn.key(other.title) == key
        }
    }

    /// The first two lines of music after the K: line, as a reminder of how
    /// the setting starts.
    private func firstBars(_ abc: String) -> String {
        let lines = abc.components(separatedBy: .newlines)
        guard let k = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("K:") }) else { return "" }
        return lines.dropFirst(k + 1).prefix(2).joined(separator: "\n")
    }
}
