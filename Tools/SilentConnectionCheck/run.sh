#!/bin/bash
# Reads through an HTTP/2 connection that goes silent; see README.md.
#
#   Tools/SilentConnectionCheck/run.sh [request timeout in seconds, default 2]
#
# Exits 0 when UmbelHTTPSource with a session maker reads on through the
# silent connection, 1 when it does not, 2 when the check cannot run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/Tools/SilentConnectionCheck"
WORK="$ROOT/tmp/silent-connection-check"
TIMEOUT="${1:-2}"

command -v node >/dev/null || { echo "needs Node.js"; exit 2; }
mkdir -p "$WORK"
if [ ! -f "$WORK/key.pem" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 30 -subj "/CN=127.0.0.1" >/dev/null 2>&1 || { echo "openssl could not make a certificate"; exit 2; }
fi
cd "$ROOT"
if ! "$ROOT/Tools/swift.sh" build --product umbel-silent-connection-check >"$WORK/build.log" 2>&1; then
  echo "build failed; see $WORK/build.log"
  exit 2
fi
CHECK="$("$ROOT/Tools/swift.sh" build --show-bin-path)/umbel-silent-connection-check"

# A fresh relay for each scenario: only its first connection goes silent.
scenario() {
  local name="$1"; shift
  rm -f "$WORK/port"
  node "$HERE/relay.js" "$WORK" >"$WORK/relay-$name.log" 2>&1 &
  local relay=$!
  for _ in $(seq 1 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
  if [ ! -s "$WORK/port" ]; then
    echo "the relay did not start; see $WORK/relay-$name.log"
    kill "$relay" 2>/dev/null
    return 2
  fi
  local mode="$1"; shift
  "$CHECK" "$mode" "$(cat "$WORK/port")" "$@" "$TIMEOUT"
  local status=$?
  kill "$relay" 2>/dev/null
  wait "$relay" 2>/dev/null
  echo "  relay: $(grep -c '"event":"connection"' "$WORK/relay-$name.log") connections," \
    "$(grep -c '"event":"request"' "$WORK/relay-$name.log") requests reached the server"
  return $status
}

echo "── URLSession alone"
scenario system system || exit 2
echo "── UmbelHTTPSource with a session maker"
scenario renew source renew
RESULT=$?
echo "── UmbelHTTPSource without one: a session with a delegate is kept"
scenario keep source keep || exit 2
echo ""
case $RESULT in
  0) echo "✓ the source read on through the silent connection" ;;
  1) echo "✗ the source did not read on through the silent connection" ;;
esac
exit $RESULT
