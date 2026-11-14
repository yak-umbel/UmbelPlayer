#!/usr/bin/env python3
"""Write one raw 4:2:0 frame of exact sample codes, for test fixtures.

Encoders are fed colours through a conversion whose rounding the tests would
then have to guess. Codes written directly are known: a test reading back a
picture checks the player against numbers taken from the standards, not
against another program's conversion.

The top half holds one luma code, the bottom half another, over one chroma
pair. 8-bit writes yuv420p, 10-bit yuv420p10le.

    python3 Tools/make_raw_frame.py out.yuv WIDTH HEIGHT BITS TOP BOTTOM CB CR

Standard library only.
"""

import struct
import sys


def main(path, width, height, bits, top, bottom, cb, cr):
    luma = [top] * (width * height // 2) + [bottom] * (width * height // 2)
    chroma_count = (width // 2) * (height // 2)
    kind = "B" if bits == 8 else "H"
    pack = lambda values: struct.pack("<%d%s" % (len(values), kind), *values)
    with open(path, "wb") as handle:
        handle.write(pack(luma) + pack([cb] * chroma_count) + pack([cr] * chroma_count))


if __name__ == "__main__":
    path, *numbers = sys.argv[1:]
    main(path, *map(int, numbers))
