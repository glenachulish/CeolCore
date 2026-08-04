import Foundation
import Vision
import ImageIO
import CoreGraphics

/// Reading the title off a photograph of sheet music.
///
/// Worth being clear about what this does and doesn't do: it reads the *words*
/// at the top of the page, not the notes. There is no notation recognition
/// here and none on the Pi either — a photographed tune is stored as a picture
/// with a title, and the title is what makes it findable. That is the whole
/// job, and Vision does it well because a tune title is large, horizontal and
/// near the top.
public enum SheetPhotoTitles {

    /// Read a likely title from an image. Nil when nothing convincing is found,
    /// so the caller can fall back to the filename rather than invent one.
    public static func title(from url: URL) async -> String? {
        // ImageIO rather than UIImage: this is the only line that was
        // iOS-only, and Vision itself is on both platforms. A Mac is where
        // you scan a page of printed music, so it would have been an odd
        // thing to leave behind.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return await title(from: cgImage)
    }

    public static func title(from cgImage: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let found = (request.results as? [VNRecognizedTextObservation]) ?? []
                continuation.resume(returning: bestTitle(from: found))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false   // tune names aren't dictionary words
            // Only the top third: below that is the music, and any words there
            // are chord symbols and lyrics.
            request.regionOfInterest = CGRect(x: 0, y: 0.66, width: 1, height: 0.34)

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([
                        
                        
                        request])
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Of everything read near the top, the title is the widest line that
    /// isn't one of the ABC header scraps a printed tune carries — "Reel",
    /// "D Major", "X:1" and the like are labels, not names.
    private static func bestTitle(from observations: [VNRecognizedTextObservation]) -> String? {
        let lines: [(text: String, width: CGFloat, top: CGFloat)] = observations.compactMap {
            guard let candidate = $0.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 3 else { return nil }
            return (text, $0.boundingBox.width, $0.boundingBox.maxY)
        }
        let usable = lines.filter { !isLabel($0.text) }
        guard !usable.isEmpty else { return nil }

        // Widest wins; ties go to whichever sits higher on the page.
        let best = usable.max { a, b in
            a.width == b.width ? a.top < b.top : a.width < b.width
        }
        return best.map { tidy($0.text) }
    }

    private static let labelPatterns = [
        "^[A-Za-z]:",                                   // an ABC header line
        "^(reel|jig|slip jig|hornpipe|polka|slide|waltz|march|strathspey|air|barn ?dance|mazurka|schottische)s?$",
        "^[A-G][#b]?\\s*(major|minor|maj|min|dorian|mixolydian|dor|mix)?$",
        "^(page|p\\.?)\\s*\\d+$",
        "^\\d+$",
        "^(trad|traditional|arr\\.?|composed|copyright|©).*",
    ]

    private static func isLabel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return labelPatterns.contains {
            trimmed.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Photographs pick up stray marks at the ends of a line.
    private static func tidy(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.-–—_*|"))
    }

    /// Read as many as are wanted, a few at a time so a folder of thirty
    /// photographs doesn't stall the screen.
    public static func titles(for urls: [URL],
                       progress: @escaping (Int, Int) -> Void) async -> [URL: String] {
        var found: [URL: String] = [:]
        for (index, url) in urls.enumerated() {
            let scoped = url.startAccessingSecurityScopedResource()
            if let title = await title(from: url), !title.isEmpty {
                found[url] = title
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
            let done = index + 1
            await MainActor.run { progress(done, urls.count) }
        }
        return found
    }
}
