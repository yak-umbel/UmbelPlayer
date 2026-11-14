#!/usr/bin/env python3
"""Add HDR10 static metadata to an HEVC stream, for test fixtures.

HDR10 files carry two SEI messages next to their pictures: the mastering
display colour volume and the content light level. FFmpeg can write the
colour tags into the bitstream (the hevc_metadata filter) but not these,
short of the GPL x265 encoder; so this writes them from the format's public
description, ITU-T H.265 Annex D.2.28 and D.2.35, into a prefix SEI NAL unit
in front of every random-access picture.

The values are those of a common grade: a P3 D65 mastering display from
0.0001 to 1000 nits, content peaking at 1000 nits with a 400-nit frame
average.

    python3 Tools/make_hdr_sei.py in.hevc out.hevc     # Annex B streams

Standard library only.
"""

import struct
import sys

# Chromaticities in units of 0.00002, green, blue, red as the SEI orders them.
GREEN = (13250, 34500)
BLUE = (7500, 3000)
RED = (34000, 16000)
WHITE = (15635, 16450)
MAX_LUMINANCE = 1000 * 10000   # units of 0.0001 nits
MIN_LUMINANCE = 1
MAX_CONTENT = 1000             # nits
MAX_FRAME_AVERAGE = 400

PREFIX_SEI = 39
RANDOM_ACCESS = range(16, 22)   # BLA, IDR and CRA pictures


def message(kind, payload):
    return bytes([kind, len(payload)]) + payload


def sei_rbsp():
    mastering = struct.pack(">HHHHHHHHII", *GREEN, *BLUE, *RED, *WHITE,
                            MAX_LUMINANCE, MIN_LUMINANCE)
    light = struct.pack(">HH", MAX_CONTENT, MAX_FRAME_AVERAGE)
    return message(137, mastering) + message(144, light) + b"\x80"


def escape(rbsp):
    """Emulation prevention: no 00 00 0x (x <= 3) may appear inside a NAL."""
    out = bytearray()
    zeros = 0
    for byte in rbsp:
        if zeros >= 2 and byte <= 3:
            out.append(3)
            zeros = 0
        out.append(byte)
        zeros = zeros + 1 if byte == 0 else 0
    return bytes(out)


def sei_nal():
    header = bytes([PREFIX_SEI << 1, 1])   # layer 0, temporal id 0
    return b"\x00\x00\x00\x01" + header + escape(sei_rbsp())


def nal_units(stream):
    """Split an Annex B stream at its start codes, keeping them."""
    starts = []
    index = stream.find(b"\x00\x00\x01")
    while index != -1:
        start = index - 1 if index > 0 and stream[index - 1] == 0 else index
        starts.append(start)
        index = stream.find(b"\x00\x00\x01", index + 3)
    return [stream[a:b] for a, b in zip(starts, starts[1:] + [len(stream)])]


def main(source, target):
    with open(source, "rb") as handle:
        units = nal_units(handle.read())
    out = bytearray()
    for unit in units:
        payload = unit.lstrip(b"\x00")[1:]   # past the start code
        kind = (payload[0] >> 1) & 0x3F
        first_slice = len(payload) > 2 and payload[2] & 0x80
        if kind in RANDOM_ACCESS and first_slice:
            out += sei_nal()
        out += unit
    with open(target, "wb") as handle:
        handle.write(out)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
