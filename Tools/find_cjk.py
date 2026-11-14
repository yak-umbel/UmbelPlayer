#!/usr/bin/env python3
"""Find Chinese, Japanese or Korean text where it should not be.

    find_cjk.py --everywhere PATH...   anywhere in the files
    find_cjk.py --comments PATH...     in comments only

Directories are searched for source files — those git tracks, when inside a
repository — including files with no extension, such as hooks and version
lists; binary files, told by a NUL byte, are passed over. Comments are found by a small scanner, not by line: Swift, Metal and C
comments (`//`, `/* */`) outside string literals; `#` comments in shell,
Python, YAML and files with no extension, and Python docstrings. Text in
strings is left alone, so test data can be in any language.

Prints each finding as path:line and exits 1 if there are any.
"""

import os
import re
import subprocess
import sys

CJK = re.compile(
    "[\u3000-\u303f\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af\uff00-\uffef]")
C_LIKE = {".swift", ".metal", ".metalsrc", ".h", ".m", ".c", ".modulemap"}
HASH = {".sh", ".py", ".yml", ".yaml", ""}
SCRIPTS = C_LIKE | HASH


def c_comments(text):
    """(line, comment text) for each comment in C-like source."""
    found = []
    i, line, n = 0, 1, len(text)
    while i < n:
        c = text[i]
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
            line += text.count("\n", i, end)
            i = end
        elif c == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == "\\" else 1
            i = j + 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            found.append((line, text[i:end]))
            i = end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            for offset, part in enumerate(text[i:end].split("\n")):
                found.append((line + offset, part))
            line += text.count("\n", i, end)
            i = end
        else:
            if c == "\n":
                line += 1
            i += 1
    return found


def hash_comments(text, python):
    """(line, comment text) for `#` comments, and docstrings in Python."""
    found = []
    in_doc = None
    for number, raw in enumerate(text.split("\n"), start=1):
        if in_doc:
            found.append((number, raw))
            if in_doc in raw:
                in_doc = None
            continue
        stripped = raw.lstrip()
        if python and stripped[:3] in ('"""', "'''"):
            quote = stripped[:3]
            found.append((number, raw))
            if stripped.count(quote) < 2:
                in_doc = quote
            continue
        quote = None
        for index, c in enumerate(raw):
            if quote:
                if c == quote and raw[index - 1] != "\\":
                    quote = None
            elif c in "'\"":
                quote = c
            elif c == "#" and (index == 0 or raw[index - 1] in " \t"):
                found.append((number, raw[index:]))
                break
    return found


def tracked_under(directory):
    """Files git tracks under `directory`, or None outside a repository —
    so what git ignores, such as a checked-out dependency, is not searched."""
    result = subprocess.run(
        ["git", "-C", directory, "ls-files", "-z", "--full-name", "."],
        capture_output=True, text=True)
    if result.returncode != 0:
        return None
    top = subprocess.run(
        ["git", "-C", directory, "rev-parse", "--show-toplevel"],
        capture_output=True, text=True).stdout.strip()
    return [os.path.join(top, name) for name in result.stdout.split("\0") if name]


def files_under(paths):
    for path in paths:
        if os.path.isdir(path):
            tracked = tracked_under(path)
            if tracked is None:
                tracked = [os.path.join(root, name)
                           for root, _, names in os.walk(path) for name in sorted(names)]
            for name in sorted(tracked):
                if os.path.splitext(name)[1] in SCRIPTS and os.path.isfile(name):
                    yield name
        elif os.path.isfile(path):
            yield path


def findings(path, everywhere):
    with open(path, "rb") as handle:
        raw = handle.read()
    # Media fixtures have no extension either; text has no NUL bytes.
    if b"\0" in raw:
        return []
    text = raw.decode("utf-8", errors="replace")
    if everywhere:
        return [(n, l) for n, l in enumerate(text.split("\n"), start=1) if CJK.search(l)]
    extension = os.path.splitext(path)[1]
    if extension in C_LIKE:
        comments = c_comments(text)
    elif extension in HASH:
        comments = hash_comments(text, python=extension == ".py")
    else:
        return []
    return [(n, l) for n, l in comments if CJK.search(l)]


def main(argv):
    if len(argv) < 2 or argv[0] not in ("--everywhere", "--comments"):
        print(__doc__, file=sys.stderr)
        return 2
    everywhere = argv[0] == "--everywhere"
    count = 0
    for path in files_under(argv[1:]):
        for number, text in findings(path, everywhere):
            print(f"{path}:{number}: {text.strip()}")
            count += 1
    return 1 if count else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
