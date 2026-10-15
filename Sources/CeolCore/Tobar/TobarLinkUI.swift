//  TobarLinkUI.swift
//  CeolCore
//
//  The small amount of SwiftUI both apps need for "Open in Tobar": opening the
//  link, and the "Tobar isn't on this device" dialog when nothing answers.
//  Here so the iPhone and the Mac say exactly the same thing.

import SwiftUI

public extension OpenURLAction {
    /// Open a Tobar an Dualchais track in Tobar. If Tobar isn't installed the
    /// system refuses the link, and `missing` is called with the track page so
    /// the caller can show `tobarMissingDialog`.
    func openInTobar(link: String, title: String, missing: @escaping (String) -> Void) {
        guard let url = TobarLink.openInTobarURL(link: link, title: title) else {
            missing(link)
            return
        }
        self(url) { accepted in
            if !accepted { missing(link) }
        }
    }
}

public extension View {
    /// "Tobar isn't on this device": the App Store, the page in the browser,
    /// or cancel. Shown while `link` holds the track page whose "Open in
    /// Tobar" found nothing to open it.
    func tobarMissingDialog(_ link: Binding<String?>) -> some View {
        modifier(TobarMissingDialog(link: link))
    }
}

private struct TobarMissingDialog: ViewModifier {
    @Binding var link: String?
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Tobar isn't on this device",
            isPresented: Binding(get: { link != nil }, set: { if !$0 { link = nil } }),
            titleVisibility: .visible,
            presenting: link
        ) { page in
            if let store = TobarLink.appStoreURL {
                Button("Get Tobar on the App Store") {
                    openURL(store)
                    link = nil
                }
            }
            Button("Open the page in the browser") {
                if let web = TobarLink.webURL(for: page) { openURL(web) }
                link = nil
            }
            Button("Cancel", role: .cancel) { link = nil }
        } message: { _ in
            Text("Tobar keeps your Tobar an Dualchais bookmarks. You can also listen on the archive's own website.")
        }
    }
}
