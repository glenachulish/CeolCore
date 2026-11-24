"""python3 tools/verify_abcphrase.py <library.ceol.json> [pairs.json]

FONN-LAYOUT-2. A line-for-line Python copy of ABCLayout.phrased (four bars a
line, part labels) in Sources/CeolCore/ABC/ABCLayout.swift. Checks, over a
whole library, that phrasing then tidying again changes nothing (it is
stable), and that the music is the same as the tidied music once whitespace
and the added P: labels are taken out. Writes pairs.json (title, tidied,
phrased) for abc-harness/phrase_notes.js, which checks in abcjs itself that
every note and duration is the same.
"""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
_argv = sys.argv; sys.argv = [sys.argv[0], "/dev/null"]
_here = os.path.dirname(os.path.abspath(__file__))
_code = open(os.path.join(_here, "verify_abclayout.py")).read()
exec(_code[:_code.index("here = os.path.dirname")])

TUPLET = re.compile(r"\(\d(:\d*)?(:\d*)?")

def tokens(line):
    out, cur, i, n = [], "", 0, len(line)
    while i < n:
        c = line[i]
        if c == '"':
            j = line.find('"', i + 1); j = n - 1 if j < 0 else j
            cur += line[i:j + 1]; i = j + 1; continue
        if c in "!+{":
            close = "}" if c == "{" else c
            j = line.find(close, i + 1)
            if j > i and (c == "{" or (j - i <= 25 and " " not in line[i:j])):
                cur += line[i:j + 1]; i = j + 1; continue
        if c == "%":
            cur += line[i:]; break
        if c == "[" and i + 2 < n and line[i + 1].isalpha() and line[i + 2] == ":":
            j = line.find("]", i + 1); j = n - 1 if j < 0 else j
            cur += line[i:j + 1]; i = j + 1; continue
        if c == "(" and i + 1 < n and line[i + 1].isdigit():
            m = TUPLET.match(line, i); cur += m.group(0); i = m.end(); continue
        if c in "|:" or (c == "[" and i + 1 < n and (line[i + 1] == "|" or line[i + 1].isdigit())):
            j = i
            while j < n:
                d = line[j]
                if d in "|:": j += 1
                elif d == "]" and j > i and line[j - 1] == "|": j += 1
                elif d == "[" and j + 1 < n and (line[j + 1] == "|" or line[j + 1].isdigit()): j += 1
                else: break
            k = j
            while k < n and (line[k].isdigit() or (k > j and line[k] in ",-")): k += 1
            out.append(("seg", cur)); cur = ""
            out.append(("bar", line[i:k])); i = k; continue
        cur += c; i += 1
    out.append(("seg", cur))
    return out

def notes(seg):
    s = re.sub(r'"[^"]*"|![^!]*!|\{[^}]*\}|\[[A-Za-z]:[^\]]*\]|%.*', "", seg)
    return sum(ch in "ABCDEFGabcdefgz" for ch in s)

def ending(tok):
    m = re.search(r"\d", tok)
    return int(m.group(0)) if m else None

def is_part_end(items, i):
    """A bar token that ends a part: :| || |] :: with no later ending after it."""
    tok = items[i][1]
    if ending(tok) is not None: return False
    if not any(s in tok for s in (":|", "||", "|]", "::")): return False
    j = i + 1
    while j < len(items):
        k, x = items[j]
        if k == "seg":
            if notes(x) > 0: return True
        elif ending(x) is not None and ending(x) >= 2: return False
        else: return True
        j += 1
    return False

def split_parts(line):
    items = tokens(line)
    parts, cur = [], []
    for i, it in enumerate(items):
        k, x = it
        # A start repeat in the middle of a line begins a new part: the part
        # before ends with a bar line, and the new one starts with |:.
        if (k == "bar" and x.endswith("|:") and ":|" not in x and ending(x) is None
                and sum(1 for kk, xx in cur if kk == "seg" and notes(xx) > 0) >= 2):
            last_bar = next((kk for kk, xx in reversed(cur) if kk == "bar" or xx.strip()), "")
            if len(x) > 2: cur.append(("bar", x[:-2]))
            elif last_bar != "bar": cur.append(("bar", "|"))
            parts.append(cur); cur = [("bar", "|:")]
            continue
        cur.append(it)
        if it[0] == "bar" and is_part_end(items, i):
            parts.append(cur); cur = []
    if any(k == "seg" and notes(x) > 0 for k, x in cur) or not parts: parts.append(cur)
    else: parts[-1].extend(cur)
    return parts

