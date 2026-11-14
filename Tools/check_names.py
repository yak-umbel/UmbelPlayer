#!/usr/bin/env python3
"""Keep names that must not appear out of what is committed.

The names themselves are not in the repository: they are read from a list
kept in the git directory (`info/umbel-names`), which is never pushed. One
name per line; blank lines and lines starting with `#` are ignored:

    SomeName
    SOME_PREFIX_*
    OtherName allow:Sources/Allowed/
    Two Words

- ASCII names match whole words, ignoring case: a name inside a longer word
  does not count. A `*` at either end drops the word boundary on that side;
  so does punctuation there (`/some/path/`).
- Other names match anywhere.
- `allow:` lists path prefixes where the name may appear.

Usage:

    check_names.py tree               every tracked file: its path and text
    check_names.py staged             paths and lines added in the index
    check_names.py message FILE       a commit message
    check_names.py commits REV...     each commit's message and added lines

Binary files are skipped. Without the list the check fails, so a hook cannot
pass silently; with --if-available it is skipped with a note instead.
"""

import argparse
import re
import subprocess
import sys


def git(*args):
    # Paths as they are, not quoted and escaped as git shows them by default.
    # Text in other encodings (a GBK subtitle fixture) must not stop the scan:
    # what is not UTF-8 is replaced, and names in ASCII still match.
    return subprocess.run(
        ["git", "-c", "core.quotePath=false", *args],
        check=True, capture_output=True, encoding="utf-8", errors="replace").stdout


def is_word(character):
    return character.isalnum() or character == "_"


class Name:
    def __init__(self, line):
        parts = line.split()
        self.allowed = [p[len("allow:"):] for p in parts if p.startswith("allow:")]
        word = " ".join(p for p in parts if not p.startswith("allow:"))
        open_left = word.startswith("*")
        open_right = word.endswith("*")
        self.word = word.strip("*")
        # Words of a name may be split by any run of spaces, or a line break.
        body = r"\s+".join(re.escape(part) for part in self.word.split())
        if self.word.isascii():
            # A boundary only where the name has a word character to bound:
            # one ending in "/" is followed by a word, not kept from one.
            left = "" if open_left or not is_word(self.word[0]) else r"(?<![A-Za-z0-9_])"
            right = "" if open_right or not is_word(self.word[-1]) else r"(?![A-Za-z0-9_])"
            body = left + body + right
        self.pattern = re.compile(body, re.IGNORECASE)

    def allowed_in(self, path):
        return path is not None and any(path.startswith(prefix) for prefix in self.allowed)


def load_names(path):
    names = []
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if line and not line.startswith("#"):
                names.append(Name(line))
    return names


class Scan:
    def __init__(self, names):
        self.names = names
        self.hits = []

    def text(self, where, text, path=None):
        for name in self.names:
            if name.pattern.search(text) and not name.allowed_in(path):
                self.hits.append(f"{where}: {name.word}")

    def lines(self, path, numbered_lines, label=""):
        """A file's path and lines; `label` goes before the path in reports."""
        self.text(f"{label}{path} (path)", path, path)
        for number, line in numbered_lines:
            self.text(f"{label}{path}:{number}", line, path)


def is_binary(data):
    return b"\0" in data[:8000]


def scan_tree(scan):
    for path in git("ls-files", "-z").split("\0"):
        if not path:
            continue
        try:
            with open(path, "rb") as handle:
                data = handle.read()
        except (FileNotFoundError, IsADirectoryError):
            continue  # deleted in the working tree, or a submodule
        if is_binary(data):
            scan.text(f"{path} (path)", path, path)
            continue
        lines = data.decode("utf-8", errors="replace").splitlines()
        scan.lines(path, enumerate(lines, start=1))


def added_lines(diff):
    """(path, [(line number, text)]) for each file a unified diff adds to."""
    files = {}
    path = None
    number = 0
    for line in diff.splitlines():
        if line.startswith("+++ "):
            target = line[4:]
            path = None if target == "/dev/null" else target[2:] if target.startswith("b/") else target
            if path is not None:
                files.setdefault(path, [])
        elif line.startswith("@@"):
            match = re.search(r"\+(\d+)", line)
            number = int(match.group(1)) if match else 0
        elif line.startswith("+") and path is not None:
            files[path].append((number, line[1:]))
            number += 1
    return files.items()


def scan_staged(scan):
    diff = git("diff", "--cached", "-U0", "--no-color", "--no-ext-diff", "--no-renames")
    for path, lines in added_lines(diff):
        scan.lines(path, lines)


def scan_commits(scan, revisions):
    for commit in git("rev-list", *revisions).split():
        short = commit[:7]
        scan.text(f"commit {short} message", git("log", "-1", "--format=%B", commit))
        diff = git("show", "--format=", "-U0", "--no-color", "--no-ext-diff",
                   "--no-renames", "--first-parent", commit)
        for path, lines in added_lines(diff):
            scan.lines(path, lines, label=f"commit {short} ")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("mode", choices=["tree", "staged", "message", "commits"])
    parser.add_argument("targets", nargs="*")
    parser.add_argument("--list", help="the name list (default: <git dir>/info/umbel-names)")
    parser.add_argument("--if-available", action="store_true",
                        help="skip, rather than fail, when there is no list")
    args = parser.parse_args()

    list_path = args.list or git("rev-parse", "--git-path", "info/umbel-names").strip()
    try:
        names = load_names(list_path)
    except FileNotFoundError:
        if args.if_available:
            print(f"- name check skipped: no list at {list_path}")
            return 0
        print(f"✗ no name list at {list_path}; nothing can be checked", file=sys.stderr)
        return 1

    scan = Scan(names)
    if args.mode == "tree":
        scan_tree(scan)
    elif args.mode == "staged":
        scan_staged(scan)
    elif args.mode == "message":
        for target in args.targets:
            with open(target, encoding="utf-8") as handle:
                # Lines git will strip: the status it lists for the editor.
                kept = [line for line in handle if not line.startswith("#")]
            scan.text("commit message", "".join(kept))
    else:
        scan_commits(scan, args.targets or ["HEAD"])

    if scan.hits:
        print("✗ names that must not be committed:", file=sys.stderr)
        for hit in scan.hits:
            print(f"    {hit}", file=sys.stderr)
        return 1
    print(f"✓ name check passed ({args.mode})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
