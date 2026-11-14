#!/usr/bin/env python3
"""Add a DV configuration box to an MP4's HEVC sample entry, for test fixtures.

A DV stream says what it is in a small box beside its hvcC: the version,
profile, level, which layers are present and what the base layer is
compatible with. FFmpeg writes it only when copying from a file that has
one; this writes it from the box's public layout into a file encoded by the
system's HEVC encoder, so the fixtures need neither a DV encoder nor a
DV-carrying source.

    python3 Tools/make_dovi_config.py in.mp4 out.mp4 --profile 5 --level 3 \
        --compatibility 0 [--entry dvhe] [--no-arrays]

--no-arrays empties the hvcC's parameter set arrays, for a stream that
carries them itself (see Tools/make_inband_hevc.py).

The box is dvcC for profiles up to 7, dvvC for 8 to 10. The file's moov
must follow its mdat (ffmpeg's default): the box goes into moov, and chunk
offsets into mdat stay as they are.

Standard library only.
"""

import argparse
import struct

CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl"}


def record(profile, level, compatibility):
    """The 24-byte payload: version 1.0, RPU and base layer present."""
    flags = (profile << 9) | (level << 3) | (1 << 2) | (0 << 1) | 1
    return bytes([1, 0]) + struct.pack(">H", flags) + bytes([compatibility << 4]) + bytes(19)


def boxes(data, start, end):
    at = start
    while at + 8 <= end:
        size, kind = struct.unpack(">I4s", data[at:at + 8])
        if size < 8:
            raise SystemExit("unsupported box size at %d" % at)
        yield at, size, kind
        at += size


def bare_hvcc(body):
    """An hvcC record's 22 bytes of profile and format, and no arrays."""
    return body[:22] + b"\x00"


def rewrite(data, start, end, payload, entry, no_arrays=False):
    """Copies [start, end), growing the path down to the HEVC sample entry."""
    out = bytearray()
    for at, size, kind in boxes(data, start, end):
        body = data[at + 8:at + size]
        if kind in CONTAINERS:
            body = rewrite(data, at + 8, at + size, payload, entry, no_arrays)
        elif kind == b"stsd":
            # Full box header (4) and entry count (4), then the entries.
            head = data[at + 8:at + 16]
            body = head + rewrite(data, at + 16, at + size, payload, entry, no_arrays)
        elif kind in (b"hvc1", b"hev1", b"dvh1", b"dvhe"):
            # Visual sample entry: 78 bytes before its own boxes.
            inner = data[at + 8 + 78:at + size]
            if no_arrays:
                boxes_out = bytearray()
                for child_at, child_size, child_kind in boxes(inner, 0, len(inner)):
                    child = inner[child_at + 8:child_at + child_size]
                    if child_kind == b"hvcC":
                        child = bare_hvcc(child)
                    boxes_out += struct.pack(">I4s", 8 + len(child), child_kind) + child
                inner = bytes(boxes_out)
            body = data[at + 8:at + 8 + 78] + inner + payload
            kind = entry or kind
        out += struct.pack(">I4s", 8 + len(body), kind) + body
    return bytes(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("target")
    parser.add_argument("--profile", type=int, required=True)
    parser.add_argument("--level", type=int, default=3)
    parser.add_argument("--compatibility", type=int, required=True)
    parser.add_argument("--entry", help="rename the sample entry, as dvhe or dvh1")
    parser.add_argument("--no-arrays", action="store_true",
                        help="empty the hvcC's parameter set arrays")
    options = parser.parse_args()
    data = open(options.source, "rb").read()
    top = list(boxes(data, 0, len(data)))
    kinds = [kind for _, _, kind in top]
    if kinds.index(b"moov") < kinds.index(b"mdat"):
        raise SystemExit("moov comes before mdat: chunk offsets would move")
    name = b"dvcC" if options.profile <= 7 else b"dvvC"
    payload = struct.pack(">I4s", 32, name) + record(
        options.profile, options.level, options.compatibility)
    entry = options.entry.encode() if options.entry else None
    open(options.target, "wb").write(
        rewrite(data, 0, len(data), payload, entry, options.no_arrays))


if __name__ == "__main__":
    main()
