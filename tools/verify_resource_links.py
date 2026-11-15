"""FONN-RESOURCES-1: ResourceLinks.url(from:), sameKey and LinkKind.guess,
transliterated from Links/ResourceModels.swift and run against fixtures
(no Swift toolchain where this was written)."""
from urllib.parse import urlsplit, urlunsplit

def url_from(text):
    raw = text.strip()
    if not raw or " " in raw: return None
    if not raw.lower().startswith(("http://", "https://")):
        if "://" in raw: return None
        raw = "https://" + raw
    p = urlsplit(raw)
    if not p.hostname or "." not in p.hostname: return None
    if p.scheme.lower() not in ("http", "https"): return None
    return raw

def same_key(text):
    p = urlsplit(text.strip())
    host = (p.hostname or "").lower()
    if host.startswith("www."): host = host[4:]
    path = p.path[:-1] if p.path.endswith("/") else p.path
    return urlunsplit(("https", host, path, p.query, p.fragment))

def guess(u):
    p = urlsplit(u); host = (p.hostname or "").lower()
    ext = p.path.rsplit(".", 1)[-1].lower() if "." in p.path.rsplit("/", 1)[-1] else ""
    on = lambda s: host == s or host.endswith("." + s)
    if any(map(on, ["youtube.com", "youtu.be", "vimeo.com", "tiktok.com"])) or ext in ("mp4","mov","m4v","webm"): return "video"
    if any(map(on, ["tobarandualchais.co.uk","raretunes.org","itma.ie","archive.org","ambaile.org.uk","calum-maclean-project.ed.ac.uk"])): return "archive"
    if any(map(on, ["soundcloud.com","bandcamp.com","spotify.com","music.apple.com","mixcloud.com"])) or ext in ("mp3","m4a","wav","aif","aiff","ogg","flac"): return "recording"
    return "article"

cases = [
    ("youtube.com/watch?v=abc", "https://youtube.com/watch?v=abc"),
    ("  https://www.tobarandualchais.co.uk/track/123 ", "https://www.tobarandualchais.co.uk/track/123"),
    ("http://thesession.org/tunes/2", "http://thesession.org/tunes/2"),
    ("not a link", None), ("hello", None), ("ftp://x.org/a", None), ("", None),
]
for text, want in cases:
    assert url_from(text) == want, (text, url_from(text))
assert same_key("http://www.YouTube.com/watch?v=a") == same_key("https://youtube.com/watch?v=a")
assert same_key("https://example.org/page/") == same_key("https://example.org/page")
assert same_key("https://a.org/x?v=1") != same_key("https://a.org/x?v=2")
for u, k in [("https://youtu.be/x", "video"), ("https://m.youtube.com/watch?v=1", "video"),
             ("https://www.tobarandualchais.co.uk/track/1", "archive"), ("https://x.bandcamp.com/track/y", "recording"),
             ("https://example.org/tune.mp3", "recording"), ("https://thesession.org/tunes/1", "article")]:
    assert guess(u) == k, (u, guess(u))
print("verify_resource_links: all passed")
