#!/usr/bin/env python3
"""Serve a directory over HTTP with Range support and a bandwidth cap.

For manual acceptance of network playback. Python's own `http.server` ignores
Range and answers 200 with the whole file, which UmbelHTTPSource rightly
refuses; this one answers 206 as a real server or CDN would.

    python3 Tools/serve_media.py videos --rate 600k
    swift run umbel-play "http://127.0.0.1:8000/<file>" 180

`--rate` caps the total bandwidth, shared by all connections, like a slow
link. Pick it a little below the file's bitrate to make playback run dry
from time to time. Stop the server (Ctrl+C) to simulate the network going
away.

`--send-timeout` closes a connection whose client has taken nothing for that
many seconds, as real servers do (commonly after a minute); without it a
paused player's connection stays open forever, which no real server allows.
`--log` prints one line per request and how it ended. Standard library only.
"""

import argparse
import os
import re
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

CHUNK = 16 * 1024


class Throttle:
    """A token bucket shared by every connection: the cap is on the link."""

    def __init__(self, rate):
        self.rate = rate
        self.lock = threading.Lock()
        self.allowance = 0.0
        self.last = time.monotonic()

    def wait(self, amount):
        if not self.rate:
            return
        while True:
            with self.lock:
                now = time.monotonic()
                # A quarter of a second of burst, no more.
                self.allowance = min(self.rate / 4, self.allowance + (now - self.last) * self.rate)
                self.last = now
                if self.allowance >= amount:
                    self.allowance -= amount
                    return
                needed = (amount - self.allowance) / self.rate
            time.sleep(needed)


def parse_rate(text):
    match = re.fullmatch(r"(\d+(?:\.\d+)?)([kKmM]?)", text)
    if not match:
        raise argparse.ArgumentTypeError("rate looks like 600k or 2M (bytes per second)")
    value, unit = float(match.group(1)), match.group(2).lower()
    return int(value * {"": 1, "k": 1024, "m": 1024 * 1024}[unit])


class Handler(SimpleHTTPRequestHandler):
    # Keep-alive, as real servers do; every response below sets its length.
    protocol_version = "HTTP/1.1"
    throttle = None
    # Applied to the socket by the base class: a send or a wait for the next
    # request that takes longer fails, and the connection is closed.
    timeout = None
    logs = False

    def note(self, text):
        if self.logs:
            print(f"{time.strftime('%H:%M:%S')} {text}", flush=True)

    def send_head(self):
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            self.send_error(404)
            return None
        size = os.path.getsize(path)
        start, end = 0, size - 1
        header = self.headers.get("Range")
        partial = False
        if header:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", header.strip())
            if not match or (not match.group(1) and not match.group(2)):
                self.send_error(416)
                return None
            if match.group(1):
                start = int(match.group(1))
                end = int(match.group(2)) if match.group(2) else size - 1
            else:  # suffix: the last N bytes
                start = max(0, size - int(match.group(2)))
            end = min(end, size - 1)
            if start >= size or start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return None
            partial = True

        self.note(f"{self.command} {header or 'whole file'}")
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        handle = open(path, "rb")
        handle.seek(start)
        self.remaining = end - start + 1
        return handle

    def copyfile(self, source, outputfile):
        sent = 0
        while self.remaining > 0:
            data = source.read(min(CHUNK, self.remaining))
            if not data:
                break
            self.throttle.wait(len(data))
            try:
                outputfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                # The player cancelled the request, as it does on a seek. The
                # connection is gone: waiting on it for another request would
                # only fail again.
                self.note(f"  closed by the client after {sent} bytes")
                self.close_connection = True
                return
            except TimeoutError:
                self.note(f"  timed out after {sent} bytes; closing")
                self.close_connection = True
                return
            self.remaining -= len(data)
            sent += len(data)
        self.note(f"  sent {sent} bytes")

    def log_message(self, format, *args):
        pass  # one line per range request drowns the player's own output


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("directory", help="directory to serve")
    parser.add_argument("--rate", type=parse_rate, default=0,
                        help="bandwidth cap in bytes per second, e.g. 600k or 2M; none if omitted")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--send-timeout", type=float, default=None,
                        help="close a connection idle for this many seconds; never if omitted")
    parser.add_argument("--log", action="store_true", help="print one line per request")
    args = parser.parse_args()

    Handler.throttle = Throttle(args.rate)
    Handler.timeout = args.send_timeout
    Handler.logs = args.log
    os.chdir(args.directory)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    cap = f"{args.rate / 1024:.0f} KiB/s" if args.rate else "no cap"
    print(f"Serving {os.getcwd()} at http://127.0.0.1:{args.port}/ ({cap}). Ctrl+C to stop.",
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
