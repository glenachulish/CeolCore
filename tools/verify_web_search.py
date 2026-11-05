#!/usr/bin/env python3
"""Mirror of WebABC's search bar and .abc file rules
(Sources/CeolCore/Import/WebABC.swift, FONN-WEBSEARCH-1/2), run against the
cases in Tests/CeolCoreTests/WebABCTests.swift. Keep the two in step.

    python3 CeolCore/tools/verify_web_search.py
"""
import sys
from urllib.parse import quote, urlsplit
import posixpath

SITES = [
    ("session", "https://thesession.org/tunes/search", "https://thesession.org/tunes/search?q={q}"),
    ("abcnotation", "https://abcnotation.com/search", "https://abcnotation.com/searchTunes?q={q}&f=c&o=a"),
    ("tunearch", "https://tunearch.org/wiki/Special:Search", "https://tunearch.org/wiki/Special:Search?search={q}"),
    ("gatherer", "https://nigelgatherer.com/tunes/abc.html", "https://duckduckgo.com/?q=site%3Anigelgatherer.com+{q}"),
    ("norbeck", "https://norbeck.nu/abc/", "https://duckduckgo.com/?q=site%3Anorbeck.nu+{q}"),
    ("web", "https://duckduckgo.com/", "https://duckduckgo.com/?q={q}+abc+notation"),
]

def site(i):
    for s in SITES:
        if s[0] == i: return s
    return SITES[0]

def encoded(words):
    collapsed = " ".join(words.split())
    return quote(collapsed, safe="-._~ ").replace(" ", "+")

def interpret(typed):
    t = typed.strip()
    if not t: return ("blank",)
    if "://" in t:
        u = urlsplit(t)
        return ("address", t) if u.hostname else ("words", t)
    if any(c.isspace() for c in t): return ("words", t)
    host = t.split("/", 1)[0]
    labels = host.split(".")
    last = labels[-1]
    if len(labels) >= 2 and all(labels) and len(last) >= 2 and all(c.isascii() and c.isalpha() for c in last):
        return ("address", "https://" + t)
    return ("words", t)

def destination(typed, s):
    k = interpret(typed)
    if k[0] == "blank": return s[1]
    if k[0] == "address": return k[1]
    return s[2].replace("{q}", encoded(k[1]))

def tidy(text):
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if l.strip().startswith("X:")), None)
    if start is None: return ""
    body = "\n".join(lines[start:])
    return body.strip() if "K:" in body else ""

def file_sources(text, url):
    t = tidy(text)
    if not t: return []
    title = next((l.strip()[2:].strip() for l in t.split("\n") if l.strip().startswith("T:")), None)
    fname = posixpath.splitext(posixpath.basename(urlsplit(url).path))[0]
    name = title if title else fname
    return [(name or "Web file", t)]

def is_abc(url):
    return posixpath.splitext(urlsplit(url).path)[1].lower() == ".abc"

fails = 0
def check(label, got, want):
    global fails
    ok = got == want
    if not ok: fails += 1
    print(("PASS " if ok else "FAIL ") + label + ("" if ok else f"\n   got  {got!r}\n   want {want!r}"))

check("blank goes home", destination("  ", site("gatherer")), "https://nigelgatherer.com/tunes/abc.html")
check("words search site", destination("Cooley's  reel", site("session")), "https://thesession.org/tunes/search?q=Cooley%27s+reel")
check("address beats site", destination("nigelgatherer.com/tunes/abc/abc1.html", site("tunearch")), "https://nigelgatherer.com/tunes/abc/abc1.html")
check("St. Anne's", interpret("St. Anne's Reel"), ("words", "St. Anne's Reel"))
check("reel.", interpret("reel."), ("words", "reel."))
check("1.2", interpret("1.2"), ("words", "1.2"))
check("unknown site", site("gone")[0], "session")
check("abc link", is_abc("https://nigelgatherer.com/tunes/abc/abc10/hroad.abc"), True)
check("html not abc", is_abc("https://nigelgatherer.com/tunes/abc.html"), False)
fs = file_sources("%comment\nX:1\nT:High Road to Linton\nK:A\nAB|", "https://example.org/abc/hroad.abc")
check("file title", fs[0][0] if fs else None, "High Road to Linton")
check("file text", fs[0][1].startswith("X:1") if fs else None, True)
check("scheme kept", destination("http://example.org/x", site("web")), "http://example.org/x")
check("gatherer search", destination("high road", site("gatherer")), "https://duckduckgo.com/?q=site%3Anigelgatherer.com+high+road")
check("abc search", destination("Mason's Apron", site("abcnotation")), "https://abcnotation.com/searchTunes?q=Mason%27s+Apron&f=c&o=a")
print("all passed" if not fails else f"{fails} failed")
sys.exit(1 if fails else 0)
