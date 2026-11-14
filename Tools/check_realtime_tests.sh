#!/bin/bash
# Checks the list of real-time tests in Tools/realtime_tests.sh against the
# tests that exist.
#
# The list is by class name, so a class that is renamed or moved to another
# module would drop out of the group without a word, and its tests would go
# back to deciding the result on the runner. Each name must match tests in
# the module the pattern names.
#
# usage: Tools/check_realtime_tests.sh [LIST_FILE]
#   LIST_FILE holds `swift test list` output; without it the list is made here.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=realtime_tests.sh
source "$HERE/realtime_tests.sh"

list="$(mktemp "${TMPDIR:-/tmp}/realtime-list.XXXXXX")"
trap 'rm -f "$list"' EXIT
if [ "$#" -ge 1 ]; then
  cp "$1" "$list" || exit 2
else
  "$HERE/swift.sh" test list > "$list" || { echo "✗ could not list the tests" >&2; exit 2; }
fi

FAIL=0
for name in "${UMBEL_REALTIME_CLASSES[@]}"; do
  n=$(grep -cE "^${UMBEL_REALTIME_MODULE}\\.${name}/" "$list")
  if [ "$n" -eq 0 ]; then
    echo "✗ ${name}: no test of it in ${UMBEL_REALTIME_MODULE}; renamed or moved? Fix Tools/realtime_tests.sh."
    FAIL=1
  fi
done

in_group=$(grep -cE "$UMBEL_REALTIME_TESTS" "$list")
# Only test lines count; a build's progress lines may be among them.
total=$(grep -cE '^[A-Za-z0-9_]+\.[A-Za-z0-9_]+/' "$list")
if [ "$FAIL" -eq 0 ]; then
  echo "✓ real-time group: ${in_group} of ${total} tests, ${#UMBEL_REALTIME_CLASSES[@]} classes"
fi
exit "$FAIL"
