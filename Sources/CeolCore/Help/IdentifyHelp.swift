import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// FONN-IDHELP-1
// Help: identifying an unknown tune with FolkFriend. Reached from the
// Identify sheet ("How to use FolkFriend"), from Settings ▸ Help on the
// phone and from Help ▸ Identifying an Unknown Tune on the Mac.
// Screenshots: Web/help/folkfriend-*.png, trimmed from Callum's own (20 Nov).

public struct IdentifyHelpView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("FolkFriend is a free web app that listens to a tune and suggests what it might be, from thesession.org. There are two ways to give it your recording.")
                    .foregroundStyle(.secondary)

                part("The easy way: two devices")
                step(1, "Open FolkFriend on a second phone, tablet or computer: folkfriend.app. It listens through the microphone to begin with.")
                shot("folkfriend-1-search")
                step(2, "In Fonn, open the unknown tune and play its recording.")
                step(3, "Tap FolkFriend's microphone while the recording plays, with the two devices close together. A few seconds of the tune is enough.")

                part("On one device: give FolkFriend the file")
                step(1, "Make a folder in iCloud Drive called FolkFriend, to keep these recordings together. iPhone or iPad: Files ▸ Browse ▸ iCloud Drive ▸ ⋯ ▸ New Folder. Mac: Finder ▸ iCloud Drive ▸ File ▸ New Folder.")
                step(2, "In Fonn, open the unknown tune, choose Identify…, then Save the Recording to a Folder…, and save it in the FolkFriend folder. It is saved under the tune's name, such as Unknown Tune 1.")
                step(3, "Open folkfriend.app and go to Settings (the ☰ menu, or the cog at the top right).")
                shot("folkfriend-2-settings")
                step(4, "Turn on “Upload file instead of using device microphone”.")
                shot("folkfriend-3-upload-on")
                step(5, "Go back to Search, tap the button that now asks for a file, and choose the recording from your FolkFriend folder.")
                shot("folkfriend-4-choose-file")

                part("Read the results")
                step(1, "FolkFriend lists the tunes it thinks it might be. “Close” is its best guess; “Possible” are others worth a listen.")
                shot("folkfriend-5-results")
                step(2, "Tap a tune to see and hear its music, and check it against your recording.")

                part("Then, in Fonn")
                step(1, "Rename the tune: Identify… ▸ Name. Once it has its proper name it is no longer an unknown tune.")
                step(2, "Add the music, from wherever you like:")
                bullet("From FolkFriend: turn on “Show ABC as text alongside sheet music” in its Settings, copy the ABC, and paste it into Identify… ▸ Choose the music.")
                bullet("From thesession.org: search for the name in Identify… and pick the setting nearest to what was played.")
                bullet("From another source: paste its ABC the same way, or a thesession.org link.")
                Text("The recording stays with the tune. If the tune was already in your library, Fonn offers to add the recording to that one instead.")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Identifying an Unknown Tune")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func part(_ title: String) -> some View {
        Text(title).font(.title3.weight(.semibold)).padding(.top, 6)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.callout.weight(.bold).monospacedDigit())
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 32)
    }

    @ViewBuilder
    private func shot(_ name: String) -> some View {
        if let image = Self.image(name) {
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 520)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.3)))
                .padding(.leading, 32)
                .accessibilityHidden(true)
        }
    }

    /// From the package's Web/help folder (copied as it is, see Package.swift).
    static func image(_ name: String) -> Image? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png",
                                          subdirectory: "Web/help") else { return nil }
        #if canImport(UIKit)
        return UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        return NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #endif
    }
}
