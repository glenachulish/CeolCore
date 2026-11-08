import Foundation

// FONN-ARRANGE-1
/// The order attachments are shown in, once you have arranged them.
///
/// Unarranged attachments all have `position` 0 and keep the order each screen
/// always used (newest first on the media page, recordings before videos
/// before links under the music). Arranging numbers every attachment from 1,
/// so from then on your order wins everywhere; one added afterwards has 0 and
/// so appears first, where you will see it, until you arrange again.
extension MediaItem {

    /// For lists of everything attached: your order, then newest first.
    public static func arranged(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted { a, b in
            if a.position != b.position { return a.position < b.position }
            return a.createdAt > b.createdAt
        }
    }

    /// Number the attachments in the order given, from 1.
    public static func keepOrder(_ items: [MediaItem]) {
        for (index, item) in items.enumerated() where item.position != index + 1 {
            item.position = index + 1
        }
    }
}
