#!/bin/bash
# Cases for Tools/check_realtime_tests.sh.
#
# The check is given test lists made up here, so the real suite is not built.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$HERE/.."
FAILURES=0

echo "test_check_realtime_tests"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/realtime-check.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# A list that holds a test of every class the real file names.
full_list() {
  # shellcheck source=../realtime_tests.sh
  source "$TOOLS/realtime_tests.sh"
  local name
  for name in "${UMBEL_REALTIME_CLASSES[@]}"; do
    echo "${UMBEL_REALTIME_MODULE}.${name}/testSomething"
  done
  echo "${UMBEL_REALTIME_MODULE}.PlaybackSessionTests/testOther"
  echo "UmbelUITests.SmallWindowTests/testElsewhere"
}

expect_exit() {
  local label="$1" want="$2" list="$3"
  "$TOOLS/check_realtime_tests.sh" "$list" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    echo "  ✓ $label"
  else
    echo "  ✗ ${label}: expected exit ${want}, got $got"
    FAILURES=$((FAILURES + 1))
  fi
}

full_list > "$SCRATCH/full.txt"
expect_exit "every named class has tests" 0 "$SCRATCH/full.txt"

grep -v 'SystemTimelineClockTests' "$SCRATCH/full.txt" > "$SCRATCH/renamed.txt"
expect_exit "a class that no longer exists is refused" 1 "$SCRATCH/renamed.txt"

sed 's/^UmbelCoreTests\.HTTPTransportTests/UmbelOtherTests.HTTPTransportTests/' "$SCRATCH/full.txt" > "$SCRATCH/moved.txt"
expect_exit "a class that moved to another module is refused" 1 "$SCRATCH/moved.txt"

# The pattern must hold the named classes and nothing else.
# shellcheck source=../realtime_tests.sh
source "$TOOLS/realtime_tests.sh"
matched=$(grep -cE "$UMBEL_REALTIME_TESTS" "$SCRATCH/full.txt")
if [ "$matched" -eq "${#UMBEL_REALTIME_CLASSES[@]}" ]; then
  echo "  ✓ the pattern takes the named classes and no other"
else
  echo "  ✗ the pattern matched ${matched} tests, expected ${#UMBEL_REALTIME_CLASSES[@]}"
  FAILURES=$((FAILURES + 1))
fi

if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
  exit 0
fi
echo "${FAILURES} failed"
exit 1
