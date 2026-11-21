"""python3 tools/verify_abclayout.py <library.ceol.json>

Transliterates Sources/CeolCore/ABC/ABCLayout.swift into Python, line for line,
and checks it gives exactly what Web/edittools.js gives (ceolLayoutProblems,
ceolTidyLayout) for every tune in a library. The authoring environment has no
Swift toolchain; this catches a port that drifted from the JavaScript.
"""
import json, math, re, subprocess, sys, os

HIDDEN = set(" ​‌‍⁠﻿  ")

def normalised_newlines(s): return s.replace("\r\n", "\n").replace("\r", "\n")
def is_blank(l): return l.strip(" \t              　 ") == ""
def drop_ws(l): return l.lstrip(" \t")
def is_field_line(l):
    t = drop_ws(l)
    if t[:1] == "%": return True
    return len(t) >= 2 and t[0].isascii() and t[0].isalpha() and t[1] == ":"
def starts_field(l, letter):
    t = drop_ws(l); return len(t) >= 2 and t[0] == letter and t[1] == ":"
def trim_trailing(s): return s.rstrip(" \t")
def ends_with_bar(s): return trim_trailing(s).endswith("|")
def ends_with_cont(s): return trim_trailing(s).endswith("\\")
def stray_bangs(line):
    c, out, i = list(line), [], 0
    while i < len(c):
        if c[i] != "!": i += 1; continue
        j = i + 1
        while j < len(c) and c[j] != "!" and not c[j].isspace() and c[j] != "|": j += 1
        inner = j - i - 1
        if j < len(c) and c[j] == "!" and 1 <= inner <= 24: i = j + 1
        else: out.append(i); i += 1
    return out
def bar_count(l): return re.sub(r'"[^"]*"', "", l).count("|")
def note_count(l): return sum(ch in "ABCDEFGabcdefg" for ch in re.sub(r'"[^"]*"|![^!]*!|\{[^}]*\}', "", l))

def problems(abc):
    text = normalised_newlines(abc); lines = text.split("\n")
    k = next((i for i, l in enumerate(lines) if l.startswith("K:")), None)
    if k is None: return []
    body = lines[k + 1:]
    last = -1
    for i, l in enumerate(body):
        if not is_blank(l) and not is_field_line(l): last = i
    blank = bangs = nobars = header = second = False; short = music = 0
    for i, l in enumerate(body):
        if starts_field(l, "X"): second = True
        if is_blank(l):
            if i < last and not second: blank = True
            continue
        if starts_field(l, "T"): header = True
        if is_field_line(l): continue
        music += 1
        if stray_bangs(l): bangs = True
        bars = bar_count(l)
        if bars == 0 and note_count(l) > 24: nobars = True
        if bars <= 2 and i != last and not ends_with_cont(l): short += 1
    out = []
    if blank: out.append("blank")
    if bangs: out.append("bang")
    if any(ch in HIDDEN for ch in text): out.append("hidden")
    if music >= 3 and short >= max(2, math.ceil(music / 3)): out.append("short")
    if nobars: out.append("nobars")
    if header: out.append("title")
    if second: out.append("second")
    return out

def tidy(abc):
    s = []
    for ch in normalised_newlines(abc):
        if ch in "  ": s.append("\n")
        elif ch == " ": s.append(" ")
        elif ch in "​‌‍⁠﻿": continue
        else: s.append(ch)
    lines = "".join(s).split("\n")
    k = next((i for i, l in enumerate(lines) if l.startswith("K:")), None)
    if k is None: return "".join(s)
    head = "\n".join(lines[:k + 1]) + "\n"; body = lines[k + 1:]
    has_second = any(starts_field(l, "X") for l in body)
    out = []; cur = [""]
    def flush():
        if not is_blank(cur[0]): out.append(trim_trailing(cur[0]))
        cur[0] = ""
    i = 0
    while i < len(body):
        line = body[i]
        if starts_field(line, "X"): flush(); out.extend(body[i:]); break
        if is_blank(line):
            if has_second: flush(); out.append("")
            i += 1; continue
        if is_field_line(line): flush(); out.append(trim_trailing(line)); i += 1; continue
        chars = list(line)
        for idx in reversed(stray_bangs(line)): chars[idx] = " "
        line = re.sub(r"\\\s*$", "", "".join(chars)).strip(" \t ")
        if not line: i += 1; continue
        if cur[0] == "": cur[0] = line
        elif ends_with_bar(cur[0]) and line.startswith("|"): cur[0] = trim_trailing(cur[0])[:-1] + line
        else: cur[0] += ("" if ends_with_bar(cur[0]) else " ") + line
        if re.search(r"(:\||\|\]|\|\||::)\s*$", cur[0]): flush()
        i += 1
    flush()
    joined = "\n".join(out).rstrip("\n")
    return head + joined + "\n"

here = os.path.dirname(os.path.abspath(__file__))
lib = json.load(open(sys.argv[1]))
tunes = [t["abc"] for t in lib["tunes"] if t.get("abc") and "\nK:" in t["abc"]]
js = subprocess.run(["node", "-e", """
global.ABCJS=require(process.argv[1]); const T=require(process.argv[2]);
const tunes=JSON.parse(require('fs').readFileSync(0,'utf8'));
console.log(JSON.stringify(tunes.map(a=>({p:T.ceolLayoutProblems(a).map(x=>x.id),t:T.ceolTidyLayout(a)}))));""",
    os.path.join(here, "../Sources/CeolCore/Web/abcjs-basic-min.js"),
    os.path.join(here, "../Sources/CeolCore/Web/edittools.js")],
    input=json.dumps(tunes), capture_output=True, text=True, check=True)
want = json.loads(js.stdout)
bad = 0
for abc, w in zip(tunes, want):
    p, t = problems(abc), tidy(abc)
    if p != w["p"] or t != w["t"]:
        bad += 1
        if bad <= 3: print("DIFFER:", abc.split("\n")[1], p, w["p"], t == w["t"])
print(f"{len(tunes)} tunes, {bad} differ between the Swift port and the JavaScript")
sys.exit(1 if bad else 0)
