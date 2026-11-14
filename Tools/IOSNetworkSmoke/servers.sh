#!/bin/bash
# Servers on this Mac for the smoke tests: an SSH server and a Samba server, each on a port of its own, with
# a private configuration, run as the user. Only what is installed is started: Samba comes from
# `brew install samba`, and without it the SMB tests skip.
#
#   servers.sh start [address]   address: what they listen on, 127.0.0.1 unless said (a LAN address for a device)
#   servers.sh stop
#
# `start` writes tmp/ios-smoke/env.sh, which a test run sources: `TEST_RUNNER_…` reaches the test process
# without the prefix. The directory is short because Samba makes Unix sockets in it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/tmp/ios-smoke"
STATE="$(getconf DARWIN_USER_TEMP_DIR)umbel-ios-smoke"
SSH_PORT=22731
SMB_PORT=24731
USER_NAME="$(whoami)"
PASSWORD="smoke-pass-1"
SMBD=""; PDBEDIT=""
for dir in /opt/homebrew /usr/local; do
  [ -x "$dir/sbin/samba-dot-org-smbd" ] && [ -x "$dir/bin/pdbedit" ] && { SMBD="$dir/sbin/samba-dot-org-smbd"; PDBEDIT="$dir/bin/pdbedit"; break; }
done
mkdir -p "$WORK"

stop() {
  for f in "$STATE/sshd.pid" "$STATE/smbd.pid"; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null || true
  done
  sleep 1
  case "$STATE" in */umbel-ios-smoke) rm -rf "${STATE:?}" ;; esac
  rm -f "$WORK/env.sh"
}

listening() { for _ in $(seq 1 100); do lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }

# Each server in a session of its own, started directly so that $! is the server: Samba tells its whole
# process group to end when it ends, which is this script's when it was started from it.
start() {
  local address="${1:-127.0.0.1}"
  stop
  mkdir -p "$STATE/ssh/served" "$STATE/smb/share" "$STATE/smb/private" "$STATE/smb/lock" "$STATE/smb/state" "$STATE/smb/cache" "$STATE/smb/pid" "$STATE/smb/ncalrpc"
  python3 - "$STATE/smb/share/movie.bin" <<'PY'
import sys
size = 1_500_000
open(sys.argv[1], "wb").write(bytes((i * 31 + (i >> 8)) & 0xFF for i in range(size)))
PY
  cp "$STATE/smb/share/movie.bin" "$STATE/ssh/served/movie.bin"
  : > "$WORK/env.sh"
  {
    echo "export TEST_RUNNER_UMBEL_SMOKE_USER='$USER_NAME'"
    echo "export TEST_RUNNER_UMBEL_SMOKE_HOST='$address'"
    echo "export TEST_RUNNER_UMBEL_SMOKE_FILE_SIZE='1500000'"
  } >> "$WORK/env.sh"

  # SSH
  ssh-keygen -q -t ed25519 -N '' -f "$STATE/ssh/host"
  ssh-keygen -q -t ed25519 -N '' -f "$STATE/ssh/client"
  cp "$STATE/ssh/client.pub" "$STATE/ssh/authorized_keys"
  chmod 600 "$STATE/ssh/host" "$STATE/ssh/client" "$STATE/ssh/authorized_keys"
  cat > "$STATE/ssh/sshd_config" <<CFG
Port $SSH_PORT
ListenAddress $address
HostKey $STATE/ssh/host
AuthorizedKeysFile $STATE/ssh/authorized_keys
PidFile $STATE/ssh/sshd.pid
UsePAM no
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
Subsystem sftp /usr/libexec/sftp-server
LogLevel INFO
CFG
  python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' /usr/sbin/sshd -D -e -f "$STATE/ssh/sshd_config" < /dev/null > "$STATE/ssh/sshd.log" 2>&1 &
  echo $! > "$STATE/sshd.pid"
  listening "$SSH_PORT" || { echo "sshd did not come up"; cat "$STATE/ssh/sshd.log"; exit 1; }
  {
    echo "export TEST_RUNNER_UMBEL_SMOKE_SSH_PORT='$SSH_PORT'"
    echo "export TEST_RUNNER_UMBEL_SMOKE_SSH_KEY='$STATE/ssh/client'"
    echo "export TEST_RUNNER_UMBEL_SMOKE_SSH_FINGERPRINT='$(ssh-keygen -l -E sha256 -f "$STATE/ssh/host.pub" | awk '{print $2}')'"
    echo "export TEST_RUNNER_UMBEL_SMOKE_SSH_FILE='$STATE/ssh/served/movie.bin'"
  } >> "$WORK/env.sh"
  echo "ssh: $address:$SSH_PORT"

  # Samba
  if [ -z "$SMBD" ]; then echo "smb: Samba is not installed (brew install samba); the SMB tests will skip"; return 0; fi
  cat > "$STATE/smb/smb.conf" <<CFG
[global]
  server role = standalone server
  workgroup = TESTGROUP
  netbios name = UMBELSMOKE
  security = user
  map to guest = Bad User
  guest account = $USER_NAME
  passdb backend = tdbsam:$STATE/smb/private/passdb.tdb
  private dir = $STATE/smb/private
  lock directory = $STATE/smb/lock
  state directory = $STATE/smb/state
  cache directory = $STATE/smb/cache
  pid directory = $STATE/smb/pid
  ncalrpc dir = $STATE/smb/ncalrpc
  log file = $STATE/smb/log.%m
  max log size = 1000
  smb ports = $SMB_PORT
  interfaces = $address
  bind interfaces only = yes
  disable netbios = yes
  load printers = no
  printcap name = /dev/null
  disable spoolss = yes
  server min protocol = SMB2
  usershare max shares = 0
  smb encrypt = desired

[share]
  path = $STATE/smb/share
  read only = yes
  guest ok = no

[open]
  path = $STATE/smb/share
  read only = yes
  guest ok = yes
CFG
  printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" | "$PDBEDIT" -s "$STATE/smb/smb.conf" -a -u "$USER_NAME" -t >/dev/null 2>&1
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" LANG=C python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$SMBD" --foreground --no-process-group -s "$STATE/smb/smb.conf" < /dev/null > "$STATE/smb/smbd.out" 2>&1 &
  echo $! > "$STATE/smbd.pid"
  listening "$SMB_PORT" || { echo "smbd did not come up"; cat "$STATE/smb/smbd.out"; exit 1; }
  {
    echo "export TEST_RUNNER_UMBEL_SMOKE_SMB_PORT='$SMB_PORT'"
    echo "export TEST_RUNNER_UMBEL_SMOKE_SMB_PASSWORD='$PASSWORD'"
  } >> "$WORK/env.sh"
  echo "smb: $address:$SMB_PORT"
}

case "${1:-}" in
  start) start "${2:-127.0.0.1}" ;;
  stop) stop ;;
  *) echo "usage: servers.sh start [address] | stop" >&2; exit 2 ;;
esac
