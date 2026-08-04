import Foundation
import AVFoundation

/// Files for attached media live in a Media folder. The Pi keeps uploads in
/// its `uploads/` folder and stores a URL; the app equivalent is a file on
/// disk with the name recorded on the MediaItem.
///
/// **Where that folder is, is now the caller's business.** On iOS it is the
/// app's own Documents directory and always has been, so iOS calls nothing and
/// behaves exactly as before. On the Mac that answer is wrong: the container is
/// somewhere the user never sees, and a library opened from a `.ceol.json` on
/// disk keeps its recordings beside that file, not beside the app. Stage 1 of
/// the Mac app rests on media being addressable relative to the library rather
/// than to the app, so the root is settable.
///
/// The `import UIKit` this file used to carry was never used and is gone; it
/// was the only thing stopping it compiling on macOS.
public final class MediaStore {
    public static let shared = MediaStore()

    private init() { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

    /// Set by the Mac app to point at the folder holding the open library.
    /// Nil means "this app's own Documents folder", which is what iOS wants.
    ///
    /// Mutable shared state on a singleton, which Swift 6 will object to. It is
    /// written once at launch and read thereafter; the fix belongs with the
    /// concurrency migration, not here.
    private var overrideRoot: URL? = nil

    /// Point the store at a folder of your choosing. Pass nil to go back to
    /// this app's Documents directory.
    public func setRoot(_ url: URL?) {
        overrideRoot = url
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public var folder: URL {
        (overrideRoot ?? defaultRoot).appendingPathComponent("Media", isDirectory: true)
    }

    public func url(for filename: String) -> URL {
        folder.appendingPathComponent(filename)
    }

    /// Copy data in under a fresh name, returning the stored filename.
    @discardableResult
    public func save(_ data: Data, extension ext: String) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext.lowercased())")
        try data.write(to: url(for: name), options: .atomic)
        return name
    }

    /// Copy a file that is already on disk, without reading it into memory.
    /// The folder import brings several hundred recordings across in one go,
    /// so `Data(contentsOf:)` per file is the wrong tool. Returns the stored
    /// name, or nil if the copy failed.
    @discardableResult
    public func copyIn(from source: URL) -> String? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = source.pathExtension
        let name = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext.lowercased())")
        do {
            try FileManager.default.copyItem(at: source, to: url(for: name))
            return name
        } catch {
            return nil
        }
    }

    /// Copy an existing file (from the Files app or Photos) into the store.
    @discardableResult
    public func importFile(at source: URL) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        return try save(data, extension: source.pathExtension)
    }

    public func delete(filename: String) {
        guard !filename.isEmpty else { return }
        try? FileManager.default.removeItem(at: url(for: filename))
    }

    public func fileSize(_ filename: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url(for: filename).path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    /// Best guess at the kind of media from a file extension.
    public static func kind(forExtension ext: String) -> MediaKind {
        switch ext.lowercased() {
        case "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "ogg": return .audio
        case "mp4", "mov", "m4v", "avi", "mkv", "webm": return .video
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "webp": return .photo
        case "pdf": return .pdf
        default: return .audio
        }
    }

    /// Duration of an audio/video file, for display.
    public func duration(of filename: String) async -> Double? {
        guard !filename.isEmpty else { return nil }
        let asset = AVURLAsset(url: url(for: filename))
        guard let d = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(d)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    public static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    public static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
