import Foundation
import SwiftData

/// Putting recordings back on the tunes they belong to.
///
/// A folder of the Pi's uploads imported through the *media* route rather than
/// the *library* route produces one tune per file, named after the file:
/// `d930bb3233a3418e9a226e7cba062d08`, no notation, one recording attached.
/// Hundreds of them. Deleting them would be easy and wrong — they are holding
/// the only copy of the audio.
///
/// The association is not lost, it is just written down somewhere else. The
/// Pi never stored an original filename for tune audio; what it stored was a
/// line in the *tune's own notes*: `audio: /api/uploads/NAME`. So for every
/// stray, the tune it belongs to is the one whose notes name that file.
///
/// This proposes; it does not act until told to, and it says exactly what it
/// would do first.
public enum MediaRepair {

    public struct Move: Identifiable {
        public let id = UUID()
        /// The tune named after a file, to be emptied and removed.
        public let stray: Tune
        /// Where its recordings should go.
        public let destination: Tune
        public let items: [MediaItem]
        /// The Pi filename that tied them together, for showing your working.
        public let matchedOn: String
    }

    public struct Plan {
        public var moves: [Move] = []
        /// Strays whose file is named in no tune's notes. Left alone: an
        /// orphan you can still play beats one silently deleted.
        public var unmatched: [Tune] = []

        public var isEmpty: Bool { moves.isEmpty && unmatched.isEmpty }
        public var summary: String {
            var parts: [String] = []
            if !moves.isEmpty {
                let files = moves.reduce(0) { $0 + $1.items.count }
                parts.append("\(files) recording\(files == 1 ? "" : "s") back onto \(Set(moves.map(\.destination.persistentModelID)).count) tunes")
                parts.append("\(moves.count) stray record\(moves.count == 1 ? "" : "s") removed")
            }
            if !unmatched.isEmpty { parts.append("\(unmatched.count) left alone (no tune names them)") }
            return parts.isEmpty ? "Nothing to tidy" : parts.joined(separator: ", ")
        }
    }

    /// A title that is really a filename: 32 hex characters, sometimes with an
    /// extension still on it. Deliberately narrow — a tune genuinely called
    /// "Bog An Lochan" must never match, and a short hex-looking title like
    /// "abba" must not either.
    static func looksLikeUploadName(_ title: String) -> Bool {
        let stem = (title as NSString).deletingPathExtension
        guard stem.count == 32 else { return false }
        return stem.allSatisfy { $0.isHexDigit }
    }

    /// Work out what would be moved where, touching nothing.
    public static func plan(in context: ModelContext) -> Plan {
        let all = (try? context.fetch(FetchDescriptor<Tune>())) ?? []

        // Which tune names which upload, from the notes the Pi wrote.
        var owner: [String: Tune] = [:]
        for tune in all where !MediaRepair.looksLikeUploadName(tune.title) {
            for name in LinkedText.uploadedFilenames(in: tune.notes) {
                // First wins: a file named by two tunes is rare and guessing
                // between them is worse than leaving it.
                if owner[name] == nil { owner[name] = tune }
            }
        }

        var plan = Plan()
        for stray in all where looksLikeUploadName(stray.title) && !stray.hasNotation {
            let items = stray.media ?? []
            // The name the file arrived under. BulkImport recorded it as
            // "Imported from NAME"; the tune's own title is the same thing,
            // which is the belt and braces here.
            let candidates = [stray.title] + items.compactMap { item -> String? in
                let prefix = "Imported from "
                guard item.notes.hasPrefix(prefix) else { return nil }
                return String(item.notes.dropFirst(prefix.count))
            }
            guard let name = candidates.first(where: { owner[$0] != nil }),
                  let destination = owner[name] else {
                plan.unmatched.append(stray)
                continue
            }
            plan.moves.append(Move(stray: stray, destination: destination,
                                   items: items, matchedOn: name))
        }
        return plan
    }

    /// Carry out a plan. Only the moves — anything unmatched is left exactly
    /// as it is.
    @discardableResult
    public static func apply(_ plan: Plan, in context: ModelContext) -> Int {
        var moved = 0
        for move in plan.moves {
            for item in move.items {
                // Don't attach a second copy of something already there.
                let already = (move.destination.media ?? []).contains {
                    $0.filename == item.filename && !item.filename.isEmpty
                }
                if already {
                    MediaStore.shared.delete(filename: item.filename)
                    context.delete(item)
                    continue
                }
                item.tune = move.destination
                moved += 1
            }
            move.destination.updatedAt = Date()
            // The stray is now empty, and was never a tune.
            context.delete(move.stray)
        }
        try? context.save()
        return moved
    }
}
