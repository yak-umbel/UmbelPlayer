#!/bin/bash
# Independence guard: exits non-zero on any violation, which fails CI.
#
# Names that must stay out of the repository — host apps, trademarks and
# others — are Tools/check_names.py's, from a list kept out of it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/Sources/UmbelCore"
FAIL=0

report() {
  echo "✗ $1"
  FAIL=1
}

# UmbelCore depends on no UI framework.
if [ -d "$CORE" ]; then
  if hits=$(grep -rInE '^[[:space:]]*import[[:space:]]+(UIKit|AppKit|SwiftUI)' "$CORE" 2>/dev/null); then
    report "UmbelCore imports a UI framework (UI code belongs in UmbelUI):"
    echo "$hits" | sed 's/^/    /'
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  echo "✓ independence check passed"
fi
exit "$FAIL"
