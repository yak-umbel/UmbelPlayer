#!/bin/bash
# Requires a built macOS umbel-play executable as its only argument.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLAYER="${1:?usage: test_playback_diagnostics_cli.sh <umbel-play executable>}"
TRACE_DIR="$(mktemp -d)"
trap 'rm -rf "$TRACE_DIR"' EXIT

# This file source cannot resolve the playlist's relative segment URLs.
STATUS=0
"$PLAYER" "$ROOT/Tests/Fixtures/hls/ad.m3u8" 1 --no-sound --diagnostics \
  >"$TRACE_DIR/failure.log" 2>&1 || STATUS=$?
if [ "$STATUS" -ne 1 ]; then
  echo "expected load failure with exit 1, got $STATUS"
  exit 1
fi

STATUS=0
"$PLAYER" "$ROOT/Tests/Fixtures/external_bom.ass" 1 --no-sound --diagnostics \
  >"$TRACE_DIR/no-tracks.log" 2>&1 || STATUS=$?
if [ "$STATUS" -ne 1 ]; then
  echo "expected rejection of subtitle-only media with exit 1, got $STATUS"
  exit 1
fi

python3 - "$TRACE_DIR/failure.log" "$TRACE_DIR/no-tracks.log" <<'PY'
import json
import sys

prefix = "[playback-diagnostic] "
for path, loaded in [(sys.argv[1], False), (sys.argv[2], True)]:
    with open(path, encoding="utf-8") as trace:
        lines = trace.readlines()
    events = [json.loads(line[len(prefix):]) for line in lines if line.startswith(prefix)]
    assert any(event["name"] == "session_open" for event in events), f"{path}: lost session_open diagnostics"
    assert any(event["name"] == "session_loaded" for event in events) == loaded, f"{path}: wrong load result"
    if not loaded:
        assert any(line.startswith("failed:") for line in lines), "expected a load failure"
    else:
        assert any("neither a video track" in line for line in lines), "expected no playable tracks"
    sequences = [event["sequence"] for event in events]
    assert sequences == list(range(1, len(events) + 1)), f"{path}: export lost or duplicated events"
    print(f"{'no playable tracks' if loaded else 'load failure'} exported {len(events)} ordered diagnostics")
PY
