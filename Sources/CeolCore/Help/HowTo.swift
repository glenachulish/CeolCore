import Foundation
import SwiftUI

// FONN-HOWTO-1

/// The how-to videos, on Callum's YouTube channel.
///
/// Fonn is a lot of app, and some of it is best shown rather than written
/// down. These are the core tasks, each one a video. Where a video lives is
/// kept two ways:
/// - `builtIn`, in the app: the videos that exist when a version ships.
/// - `listURL`, a small JSON file online, read at most every few hours, so a
///   new or replaced video reaches everyone without a new app version:
///
///       { "channel": "https://www.youtube.com/@…",
///         "videos": { "playing": "https://youtu.be/…", "metronome": "…" } }
///
///   Its entries win over the built-in ones; an empty string hides a video.
///
/// A topic with no video is not shown at all, and with none anywhere the
/// "How-to videos" entries disappear — so a version can ship before the
/// videos are made, without an empty screen in it.
public enum HowToTopic: String, CaseIterable, Identifiable, Sendable {
    case playing
    case appleMusic = "applemusic"
    case sets
    case collections
    case ratings
    case filters
    case marking
    case metronome
    case sound

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .playing:     return "Playing a tune: learning and looping"
        case .appleMusic:  return "Apple Music under the sheet music"
        case .sets:        return "Building sets"
        case .collections: return "Collections"
        case .ratings:     return "Star ratings, the hitlist and favourites"
        case .filters:     return "Filtering the library and Open here"
        case .marking:     return "Marking the music"
        case .metronome:   return "The metronome"
        case .sound:       return "Accompaniment, instruments and drones"
        }
    }

    public var summary: String {
        switch self {
        case .playing:     return "Play, slow down, loop a few bars, and learn it phrase by phrase."
        case .appleMusic:  return "Add a track and play it under the music, with an A–B loop."
        case .sets:        return "Put tunes together, in order, and play them through."
        case .collections: return "Group tunes for a session, a class or a book, and share them."
        case .ratings:     return "How the stars, the hitlist and favourites help you practise."
        case .filters:     return "Narrow the library down, and make Fonn open where you want."
        case .marking:     return "Highlight, write and draw on the music, and on PDFs."
        case .metronome:   return "The click, its tempo and beat, and matching it to a recording."
        case .sound:       return "Choose the instrument, the backing and a drone."
        }
    }

    public var systemImage: String {
        switch self {
        case .playing:     return "play.circle"
        case .appleMusic:  return "music.note"
        case .sets:        return "list.number"
        case .collections: return "folder"
        case .ratings:     return "star"
        case .filters:     return "line.3.horizontal.decrease.circle"
        case .marking:     return "highlighter"
        case .metronome:   return "metronome"
        case .sound:       return "speaker.wave.2"
        }
    }
}

@MainActor
public final class HowToVideos: ObservableObject {
    public static let shared = HowToVideos()

    /// The online list: `_data/howto.json` in the public fonn-docs repository,
    /// which also drives the site's How-to page (glenachulish.github.io/
    /// fonn-docs/howto). Edit it on GitHub and every copy of Fonn has the
    /// new link within a few hours.
    public static let listURL = URL(string: "https://raw.githubusercontent.com/glenachulish/fonn-docs/main/_data/howto.json")

    /// Videos that exist when this version ships, by topic.
    private static let builtIn: [HowToTopic: String] = [:]
    /// The channel, for "All the videos".
    private static let builtInChannel: String? = nil

    @Published public private(set) var links: [HowToTopic: URL] = [:]
    @Published public private(set) var channel: URL?

    private static let cacheKey = "ceol.howto.list"
    private static let fetchedKey = "ceol.howto.fetched"
    private static let refreshEvery: TimeInterval = 6 * 60 * 60

    private init() {
        rebuild(from: UserDefaults.standard.data(forKey: Self.cacheKey))
    }

    /// Topics with a video, in the order above.
    public var available: [HowToTopic] {
        HowToTopic.allCases.filter { links[$0] != nil }
    }

    /// Whether there is anything to show.
    public var hasAny: Bool { !links.isEmpty || channel != nil }

    public func url(for topic: HowToTopic) -> URL? { links[topic] }

    /// Read the online list, if there is one and it hasn't been read lately.
    public func refresh(force: Bool = false) async {
        guard let listURL = Self.listURL else { return }
        let last = UserDefaults.standard.double(forKey: Self.fetchedKey)
        // FONN-HOWTO-3: while there is nothing to show, look every launch, so
        // the first videos appear the next time Fonn opens, not hours later.
        if !force, hasAny, Date().timeIntervalSince1970 - last < Self.refreshEvery { return }
        var request = URLRequest(url: listURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.fetchedKey)
        rebuild(from: data)
    }

    private func rebuild(from data: Data?) {
        var strings: [HowToTopic: String] = Self.builtIn
        var channelString = Self.builtInChannel
        if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let videos = json["videos"] as? [String: String] {
                for (key, value) in videos {
                    guard let topic = HowToTopic(rawValue: key) else { continue }
                    strings[topic] = value
                }
            }
            if let value = json["channel"] as? String { channelString = value }
        }
        var built: [HowToTopic: URL] = [:]
        for (topic, string) in strings {
            if let url = Self.webURL(string) { built[topic] = url }
        }
        links = built
        channel = channelString.flatMap(Self.webURL)
    }

    /// Only http(s) links: the list is read from the internet, and nothing in
    /// it should be able to open anything else.
    private static func webURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }
}

/// Every how-to video, as a list. iPhone and iPad: Settings ▸ How-to videos.
public struct HowToList: View {
    @ObservedObject private var videos = HowToVideos.shared
    @Environment(\.openURL) private var openURL

    public init() {}

    public var body: some View {
        List {
            Section {
                ForEach(videos.available) { topic in
                    Button {
                        if let url = videos.url(for: topic) { openURL(url) }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: topic.systemImage)
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(topic.title).foregroundStyle(.primary)
                                Text(topic.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "play.rectangle")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("The videos are on YouTube and open there.")
            }
            if let channel = videos.channel {
                Section {
                    Button {
                        openURL(channel)
                    } label: {
                        Label("All the videos on YouTube", systemImage: "play.rectangle.on.rectangle")
                    }
                }
            }
        }
        .navigationTitle("How-to videos")
        .task { await videos.refresh() }
    }
}

/// "Watch how" for one topic, beside the controls it is about. Nothing at
/// all when there is no video for it yet.
public struct HowToLink: View {
    let topic: HowToTopic
    @ObservedObject private var videos = HowToVideos.shared
    @Environment(\.openURL) private var openURL

    public init(_ topic: HowToTopic) {
        self.topic = topic
    }

    public var body: some View {
        if let url = videos.url(for: topic) {
            Button {
                openURL(url)
            } label: {
                Label("Watch how", systemImage: "play.rectangle")
                    .font(.footnote)
            }
            .buttonStyle(.borderless)
            .help("A how-to video on YouTube: \(topic.title)")
        }
    }
}
