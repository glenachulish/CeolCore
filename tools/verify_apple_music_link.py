#!/usr/bin/env python3
"""Mirror of AppleMusicLink (Sources/CeolCore/Models/AppleMusicLink.swift), run
against the same cases as Tests/CeolCoreTests/AppleMusicLinkTests.swift.
Keep it in step with the Swift.

    python3 CeolCore/tools/verify_apple_music_link.py
"""
import sys
from urllib.parse import urlsplit, parse_qsl

# FONN-APPLEMUSIC-1

def is_host(h):
    return h == "music.apple.com" or h.endswith(".music.apple.com") or h == "itunes.apple.com"

def is_id(s):
    return bool(s) and len(s) <= 20 and all(c in "0123456789" for c in s)

def song_id(s):
    s = s.strip()
    if not s: return None
    if "://" not in s: s = "https://" + s
    u = urlsplit(s)
    if not is_host((u.hostname or "").lower()): return None
    q = [v for k, v in parse_qsl(u.query, keep_blank_values=True) if k == "i"]
    if q:
        return q[0] if is_id(q[0]) else None
    parts = [p for p in u.path.split("/") if p]
    if "song" in parts and parts and is_id(parts[-1]):
        return parts[-1]
    return None

CASES = [
    ("https://music.apple.com/gb/album/a-renwicks-ferret-the-pumpkins-fancy/969195822?i=969196002", "969196002"),
    ("https://music.apple.com/gb/album/x/1?ls=1&i=2", "2"),
    ("http://geo.music.apple.com/us/album/x/1?i=22", "22"),
    ("https://itunes.apple.com/gb/album/x/id1?i=33&uo=4", "33"),
    ("  music.apple.com/gb/album/x/1?i=44  ", "44"),
    ("https://MUSIC.apple.com/gb/album/x/1?i=55", "55"),
    ("https://music.apple.com/gb/song/the-pumpkins-fancy/969196002", "969196002"),
    ("https://music.apple.com/gb/song/969196002", "969196002"),
    ("https://music.apple.com/gb/song/x/969196002/", "969196002"),
    ("https://music.apple.com/gb/album/x/969195822", None),
    ("https://music.apple.com/gb/playlist/x/pl.u-abc", None),
    ("https://music.apple.com/gb/artist/x/12345", None),
    ("https://music.apple.com/gb/album/x/1?i=abc", None),
    ("https://music.apple.com/gb/album/x/1?i=", None),
    ("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC", None),
    ("https://michaelmcgoldrick1.bandcamp.com/track/the-cotton-tree-reel", None),
    ("https://notmusic.apple.com/gb/song/x/1", None),
    ("https://music.apple.com.example.com/gb/song/x/1", None),
    ("", None),
]

bad = [(c, w, song_id(c)) for c, w in CASES if song_id(c) != w]
for c, w, g in bad:
    print(f"FAIL {c!r}: wanted {w!r}, got {g!r}")
print(f"{len(CASES) - len(bad)}/{len(CASES)} Apple Music link cases pass")
sys.exit(1 if bad else 0)
