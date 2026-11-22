#!/usr/bin/env python3
"""Write a tiny TrueType font for test fixtures.

The tests need a font that covers characters no system font has, so that a
line set in them is drawn from this font or not at all, on every machine.
Four filled boxes sit at U+E000...U+E003 in the Private Use Area, each of a
different width, so that a line's width tells which font drew it.

Written from the TrueType table layouts as the OpenType specification
describes them: head, hhea, maxp, OS/2, hmtx, cmap (format 4), loca, glyf,
name and post. Standard library only; the output is deterministic.

    python3 Tools/make_test_font.py Tests/Fixtures/fonts/PrivateUseBoxes.ttf
"""

import struct
import sys

FAMILY = "Private Use Boxes"
STYLE = "Regular"
POSTSCRIPT = "PrivateUseBoxes-Regular"

UNITS_PER_EM = 1000
ASCENDER = 800
DESCENDER = -200
FIRST_CODE = 0xE000
BOX_HEIGHT = 700
LEFT_BEARING = 100
# Advance widths of the four boxes; the ink is 200 narrower than the advance.
ADVANCES = [800, 600, 1000, 700]
NOTDEF_ADVANCE = 500


def pad4(data):
    return data + b"\0" * (-len(data) % 4)


def checksum(data):
    data = pad4(data)
    return sum(struct.unpack(">%dI" % (len(data) // 4), data)) & 0xFFFFFFFF


def sized(data, length):
    assert len(data) == length, (len(data), length)
    return data


def box(advance):
    """A clockwise rectangle: the outline of one simple glyph."""
    right = advance - LEFT_BEARING
    xs = [LEFT_BEARING, LEFT_BEARING, right, right]
    ys = [0, BOX_HEIGHT, BOX_HEIGHT, 0]
    data = struct.pack(">hhhhh", 1, min(xs), min(ys), max(xs), max(ys))
    data += struct.pack(">H", 3)            # last point of the only contour
    data += struct.pack(">H", 0)            # no instructions
    data += bytes([1] * 4)                  # every point on the curve, 16-bit deltas
    for values in (xs, ys):
        previous = 0
        for value in values:
            data += struct.pack(">h", value - previous)
            previous = value
    return pad4(data)


def glyph_tables():
    glyphs = [b""] + [box(advance) for advance in ADVANCES]  # glyph 0 is empty
    offsets = [0]
    for glyph in glyphs:
        offsets.append(offsets[-1] + len(glyph))
    widths = [NOTDEF_ADVANCE] + ADVANCES
    hmtx = b"".join(
        struct.pack(">Hh", width, LEFT_BEARING if index else 0)
        for index, width in enumerate(widths))
    return {
        b"glyf": b"".join(glyphs),
        b"loca": struct.pack(">%dI" % len(offsets), *offsets),  # long format
        b"hmtx": hmtx,
    }, widths


def cmap_table(last):
    """Format 4: one segment for the boxes, one closing segment."""
    segments = 2
    subtable = struct.pack(">HHHHHHH", 4, 32, 0, segments * 2, 4, 1, 0)
    subtable += struct.pack(">HH", last, 0xFFFF)                       # end codes
    subtable += struct.pack(">H", 0)                                   # reserved
    subtable += struct.pack(">HH", FIRST_CODE, 0xFFFF)                 # start codes
    subtable += struct.pack(">HH", (1 - FIRST_CODE) & 0xFFFF, 1)       # code to glyph 1...
    subtable += struct.pack(">HH", 0, 0)                               # no glyph array
    sized(subtable, 32)
    return struct.pack(">HH", 0, 1) + struct.pack(">HHI", 3, 1, 12) + subtable


def head_table():
    return sized(
        struct.pack(">IIII", 0x00010000, 0x00010000, 0, 0x5F0F3CF5)    # adjustment: later
        + struct.pack(">HH", 0x000B, UNITS_PER_EM)
        + struct.pack(">qq", 0, 0)
        + struct.pack(">hhhh", LEFT_BEARING, 0, max(ADVANCES) - LEFT_BEARING, BOX_HEIGHT)
        + struct.pack(">HHhhh", 0, 8, 2, 1, 0), 54)


def hhea_table(widths, count):
    extent = max(ADVANCES) - LEFT_BEARING
    return sized(
        struct.pack(">I", 0x00010000)
        + struct.pack(">hhh", ASCENDER, DESCENDER, 0)
        + struct.pack(">H", max(widths))
        + struct.pack(">hhh", LEFT_BEARING, LEFT_BEARING, extent)
        + struct.pack(">hhh", 1, 0, 0)
        + bytes(8) + struct.pack(">h", 0)
        + struct.pack(">H", count), 36)


def maxp_table(count):
    return sized(
        struct.pack(">IH", 0x00010000, count)
        + struct.pack(">HHHHH", 4, 1, 0, 0, 1)
        + bytes(2 * 8), 32)


def os2_table(widths, last):
    data = struct.pack(">HhHHH", 1, sum(widths) // len(widths), 400, 5, 0)
    data += bytes(2 * 11)                                              # sub/superscript, strikeout, class
    data += bytes(10)                                                  # PANOSE
    data += struct.pack(">IIII", 0, 1 << 28, 0, 0)                     # Unicode ranges: Private Use
    data += b"NONE"
    data += struct.pack(">HHH", 0x0040, FIRST_CODE, last)
    data += struct.pack(">hhhHH", ASCENDER, DESCENDER, 0, ASCENDER, -DESCENDER)
    data += struct.pack(">II", 1, 0)                                   # code pages: Latin 1
    return sized(data, 86)


def name_table():
    strings = {1: FAMILY, 2: STYLE, 4: FAMILY + " " + STYLE, 6: POSTSCRIPT}
    storage = b""
    records = b""
    for name_id in sorted(strings):
        encoded = strings[name_id].encode("utf-16-be")
        records += struct.pack(">HHHHHH", 3, 1, 0x409, name_id, len(encoded), len(storage))
        storage += encoded
    return struct.pack(">HHH", 0, len(strings), 6 + len(records)) + records + storage


def post_table():
    return sized(struct.pack(">IIhhIIIII", 0x00030000, 0, -100, 50, 0, 0, 0, 0, 0), 32)


def build():
    parts, widths = glyph_tables()
    count = len(widths)
    last = FIRST_CODE + len(ADVANCES) - 1
    parts.update({
        b"OS/2": os2_table(widths, last), b"cmap": cmap_table(last),
        b"head": head_table(), b"hhea": hhea_table(widths, count),
        b"maxp": maxp_table(count), b"name": name_table(), b"post": post_table(),
    })
    tags = sorted(parts)
    # The offset table: how many tables, and the search values for that count.
    header = struct.pack(">IHHHH", 0x00010000, len(tags), 128, 3, len(tags) * 16 - 128)
    directory = b""
    body = b""
    head_at = 0
    for tag in tags:
        offset = 12 + len(tags) * 16 + len(body)
        if tag == b"head":
            head_at = offset
        directory += tag + struct.pack(">III", checksum(parts[tag]), offset, len(parts[tag]))
        body += pad4(parts[tag])
    font = bytearray(header + directory + body)
    # head.checkSumAdjustment makes the whole file sum to a fixed value.
    adjustment = (0xB1B0AFBA - checksum(bytes(font))) & 0xFFFFFFFF
    font[head_at + 8:head_at + 12] = struct.pack(">I", adjustment)
    return bytes(font)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(sys.argv[1], "wb") as out:
        out.write(build())
