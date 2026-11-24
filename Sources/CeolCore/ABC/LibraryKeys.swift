import SwiftUI
import SwiftData

// FONN-KEYCHECK-1
/// The key and mode a tune is filed under, checked against its own K: line.
///
/// Until FONN-MIXMODE-1, `ABCParser.parseKeyField` read K:Amix as A minor and
/// K:A mix / K:D Dorian as major, so tunes pasted or imported as ABC could be
/// filed in the wrong mode. This finds every tune (every version) whose filed
/// key or mode disagrees with what its ABC now reads as, and puts it right,
/// one tune at a time or all together, each with its own Undo. Only the
/// filed key and mode change; the ABC is not touched.
public enum LibraryKeys {

    /// A mode under one name: "Mix", "mixolydian", "aeolian", "" and so on.
    static func canon(_ mode: String) -> String {
        let m = mode.trimmingCharacters(in: .whitespaces).lowercased()
        let full = ABCParser.parseKeyField("C" + m).mode   // the parser's own prefixes
        switch full {
        case "", "ionian": return "major"
        case "aeolian": return "minor"
        default: return full
        }
    }

    /// The keynote and mode a tune is filed under. Fonn has stored these
    /// three ways: key "A" with mode "minor"; key "A major" with the mode in
    /// the key field and mode empty; and key "Am".
    static func filed(_ tune: Tune) -> (tonic: String, mode: String) {
        let words = tune.key.split(separator: " ").map(String.init)
        guard let first = words.first, !first.isEmpty else { return ("", "") }
        let parsed = ABCParser.parseKeyField(first)
        var mode = tune.mode.trimmingCharacters(in: .whitespaces)
        if mode.isEmpty { mode = words.dropFirst().joined(separator: " ") }
        if mode.isEmpty, first.count > parsed.key.count { mode = parsed.mode }
        return (parsed.key, canon(mode))
    }

    /// What the ABC says, when it gives the same keynote as the tune is filed
    /// under but a different mode. A different keynote is left alone: it can
    /// be deliberate (a transposed version), and it isn't what the parser got
    /// wrong. A tune with no key filed is left too.
    static func correction(for tune: Tune) -> (key: String, mode: String)? {
        guard !tune.abc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let parsed = ABCParser.parse(tune.abc)
        // A to G only: K:HP (bagpipes) and K:none would read as "H" and "N".
        guard let letter = parsed.key.first, "ABCDEFG".contains(letter) else { return nil }
        let have = filed(tune)
        guard !have.tonic.isEmpty, have.tonic.lowercased() == parsed.key.lowercased() else { return nil }
        let want = canon(parsed.mode)
        return have.mode == want ? nil : (parsed.key, want)
    }

    /// The key field after a fix, in the form it was already stored in.
    static func fixedKeyField(_ old: String, tonic: String, mode: String) -> String {
        let words = old.split(separator: " ")
        return words.count > 1 ? "\(words[0]) \(mode)" : old
    }

    static func describe(_ key: String, _ mode: String) -> String {
        let k = key.trimmingCharacters(in: .whitespaces)
        let m = mode.trimmingCharacters(in: .whitespaces)
        if k.isEmpty { return "no key" }
        return m.isEmpty ? k : "\(k) \(m)"
    }
}

public struct LibraryKeyCheckView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    struct Finding: Identifiable {
        let id: PersistentIdentifier
        let tune: Tune
        let newKey: String
        let newMode: String
        /// What was filed before Fix, for Undo. Nil until fixed.
        var before: (key: String, mode: String)? = nil
        var isFixed: Bool { before != nil }
    }

    @State private var findings: [Finding] = []
    @State private var scanned = false

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Finds tunes filed under a different key or mode from the one their own ABC gives, and puts them right. Mixolydian tunes pasted as ABC were filed as minor until this version.")
                    Text("Only the key Fonn files the tune under changes; the music is not touched. Each tune has its own Undo.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                if !scanned {
                    Section { ProgressView() }
                } else if findings.isEmpty {
                    Section { Label("Every tune is filed under the key its ABC gives.", systemImage: "checkmark.circle") }
                } else {
                    Section {
                        let left = findings.filter { !$0.isFixed }.count
                        Button(left == 0 ? "All fixed" : "Fix all \(left)") {
                            for index in findings.indices where !findings[index].isFixed { fix(index) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(left == 0)
                    }
                    Section("Filed under the wrong key: \(findings.count)") {
                        ForEach(findings.indices, id: \.self) { index in
                            row(index)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Check the Keys")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
        .onAppear { if !scanned { scan() } }
    }

    private func row(_ index: Int) -> some View {
        let finding = findings[index]
        let filed = finding.before.map { LibraryKeys.describe($0.key, $0.mode) }
            ?? LibraryKeys.describe(finding.tune.key, finding.tune.mode)
        var title = TitleDisplay.spoken(finding.tune.title)
        if !finding.tune.versionLabel.isEmpty { title += " (\(finding.tune.versionLabel))" }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("Filed as \(filed); its ABC says \(LibraryKeys.describe(finding.newKey, finding.newMode))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if finding.isFixed {
                Label("Fixed", systemImage: "checkmark").font(.callout).foregroundStyle(.green)
                Button("Undo") { undo(index) }.buttonStyle(.borderless)
            } else {
                Button("Fix") { fix(index) }.buttonStyle(.bordered)
            }
        }
    }

    private func scan() {
        let all = (try? context.fetch(FetchDescriptor<Tune>())) ?? []
        findings = all.compactMap { tune -> Finding? in
            guard let fix = LibraryKeys.correction(for: tune) else { return nil }
            return Finding(id: tune.persistentModelID, tune: tune, newKey: fix.key, newMode: fix.mode)
        }
        .sorted { TitleDisplay.precedes($0.tune.title, $1.tune.title) }
        scanned = true
    }

    private func fix(_ index: Int) {
        let tune = findings[index].tune
        findings[index].before = (key: tune.key, mode: tune.mode)
        tune.key = LibraryKeys.fixedKeyField(tune.key, tonic: findings[index].newKey,
                                             mode: findings[index].newMode)
        tune.mode = findings[index].newMode
        tune.updatedAt = Date()
        try? context.save()
    }

    private func undo(_ index: Int) {
        guard let before = findings[index].before else { return }
        let tune = findings[index].tune
        tune.key = before.key
        tune.mode = before.mode
        tune.updatedAt = Date()
        try? context.save()
        findings[index].before = nil
    }
}
