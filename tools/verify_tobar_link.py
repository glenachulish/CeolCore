#!/usr/bin/env python3
"""Mirror of TobarLink's rules (Sources/CeolCore/Tobar/TobarLink.swift), run
against the same cases as Tests/CeolCoreTests/TobarLinkTests.swift.

There is no Swift toolchain where this was written, so this does not prove the
Swift compiles. It proves the *rules* are what the tests say: which links are
Tobar tracks, how fonn:// links are read, and which titles count as the same
tune. Keep it in step with TobarLink.swift.

    python3 CeolCore/tools/verify_tobar_link.py
"""
import sys, unicodedata
from urllib.parse import urlsplit, parse_qsl, urlencode, quote

HOSTS = {"tobarandualchais.co.uk", "www.tobarandualchais.co.uk"}
LEADING = ["an t-", "an t’", "the ", "an ", "am ", "na ", "a' ", "a’ ", "a "]
TRAILING = ["the", "a", "an", "na", "am", "an t-", "na h-"]

def track_id(s):
    s = s.strip()
    if not s: return None
    if "://" not in s: s = "https://" + s
    u = urlsplit(s)
    if (u.hostname or "").lower() not in HOSTS: return None
    parts = [p for p in u.path.split("/") if p]
    if len(parts) >= 2 and parts[0] == "track" and parts[1].isdigit():
        return int(parts[1])
    return None

def same_track(a, b):
    x, y = track_id(a), track_id(b)
    return x is not None and y is not None and x == y

def parse_incoming(url):
    u = urlsplit(url)
    if (u.scheme or "").lower() != "fonn": return None
    if (u.hostname or "").lower() not in ("tune", "search"): return None
    items = parse_qsl(u.query, keep_blank_values=True)
    if not items: return None
    get = lambda n: next((v for k, v in items if k == n), None)
    raw = get("title")
    if raw is None: raw = get("q")
    title = (raw or "").strip()
    if not title: return None
    link = get("link")
    link = link.strip() if link is not None and track_id(link) is not None else None
    return (title, link)

def fold(t):
    d = unicodedata.normalize("NFD", t)
    return "".join(c for c in d if unicodedata.category(c) not in ("Mn", "Mc", "Me")).lower()

def match_key(title):
    f = fold(title).strip()
    if "," in f:
        i = f.rfind(",")
        head, tail = f[:i].strip(), f[i+1:].strip()
        if head and tail in TRAILING: f = head
    for a in LEADING:
        if f.startswith(a):
            rest = f[len(a):].strip()
            if rest: f = rest
            break
    kept = "".join(c if c.isalnum() else " " for c in f)
    return " ".join(kept.split())

def match_index(title, titles):
    w = match_key(title)
    if not w: return None
    return next((i for i, t in enumerate(titles) if match_key(t) == w), None)

failures = 0
def check(cond, what):
    global failures
    if not cond:
        failures += 1
        print("FAIL:", what)

check(track_id("https://www.tobarandualchais.co.uk/track/91825?l=en") == 91825, "track 91825")
check(track_id("https://tobarandualchais.co.uk/track/1") == 1, "bare host")
check(track_id("www.tobarandualchais.co.uk/track/42") == 42, "no scheme")
check(track_id("  https://www.tobarandualchais.co.uk/track/7/  ") == 7, "spaces, slash")
check(track_id("https://www.tobarandualchais.co.uk/person/12") is None, "person")
check(track_id("https://www.tobarandualchais.co.uk/track/abc") is None, "non-numeric")
check(track_id("https://example.com/track/91825") is None, "other host")
check(track_id("") is None, "empty")

check(same_track("https://www.tobarandualchais.co.uk/track/91825?l=en",
                 "http://tobarandualchais.co.uk/track/91825"), "same track")
check(not same_track("https://www.tobarandualchais.co.uk/track/1",
                     "https://www.tobarandualchais.co.uk/track/2"), "different tracks")
check(not same_track("https://example.com/track/1", "https://example.com/track/1"), "not tobar")

check(parse_incoming("fonn://tune?title=The%20Banshee&link=https%3A%2F%2Fwww.tobarandualchais.co.uk%2Ftrack%2F1")
      == ("The Banshee", "https://www.tobarandualchais.co.uk/track/1"), "tune link")
check(parse_incoming("fonn://search?q=Calliope%20House") == ("Calliope House", None), "search")
check(parse_incoming("fonn://tune?title=Kesh&link=https%3A%2F%2Fexample.com%2Ftrack%2F1") == ("Kesh", None),
      "non-track link dropped")
for other in ["fonn://tune?link=https%3A%2F%2Fwww.tobarandualchais.co.uk%2Ftrack%2F1",
              "fonn://tune?title=%20%20", "fonn://set?title=Kesh", "orain://song?title=Kesh",
              "file:///Users/me/library.ceol.json", "https://www.tobarandualchais.co.uk/track/1"]:
    check(parse_incoming(other) is None, "ignored: " + other)

for a, b in [("The Banshee", "Banshee, The"), ("the banshee", "Banshee"),
             ("Chì Mi Na Mòrbheanna", "chi mi na morbheanna"),
             ("An t-Eilean Muileach", "Eilean Muileach"),
             ("Eilean Muileach, An t-", "An t-Eilean Muileach"),
             ("Fear a' Bhàta", "Fear a Bhata"),
             ("Morrison's Jig", "Morrison’s Jig"),
             ("  Kesh   Jig  ", "Kesh Jig")]:
    check(match_key(a) == match_key(b), f"same: {a!r} / {b!r} -> {match_key(a)!r} / {match_key(b)!r}")
check(match_key("Kesh Jig") != match_key("Kesh"), "Kesh Jig != Kesh")
check(match_key("The") == "the", "a tune called The")

titles = ["Kesh Jig", "Banshee, The", "Morrison's Jig"]
check(match_index("The Banshee", titles) == 1, "index banshee")
check(match_index("morrison’s jig", titles) == 2, "index morrison")
check(match_index("Kesh", titles) is None, "no near miss")
check(match_index("", titles) is None, "empty title")

print("verify_tobar_link: all checks passed" if failures == 0 else f"verify_tobar_link: {failures} failed")
sys.exit(1 if failures else 0)
