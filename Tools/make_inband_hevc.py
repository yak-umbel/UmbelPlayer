#!/usr/bin/env python3
"""Keep an HEVC stream's parameter sets at its start only, for test fixtures.

Some real files carry their VPS, SPS and PPS in the stream rather than in
the MP4's hvcC, and only at the very start (or only beside some pictures):
a player that looks for them in the keyframe it seeks to finds none. This
makes such a stream from an ordinary one: in an Annex B stream, parameter
sets after the first picture are dropped.

    python3 Tools/make_inband_hevc.py in.hevc out.hevc

Standard library only.
"""

import re
import sys

START = re.compile(b"\x00\x00\x01")


def units(data):
    """(start code, unit) pairs; a zero before 00 00 01 is part of the code."""
    starts = [m.start() for m in START.finditer(data)]
    for index, at in enumerate(starts):
        code = at - 1 if at > 0 and data[at - 1] == 0 else at
        end = starts[index + 1] if index + 1 < len(starts) else len(data)
        if index + 1 < len(starts) and data[end - 1] == 0:
            end -= 1
        yield data[code:at + 3], data[at + 3:end]


def main():
    source, target = sys.argv[1], sys.argv[2]
    out = bytearray()
    seen_picture = False
    for code, unit in units(open(source, "rb").read()):
        kind = (unit[0] >> 1) & 0x3F if unit else None
        if kind is not None and kind < 32:
            seen_picture = True
        if seen_picture and kind in (32, 33, 34):
            continue
        out += code + unit
    open(target, "wb").write(bytes(out))


if __name__ == "__main__":
    main()
