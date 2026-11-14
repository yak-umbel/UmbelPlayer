#!/usr/bin/env python3
"""Write a small Blu-ray PGS subtitle stream (.sup) for test fixtures.

FFmpeg decodes PGS but has no encoder for it, so the fixtures need their
own. This writes the format from its public description: every display set
is a presentation composition (PCS), window definition (WDS), palette
(PDS), picture object (ODS) and end segment; clearing the screen is a
composition with no objects. Pictures are run-length encoded.

Standard library only. Each event is a solid rectangle in one colour, which
is all the tests need: a known shape, at a known place, at a known time.

    python3 Tools/make_pgs.py out.sup
"""

import struct
import sys

CANVAS = (320, 240)
FRAME_RATE_CODE = 0x10  # conventional value; players ignore it
TICKS = 90_000          # PGS timestamps count 90 kHz ticks

# (start seconds, end seconds, x, y, width, height, (Y, Cr, Cb, alpha), forced)
EVENTS = [
    (0.5, 2.0, 110, 200, 100, 20, (235, 128, 128, 255), False),  # white, bottom centre
    (2.5, 3.5, 40, 20, 60, 30, (81, 240, 90, 255), True),        # red, top left, forced
]


def segment(kind, pts, payload):
    """PG magic, PTS, DTS (unused, zero), type, size, payload."""
    return b"PG" + struct.pack(">IIBH", pts, 0, kind, len(payload)) + payload


def composition(number, objects, pts):
    """PCS. `objects` is a list of (object id, x, y, forced)."""
    state = 0x80 if objects else 0x00  # epoch start when showing, normal when clearing
    payload = struct.pack(
        ">HHBHBBBB", CANVAS[0], CANVAS[1], FRAME_RATE_CODE, number, state,
        0, 0, len(objects))
    for object_id, x, y, forced in objects:
        flags = 0x40 if forced else 0x00
        payload += struct.pack(">HBBHH", object_id, 0, flags, x, y)
    return segment(0x16, pts, payload)


def window(x, y, width, height, pts):
    return segment(0x17, pts, struct.pack(">BBHHHH", 1, 0, x, y, width, height))


def palette(colour, pts):
    """Entry 0 stays transparent; entry 1 is the event's colour."""
    y, cr, cb, alpha = colour
    return segment(0x14, pts, struct.pack(">BB", 0, 0) + bytes([1, y, cr, cb, alpha]))


def encode_rle(width, height):
    """Every pixel is palette entry 1: one long run per line, then end of line."""
    line = bytes([0x00, 0xC0 | (width >> 8), width & 0xFF, 1, 0x00, 0x00])
    return line * height


def picture(width, height, pts):
    data = struct.pack(">HH", width, height) + encode_rle(width, height)
    # Object data length counts the width and height fields too; 24 bits.
    length = len(data)
    payload = struct.pack(">HBB", 1, 0, 0xC0) + length.to_bytes(3, "big") + data
    return segment(0x15, pts, payload)


def end(pts):
    return segment(0x80, pts, b"")


def main(path, events=EVENTS):
    out = bytearray()
    number = 0
    for start, stop, x, y, width, height, colour, forced in events:
        show = int(start * TICKS)
        out += composition(number, [(1, x, y, forced)], show)
        out += window(x, y, width, height, show)
        out += palette(colour, show)
        out += picture(width, height, show)
        out += end(show)
        number += 1

        clear = int(stop * TICKS)
        out += composition(number, [], clear)
        out += window(x, y, width, height, clear)
        out += end(clear)
        number += 1
    with open(path, "wb") as handle:
        handle.write(out)


if __name__ == "__main__":
    main(sys.argv[1])
