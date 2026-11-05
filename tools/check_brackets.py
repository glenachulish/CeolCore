#!/usr/bin/env python3
"""Rough Swift syntax check without a Swift toolchain: brackets balance,
ignoring comments, strings (with interpolation) and raw/multi-line strings.
Catches a lost brace from a patch; it is not a compiler.

    python3 CeolCore/tools/check_brackets.py file.swift ...
"""
import sys
def check(path):
    s = open(path, encoding="utf-8").read()
    i, n = 0, len(s); stack = []; line = 1
    pairs = {')': '(', ']': '[', '}': '{'}
    def err(msg):
        print(f"{path}:{line}: {msg}"); return False
    while i < n:
        c = s[i]
        if c == '\n': line += 1
        if s.startswith('//', i):
            j = s.find('\n', i); i = n if j < 0 else j; continue
        if s.startswith('/*', i):
            j = s.find('*/', i); line += s[i:j].count('\n'); i = j + 2; continue
        if s.startswith('#"""', i):
            j = s.find('"""#', i + 4); line += s[i:j].count('\n'); i = j + 4; continue
        if s.startswith('#"', i):
            j = s.find('"#', i + 2); line += s[i:j].count('\n'); i = j + 2; continue
        if c == '"':
            if s.startswith('"""', i):
                j = s.find('"""', i + 3); line += s[i:j].count('\n'); i = j + 3; continue
            i += 1; depth = 0
            while i < n:
                if s[i] == '\\' and i + 1 < n and s[i + 1] == '(':
                    depth += 1; i += 2; continue
                if s[i] == '\\': i += 2; continue
                if depth and s[i] == '(': depth += 1
                elif depth and s[i] == ')': depth -= 1
                elif s[i] == '"' and depth == 0: break
                elif s[i] == '"' and depth: i = s.find('"', i + 1)
                elif s[i] == '\n': return err("newline in string")
                i += 1
            i += 1; continue
        if c in '([{': stack.append((c, line))
        elif c in ')]}':
            if not stack or stack[-1][0] != pairs[c]: return err(f"unmatched {c}")
            stack.pop()
        i += 1
    if stack: return err(f"unclosed {stack[-1]}")
    print("OK", path); return True
ok = all([check(p) for p in sys.argv[1:]])
sys.exit(0 if ok else 1)
