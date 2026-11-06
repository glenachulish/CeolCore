#!/usr/bin/env python3
"""Mirror of SpotifyLink and BandcampLink (Sources/CeolCore/Models/StreamingLinks.swift,
FONN-EMBEDS-1), run against the cases in Tests/CeolCoreTests/StreamingLinksTests.swift.
Keep the two in step.

    python3 CeolCore/tools/verify_streaming_links.py
"""
import json, re, sys
from urllib.parse import urlsplit

KINDS = {"track", "album", "playlist", "episode", "show"}

def is_id(s):
    return len(s) == 22 and all(c.isascii() and c.isalnum() for c in s)

def spotify_item(s):
    s = s.strip()
    if not s: return None
    if s.lower().startswith("spotify:"):
        p = s.split(":")
        if len(p) == 3 and p[1].lower() in KINDS and is_id(p[2]): return (p[1].lower(), p[2])
        return None
    if "://" not in s: s = "https://" + s
    u = urlsplit(s)
    if (u.hostname or "").lower() not in ("open.spotify.com", "play.spotify.com"): return None
    parts = [x for x in u.path.split("/") if x]
    if parts and parts[0].lower().startswith("intl-"): parts.pop(0)
    if parts and parts[0].lower() == "embed": parts.pop(0)
    if len(parts) >= 2 and parts[0].lower() in KINDS and is_id(parts[1]): return (parts[0].lower(), parts[1])
    return None

def spotify_embed(s):
    it = spotify_item(s)
    return f"https://open.spotify.com/embed/{it[0]}/{it[1]}" if it else None

def bc_is_page(s):
    s = s.strip()
    if not s: return False
    if "://" not in s: s = "https://" + s
    u = urlsplit(s)
    if not (u.hostname or "").lower().endswith(".bandcamp.com"): return False
    parts = [x for x in u.path.split("/") if x]
    return len(parts) >= 2 and parts[0] in ("track", "album")

def bc_props(html):
    i = html.find("bc-page-properties")
    if i < 0: return None
    tail = html[i + len("bc-page-properties"):]
    j = tail.find("content=")
    if j < 0: return None
    after = tail[j + len("content="):]
    if not after or after[0] not in "\"'": return None
    q = after[0]; body = after[1:]
    k = body.find(q)
    if k < 0: return None
    js = body[:k].replace("&quot;", '"').replace("&#34;", '"').replace("&amp;", "&")
    try: o = json.loads(js)
    except Exception: return None
    t = o.get("item_type"); iid = o.get("item_id")
    if isinstance(iid, bool) or iid is None: return None
    iid = str(iid)
    if not iid.isdigit(): return None
    return {"t": ("track", iid), "a": ("album", iid)}.get(t)

def bc_embed_item(html):
    it = bc_props(html)
    if it: return it
    m = re.search(r"""EmbeddedPlayer/[^"'\s]*?(track|album)=(\d+)""", html)
    if not m: return None
    match = m.group(0)
    for kind in ("track", "album"):
        r = match.find(kind + "=")
        if r >= 0:
            d = re.match(r"\d+", match[r + len(kind) + 1:])
            if d: return (kind, d.group(0))
    return None

fails = 0
def check(label, got, want):
    global fails
    ok = got == want
    if not ok: fails += 1
    print(("PASS " if ok else "FAIL ") + label + ("" if ok else f"\n   got  {got!r}\n   want {want!r}"))

check("spotify track", spotify_item("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=abc"), ("track", "4uLU6hMCjMI75M1A2tKUQC"))
check("intl album", (spotify_item("https://open.spotify.com/intl-de/album/1A2GTWGtFfWp7KSQTwWOyo") or (None,))[0], "album")
check("uri", (spotify_item("spotify:track:4uLU6hMCjMI75M1A2tKUQC") or (None, None))[1], "4uLU6hMCjMI75M1A2tKUQC")
check("embed", spotify_embed("open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"), "https://open.spotify.com/embed/track/4uLU6hMCjMI75M1A2tKUQC")
check("artist rejected", spotify_item("https://open.spotify.com/artist/0OdUWJ0sBjDrqHygGUXeCF"), None)
check("short rejected", spotify_item("https://open.spotify.com/track/short"), None)
check("other host rejected", spotify_item("https://example.com/track/4uLU6hMCjMI75M1A2tKUQC"), None)
check("bc track", bc_is_page("https://michaelmcgoldrick.bandcamp.com/track/the-wiggly-jig"), True)
check("bc album bare", bc_is_page("michaelmcgoldrick.bandcamp.com/album/arcadia"), True)
check("bc front page", bc_is_page("https://michaelmcgoldrick.bandcamp.com/"), False)
check("bc discover", bc_is_page("https://bandcamp.com/discover"), False)
check("bc props", bc_embed_item('<meta name="bc-page-properties" content="{&quot;item_type&quot;:&quot;t&quot;,&quot;item_id&quot;:2797651047,&quot;tralbum_page_version&quot;:0}">'), ("track", "2797651047"))
check("bc og", bc_embed_item('<meta property="og:video" content="https://bandcamp.com/EmbeddedPlayer/v=2/album=1234567/size=large/tracklist=false/artwork=small/">'), ("album", "1234567"))
check("bc nothing", bc_embed_item("<html><body>hello</body></html>"), None)
from urllib.parse import quote, urlunsplit
def sp_search(w):
    c = " ".join(w.split())
    return "https://open.spotify.com/search"
def bc_search(w):
    c = " ".join(w.split())
    if not c: return "https://bandcamp.com/search"
    return "https://bandcamp.com/search?q=" + quote(c, safe="-._~ ").replace(" ", "+") + "&item_type=t"
def bc_playable(u):
    if not u or not bc_is_page(u): return None
    x = urlsplit(u)
    return urlunsplit((x.scheme, x.netloc, x.path, "", ""))
check("sp search", sp_search("The Kesh  Jig"), "https://open.spotify.com/search")
check("bc search", bc_search("McGoldrick reels"), "https://bandcamp.com/search?q=McGoldrick+reels&item_type=t")
check("bc search blank", bc_search(" "), "https://bandcamp.com/search")
check("bc playable", bc_playable("https://michaelmcgoldrick.bandcamp.com/track/the-wiggly-jig?from=search&search_item_id=1"), "https://michaelmcgoldrick.bandcamp.com/track/the-wiggly-jig")
check("bc search not playable", bc_playable("https://bandcamp.com/search?q=x"), None)
def chip_name(t):
    t = t.strip()
    if not t: return None
    i = t.rfind(" — ")
    if i >= 0:
        after = t[i + 3:].strip()
        if after: return after
    return t
check("chip performer", chip_name("The Kesh Jig — Lùnasa"), "Lùnasa")
check("chip plain", chip_name("Live in Ennis"), "Live in Ennis")
check("chip blank", chip_name("  "), None)
check("chip trailing dash", chip_name("Jig — "), "Jig —")
print("all passed" if not fails else f"{fails} failed")
sys.exit(1 if fails else 0)
