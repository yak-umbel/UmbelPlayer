#!/bin/bash
# Cases for Tools/check_names.py.
#
# Each runs in a scratch repository with a list of made-up names, so the
# real list is neither needed nor exposed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../check_names.py"
FAILURES=0

echo "test_check_names"

make_repo() {
  local root="$1"
  git -C "$root" init -q
  git -C "$root" config user.email "test@example.invalid"
  git -C "$root" config user.name "test"
  git -C "$root" config commit.gpgsign false
  mkdir -p "$root/Sources/Core" "$root/Sources/Engine"
  printf 'let clean = 1\n' > "$root/Sources/Core/Clean.swift"
  cat > "$(git -C "$root" rev-parse --absolute-git-dir)/info/umbel-names" <<'LIST'
# players
Fooplay
Bar Viewer
# a prefix
ZED_ENV_*
# allowed in one place
Sysplay allow:Sources/Engine/
# not ASCII
甲乙
# ending in punctuation
/home/someone/
LIST
  git -C "$root" add -A && git -C "$root" commit -q -m "start"
}

expect() {
  local label="$1" want="$2" root="$3"; shift 3
  (cd "$root" && python3 "$SCRIPT" "$@") >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    echo "  ✓ $label"
  else
    echo "  ✗ ${label}: expected exit ${want}, got $got"
    FAILURES=$((FAILURES + 1))
  fi
}

run_case() {
  local label="$1" want="$2" setup="$3"; shift 3
  local root
  root="$(mktemp -d)"
  make_repo "$root"
  (cd "$root" && eval "$setup")
  expect "$label" "$want" "$root" "$@"
  rm -rf "$root"
}

run_case "a clean tree passes" 0 'true' tree
run_case "a name in a file fails, whatever its case" 1 \
  'printf "// as FOOPLAY does\n" >> Sources/Core/Clean.swift' tree
run_case "a name inside a longer word passes" 0 \
  'printf "let fooplayer = 1\n" >> Sources/Core/Clean.swift' tree
run_case "a name ending a longer word passes" 0 \
  'printf "let myfooplay = 1\n" >> Sources/Core/Clean.swift' tree
run_case "a two-word name fails" 1 \
  'printf "// the bar viewer way\n" >> Sources/Core/Clean.swift' tree
run_case "one word of a two-word name passes" 0 \
  'printf "// the bar is open\n" >> Sources/Core/Clean.swift' tree
run_case "a prefix matches what follows it" 1 \
  'printf "let key = \"ZED_ENV_HOME\"\n" >> Sources/Core/Clean.swift' tree
run_case "an allowed name passes where it is allowed" 0 \
  'printf "import Sysplay\n" > Sources/Engine/E.swift && git add -A' tree
run_case "an allowed name fails elsewhere" 1 \
  'printf "// like Sysplay\n" >> Sources/Core/Clean.swift' tree
run_case "a name not in ASCII matches inside other text" 1 \
  'printf "// 这是甲乙的做法\n" >> Sources/Core/Clean.swift' tree
run_case "a name in a path fails" 1 \
  'mkdir -p Notes && printf "x\n" > Notes/fooplay.txt && git add -A' tree
run_case "a name ending in punctuation matches what follows it" 1 \
  'printf "// built in /home/someone/work\n" >> Sources/Core/Clean.swift' tree
run_case "a staged file not in UTF-8 is scanned, not a crash" 0 \
  'printf "\\xcd\\xe2\\xb9\\xd2 clean\\n" > Sources/Core/gbk.srt && git add -A' staged
run_case "a name beside text not in UTF-8 is found" 1 \
  'printf "\\xcd\\xe2 Fooplay\\n" > Sources/Core/gbk.srt && git add -A' staged
run_case "a binary file is skipped" 0 \
  'printf "Fooplay\0\0" > Sources/Core/blob.bin && git add -A' tree
run_case "a staged line with a name fails" 1 \
  'printf "// Fooplay\n" >> Sources/Core/Clean.swift && git add -A' staged
run_case "removing a line with a name passes" 0 \
  'printf "// Fooplay\n" >> Sources/Core/Clean.swift && git add -A && git commit -q -m x --no-verify && printf "let clean = 1\n" > Sources/Core/Clean.swift && git add -A' staged
run_case "a message with a name fails" 1 \
  'printf "fix: behave as fooplay does\n" > msg' message msg
run_case "comment lines of a message are ignored" 0 \
  'printf "fix: a thing\n# Fooplay.swift | 2 +-\n" > msg' message msg
run_case "a commit whose message has a name fails" 1 \
  'git commit -q --allow-empty -m "like Fooplay"' commits HEAD
run_case "a commit adding a name fails" 1 \
  'printf "// Fooplay\n" >> Sources/Core/Clean.swift && git commit -q -am x' commits HEAD
run_case "clean commits pass" 0 \
  'printf "let more = 2\n" >> Sources/Core/Clean.swift && git commit -q -am "more"' commits HEAD
run_case "without the list the check fails" 1 \
  'rm "$(git rev-parse --absolute-git-dir)/info/umbel-names"' tree
run_case "without the list, --if-available skips" 0 \
  'rm "$(git rev-parse --absolute-git-dir)/info/umbel-names"' tree --if-available

# ── The hooks, end to end ───────────────────────────────

# A repository using the hooks, with the checker where they look for it, and
# a bare remote to push to.
make_hooked_repo() {
  local root="$1"
  mkdir -p "$root/work"
  make_repo "$root/work"
  git init -q --bare "$root/remote.git"
  mkdir -p "$root/work/Tools"
  cp "$SCRIPT" "$root/work/Tools/check_names.py"
  cp -R "$HERE/../githooks" "$root/work/Tools/githooks"
  git -C "$root/work" add -A && git -C "$root/work" commit -q -m "tools"
  git -C "$root/work" config core.hooksPath Tools/githooks
  git -C "$root/work" remote add origin "$root/remote.git"
}

run_hook_case() {
  local label="$1" want="$2" action="$3"
  local root
  root="$(mktemp -d)"
  make_hooked_repo "$root"
  (cd "$root/work" && eval "$action") >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    echo "  ✓ $label"
  else
    echo "  ✗ ${label}: expected exit ${want}, got $got"
    FAILURES=$((FAILURES + 1))
  fi
  rm -rf "$root"
}

run_hook_case "committing a name is refused" 1 \
  'printf "// Fooplay\n" >> Sources/Core/Clean.swift && git commit -q -am "x"'
run_hook_case "a message with a name is refused" 1 \
  'git commit -q --allow-empty -m "as fooplay does"'
run_hook_case "a clean commit goes through" 0 \
  'printf "let more = 2\n" >> Sources/Core/Clean.swift && git commit -q -am "more"'
run_hook_case "pushing a clean branch goes through" 0 \
  'git push -q origin HEAD:refs/heads/main'
run_hook_case "pushing a name that slipped past is refused" 1 \
  'git commit -q --allow-empty --no-verify -m "as fooplay does" && git push -q origin HEAD:refs/heads/main'
run_hook_case "pushing more onto a remote branch checks the new commits" 1 \
  'git push -q origin HEAD:refs/heads/main && printf "// Fooplay\n" >> Sources/Core/Clean.swift && git commit -q --no-verify -am x && git push -q origin HEAD:refs/heads/main'

if [ "$FAILURES" -eq 0 ]; then
  echo "✓ all passed"
  exit 0
fi
echo "✗ ${FAILURES} failed"
exit 1
