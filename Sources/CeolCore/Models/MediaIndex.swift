import Foundation

/// What each version group has attached, worked out once for a whole library.
///
/// Attachments hang off a single `Tune` record, but a recording is of the
/// *tune*, not of one setting of it — so "has a recording" has to be answered
/// for the group, not the row. The detail screens do that with
/// `VersionTools.mediaAcrossGroup`, which fetches.
///
/// A filter cannot. It runs across 1,500 tunes on every keystroke, and a fetch
/// per tune would be 1,500 queries per letter typed. So this builds the answer
/// in one pass over the tunes the list already holds in memory, and every
/// lookup afterwards is a dictionary hit.
///
/// This is why a tune with plenty of audio did not match "Has a recording":
/// the recording was on a sibling version, and the filter was asking the wrong
/// record.
public struct MediaIndex: Sendable {

    /// groupID → every kind of attachment anywhere in that group.
    private let byGroup: [String: Set<MediaKind>]
    /// Tunes with no groupID are their own group of one, keyed by identity.
    private let ungrouped: [ObjectIdentifier: Set<MediaKind>]

    public init(_ tunes: [Tune]) {
        var byGroup: [String: Set<MediaKind>] = [:]
        var ungrouped: [ObjectIdentifier: Set<MediaKind>] = [:]
        for tune in tunes {
            let kinds = Set((tune.media ?? []).map(\.kind))
            guard !kinds.isEmpty else { continue }
            if let group = tune.groupID {
                byGroup[group, default: []].formUnion(kinds)
            } else {
                ungrouped[ObjectIdentifier(tune)] = kinds
            }
        }
        self.byGroup = byGroup
        self.ungrouped = ungrouped
    }

    /// Everything attached anywhere in this tune's group.
    public func kinds(for tune: Tune) -> Set<MediaKind> {
        if let group = tune.groupID { return byGroup[group] ?? [] }
        return ungrouped[ObjectIdentifier(tune)] ?? []
    }

    public func hasAnything(_ tune: Tune) -> Bool { !kinds(for: tune).isEmpty }

    public func has(_ wanted: Set<MediaKind>, _ tune: Tune) -> Bool {
        !kinds(for: tune).isDisjoint(with: wanted)
    }
}
