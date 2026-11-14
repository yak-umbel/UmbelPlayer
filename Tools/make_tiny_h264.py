#!/usr/bin/env python3
"""Write an H.264 stream of one macroblock, 16 x 16 pixels, for test fixtures.

The system encoder cannot make one: it codes no picture smaller than a few
macroblocks and crops what it codes, so its 16 x 16 stream is no 16 x 16
stream to a decoder. This one is written bit by bit from the syntax in the
standard (Constrained Baseline, CAVLC, level 1.0): a sequence and a picture
parameter set, an IDR picture of a single I_PCM macroblock, and P pictures
that skip it. The pixels are known numbers, a ramp of luma over flat chroma.

Hardware decoding refuses a stream of this size once it has read its headers,
which is what the fixture is for.

    python3 Tools/make_tiny_h264.py out.h264 FRAMES

The output is an Annex B byte stream; wrap it with `ffmpeg -f h264 -i`.
Standard library only.
"""

import sys


class Bits:
    """A bit string, written from the front."""

    def __init__(self):
        self.bits = []

    def u(self, count, value):
        self.bits += [(value >> shift) & 1 for shift in range(count - 1, -1, -1)]

    def ue(self, value):
        code = value + 1
        length = code.bit_length()
        self.u(length - 1, 0)
        self.u(length, code)

    def se(self, value):
        self.ue(2 * value - 1 if value > 0 else -2 * value)

    def align_zero(self):
        while len(self.bits) % 8:
            self.bits.append(0)

    def trailing(self):
        """rbsp_trailing_bits: a one, then zeros to the byte."""
        self.bits.append(1)
        self.align_zero()

    def payload(self):
        assert len(self.bits) % 8 == 0
        return bytes(
            sum(bit << (7 - index) for index, bit in enumerate(self.bits[start:start + 8]))
            for start in range(0, len(self.bits), 8)
        )


def nal(reference_idc, unit_type, rbsp):
    """A NAL unit with its start code; zeros followed by a small byte are escaped."""
    escaped = bytearray()
    zeros = 0
    for byte in rbsp:
        if zeros >= 2 and byte <= 3:
            escaped.append(3)
            zeros = 0
        escaped.append(byte)
        zeros = zeros + 1 if byte == 0 else 0
    return b"\x00\x00\x00\x01" + bytes([(reference_idc << 5) | unit_type]) + bytes(escaped)


def sequence_parameter_set():
    bits = Bits()
    bits.u(8, 66)            # profile_idc: Baseline
    bits.u(8, 0b11000000)    # constraint_set0 and 1: Constrained Baseline
    bits.u(8, 10)            # level_idc: 1.0
    bits.ue(0)               # seq_parameter_set_id
    bits.ue(0)               # log2_max_frame_num_minus4: frame_num is 4 bits
    bits.ue(2)               # pic_order_cnt_type: output order is decoding order
    bits.ue(1)               # max_num_ref_frames
    bits.u(1, 0)             # gaps_in_frame_num_value_allowed_flag
    bits.ue(0)               # pic_width_in_mbs_minus1: one macroblock wide
    bits.ue(0)               # pic_height_in_map_units_minus1: and one high
    bits.u(1, 1)             # frame_mbs_only_flag
    bits.u(1, 1)             # direct_8x8_inference_flag
    bits.u(1, 0)             # frame_cropping_flag
    bits.u(1, 0)             # vui_parameters_present_flag
    bits.trailing()
    return nal(3, 7, bits.payload())


def picture_parameter_set():
    bits = Bits()
    bits.ue(0)               # pic_parameter_set_id
    bits.ue(0)               # seq_parameter_set_id
    bits.u(1, 0)             # entropy_coding_mode_flag: CAVLC
    bits.u(1, 0)             # bottom_field_pic_order_in_frame_present_flag
    bits.ue(0)               # num_slice_groups_minus1
    bits.ue(0)               # num_ref_idx_l0_default_active_minus1
    bits.ue(0)               # num_ref_idx_l1_default_active_minus1
    bits.u(1, 0)             # weighted_pred_flag
    bits.u(2, 0)             # weighted_bipred_idc
    bits.se(0)               # pic_init_qp_minus26
    bits.se(0)               # pic_init_qs_minus26
    bits.se(0)               # chroma_qp_index_offset
    bits.u(1, 0)             # deblocking_filter_control_present_flag
    bits.u(1, 0)             # constrained_intra_pred_flag
    bits.u(1, 0)             # redundant_pic_cnt_present_flag
    bits.trailing()
    return nal(3, 8, bits.payload())


def luma(x, y):
    return 16 + 7 * (x + y)  # 16 ... 226, inside the video range


def idr_picture():
    bits = Bits()
    bits.ue(0)               # first_mb_in_slice
    bits.ue(7)               # slice_type: I, for every slice of the picture
    bits.ue(0)               # pic_parameter_set_id
    bits.u(4, 0)             # frame_num
    bits.ue(0)               # idr_pic_id
    bits.u(1, 0)             # no_output_of_prior_pics_flag
    bits.u(1, 0)             # long_term_reference_flag
    bits.se(0)               # slice_qp_delta
    bits.ue(25)              # mb_type: I_PCM
    bits.align_zero()        # pcm_alignment_zero_bit
    for y in range(16):
        for x in range(16):
            bits.u(8, luma(x, y))
    for _ in range(2 * 8 * 8):
        bits.u(8, 128)       # Cb and Cr: flat
    bits.trailing()
    return nal(3, 5, bits.payload())


def skipped_picture(frame_num):
    bits = Bits()
    bits.ue(0)               # first_mb_in_slice
    bits.ue(5)               # slice_type: P, for every slice of the picture
    bits.ue(0)               # pic_parameter_set_id
    bits.u(4, frame_num % 16)
    bits.u(1, 0)             # num_ref_idx_active_override_flag
    bits.u(1, 0)             # ref_pic_list_modification_flag_l0
    bits.u(1, 0)             # adaptive_ref_pic_marking_mode_flag
    bits.se(0)               # slice_qp_delta
    bits.ue(1)               # mb_skip_run: the one macroblock
    bits.trailing()
    return nal(2, 1, bits.payload())


def main(path, frames):
    stream = sequence_parameter_set() + picture_parameter_set() + idr_picture()
    for number in range(1, frames):
        stream += skipped_picture(number)
    with open(path, "wb") as handle:
        handle.write(stream)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], int(sys.argv[2]))