def phrase_part(items):
    segs = [i for i, (k, x) in enumerate(items) if k == "seg" and notes(x) > 0]
    if not segs: return "".join(x for _, x in items).strip(), 0
    counts = [notes(items[i][1]) for i in segs]
    srt = sorted(counts); median = srt[len(srt) // 2]
    counted = set()
    for idx, i in enumerate(segs):
        opening = items[i - 1][1] if i > 0 else ""
        e = ending(opening)
        if idx == 0 and len(segs) > 1 and counts[idx] * 2 < median: continue   # pickup
        if e is not None and e >= 2: continue                                   # a later ending
        counted.add(i)
    N = len(counted)
    per = N if N <= 5 else (4 if N % 4 == 0 else (3 if N % 3 == 0 else 4))
    out, c, pending = [], 0, False
    for i, (kind, text) in enumerate(items):
        if kind == "bar":
            e = ending(text)
            if pending and e == 1:
                # Break before the first ending: after the bar line, if the
                # ending is written [1, otherwise before the whole token.
                cut = text.find("[")
                if cut > 0:
                    out.append(text[:cut]); text = text[cut:]
                out.append("\n"); pending = False
            out.append(text)
            if pending and e is None:
                out.append("\n"); pending = False
        else:
            out.append(text)
            if i in counted:
                c += 1
                if c % per == 0 and c < N: pending = True
    text = "\n".join(l.strip(" \t") for l in "".join(out).split("\n") if l.strip(" \t"))
    return text, N

def phrase_line(line):
    return "\n".join(phrase_part(p)[0] for p in split_parts(line))

def voice_ids(lines):
    ids = set()
    for l in lines:
        s = l.lstrip(" \t")
        if s.startswith("V:"):
            w = s[2:].split()
            ids.add(w[0] if w else "")
        for m in re.finditer(r"\[V:\s*([^\]\s]*)", l):
            ids.add(m.group(1))
    return ids


def leading_later_ending(line):
    """FONN-ENDING-1. If a line opens with a second (or later) ending, split
    it into that ending (up to where the next part starts) and the rest. The
    ending belongs to the part above; laid out line by line, it was being
    counted into the next part, which then took the part label too."""
    items = tokens(line)
    first = next((n for n, (k, x) in enumerate(items) if k == "bar" or x.strip()), None)
    if first is None or items[first][0] != "bar": return None
    e = ending(items[first][1])
    if e is None or e < 2: return None
    for n in range(first + 1, len(items)):
        k, x = items[n]
        if k != "bar": continue
        if x.endswith("|:") and ":|" not in x and ending(x) is None:
            before = "".join(xx for _, xx in items[:n])
            last = next((kk for kk, xx in reversed(items[:n]) if kk == "bar" or xx.strip()), "")
            close = x[:-2] if len(x) > 2 else ("" if last == "bar" else "|")
            return before + close, "|:" + "".join(xx for _, xx in items[n + 1:])
        if ("||" in x or "|]" in x) and ending(x) is None:
            return "".join(xx for _, xx in items[:n + 1]), "".join(xx for _, xx in items[n + 1:])
    return line, ""

PART_END = re.compile(r"(:\||\|\]|\|\||::)\s*$")

def scan(abc):
    """Tidy, then 4 bars a line and part labels. Never changes a note."""
    t = tidy(abc)
    lines = t.split("\n")
    k = next((i for i, l in enumerate(lines) if l.startswith("K:")), None)
    if k is None: return t
    head, body = lines[:k + 1], lines[k + 1:]
    if any(starts_field(l, "X") for l in body): return t
    # Several voices, or a tune that sets its own line breaks: left as tidied.
    # FONN-ONEVOICE-1: a single voice named with V:1 (as many tools write it)
    # is one stave like any other; only two or more voices are left alone.
    if len(voice_ids(lines)) > 1: return t
    if any("%%score" in l or "%%staves" in l or "linebreak" in l for l in lines): return t
    music = [i for i, l in enumerate(body) if not is_blank(l) and not is_field_line(l)]
    emptied = set()
    for pos in range(1, len(music)):
        cut = leading_later_ending(body[music[pos]])
        if cut is None: continue
        moved, rest = cut
        prev = music[pos - 1]
        moved = moved.strip()
        if re.match(r"\|\d", moved) and body[prev].rstrip()[-1:] in ("|", ":"):
            moved = "[" + moved[1:]          # :| |2 would draw an empty bar
        body[prev] = body[prev].rstrip() + " " + moved
        body[music[pos]] = rest.strip()
        if not body[music[pos]]: emptied.add(music[pos])
    music = [i for i in music if i not in emptied]
    has_p = any(starts_field(l, "P") for l in lines)
    phrased = {i: [phrase_part(p) for p in split_parts(body[i])] for i in music}
    parts = [pt for i in music for pt in phrased[i]]
    real = [n for _, n in parts if n > 0]
    label = (not has_p and 2 <= len(real) <= 8 and all(n >= 4 for n in real))
    out, part = [], 0
    for i, l in enumerate(body):
        if i in music:
            for text, _ in phrased[i]:
                if label and _ > 0:
                    out.append("P:" + "ABCDEFGH"[part]); part += 1
                out.append(text)
        elif i not in emptied:
            out.append(l)
    # FONN-SPLITREPEAT-1: a part that ends a line with "::" hands its
    # start-repeat to the next line, so the repeat sign opens the next part.
    rows = [i for i, l in enumerate(out) if not is_blank(l) and not is_field_line(l)]
    for a, b in zip(rows, rows[1:]):
        ta = out[a].rstrip()
        for suffix in (":||:", ":|:", "::"):
            if ta.endswith(suffix) and not ta.endswith("|" + suffix):
                out[a] = ta[:-len(suffix)] + ":|"
                out[b] = "|: " + out[b].lstrip()
                break
    return "\n".join(head + close_later_endings(leading_fields_as_lines(out)))  # FONN-LEADFIELD-1, FONN-CLOSEEND-1


if __name__ == "__main__":
    lib = json.load(open(_argv[1]))
    tunes = [t for t in lib["tunes"] if (t.get("abc") or "").strip()]
    def flat(abc):
        lines = abc.split("\n")
        k = next((i for i, l in enumerate(lines) if l.startswith("K:")), None)
        if k is None: return re.sub(r"\s", "", abc)
        body = [l for l in lines[k + 1:] if not re.match(r"\s*P:[A-H]\s*$", l)]
        # FONN-LEADFIELD-1: [M:x] and an M:x line are the same change.
        body = [re.sub(r"\[([MK]:[^\]]*)\]", r"\1", l) for l in body]
        # Bar lines aside: a | is added where a part is split at a |: .
        # [2 and |2 are the same ending (FONN-ENDING-1 writes [2 after a :|).
        return re.sub(r"\[(?=\d)", "", re.sub(r"[\s|]", "", "\n".join(lines[:k + 1] + body)))
    unstable = [t["title"] for t in tunes if scan(scan(t["abc"])) != scan(t["abc"])]
    differ = [t["title"] for t in tunes if flat(scan(t["abc"])) != flat(tidy(t["abc"]))]
    changed = sum(scan(t["abc"]).strip() != t["abc"].strip() for t in tunes)
    print(f"{len(tunes)} tunes: {changed} laid out afresh; unstable {len(unstable)}; music differs {len(differ)}")
    for x in (unstable + differ)[:10]: print("  ", x)
    out = _argv[2] if len(_argv) > 2 else "pairs.json"
    json.dump([[t["title"], tidy(t["abc"]), scan(t["abc"])] for t in tunes], open(out, "w"))
    sys.exit(1 if unstable or differ else 0)
