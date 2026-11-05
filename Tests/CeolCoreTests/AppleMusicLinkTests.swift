import Testing
@testable import CeolCore

// FONN-APPLEMUSIC-1
/// Which stored links are Apple Music songs Fonn can play itself.
/// Mirrored by tools/verify_apple_music_link.py. Keep the two in step.
struct AppleMusicLinkTests {

    @Test("a track on an album page gives the track's id")
    func albumTrack() {
        #expect(AppleMusicLink.songID(from: "https://music.apple.com/gb/album/a-renwicks-ferret-the-pumpkins-fancy/969195822?i=969196002") == "969196002")
        #expect(AppleMusicLink.songID(from: "https://music.apple.com/gb/album/x/1?ls=1&i=2") == "2")
        #expect(AppleMusicLink.songID(from: "http://geo.music.apple.com/us/album/x/1?i=22") == "22")
        #expect(AppleMusicLink.songID(from: "https://itunes.apple.com/gb/album/x/id1?i=33&uo=4") == "33")
        #expect(AppleMusicLink.songID(from: "  music.apple.com/gb/album/x/1?i=44  ") == "44")
        #expect(AppleMusicLink.songID(from: "https://MUSIC.apple.com/gb/album/x/1?i=55") == "55")
    }

    @Test("a song page gives its id")
    func songPage() {
        #expect(AppleMusicLink.songID(from: "https://music.apple.com/gb/song/the-pumpkins-fancy/969196002") == "969196002")
        #expect(AppleMusicLink.songID(from: "https://music.apple.com/gb/song/969196002") == "969196002")
        #expect(AppleMusicLink.songID(from: "https://music.apple.com/gb/song/x/969196002/") == "969196002")
    }

    @Test("albums, playlists, artists and other services are not songs")
    func notSongs() {
        #expect(AppleMusicLink.songID(from: "https://music.apple.com/gb/album/x/969195822") == nil)
        #expect(AppleMusicLink.songID(from: "https://music.apple.com/gb/playlist/x/pl.u-abc") == nil)
        #expect(AppleMusicLink.songID(from: "https://music.apple.com/gb/artist/x/12345") == nil)
        #expect(AppleMusicLink.songID(from: "https://music.apple.com/gb/album/x/1?i=abc") == nil)
        #expect(AppleMusicLink.songID(from: "https://music.apple.com/gb/album/x/1?i=") == nil)
        #expect(AppleMusicLink.songID(from: "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC") == nil)
        #expect(AppleMusicLink.songID(from: "https://michaelmcgoldrick1.bandcamp.com/track/the-cotton-tree-reel") == nil)
        #expect(AppleMusicLink.songID(from: "https://notmusic.apple.com/gb/song/x/1") == nil)
        #expect(AppleMusicLink.songID(from: "https://music.apple.com.example.com/gb/song/x/1") == nil)
        #expect(AppleMusicLink.songID(from: "") == nil)
    }
}
