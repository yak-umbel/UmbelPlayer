#!/bin/bash
# Makes the test fixtures. They are committed, so neither everyday testing nor
# CI needs ffmpeg installed; this runs only to make fixtures again.
#
# Licensing: LGPL-safe encoders only. Not libx264 or libx265, which are GPL
# components; H.264 comes from the system encoder, h264_videotoolbox. Making
# test data with a tool would not pass its license on anyway, but steering
# clear costs nothing and saves explaining later.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/../Tests/Fixtures"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "✗ no ffmpeg. Install it and try again: brew install ffmpeg" >&2
  exit 1
fi

mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# With no arguments, makes them all; with arguments, only those named:
#   Tools/make_fixtures.sh styled_subs.mkv external_gbk.srt
# The hardware encoders' output differs every time, so making them all again
# changes the bytes of existing fixtures; when adding one, make only it.
REQUESTED=("$@")
want() {
  [ "${#REQUESTED[@]}" -eq 0 ] && return 0
  local name
  for name in "${REQUESTED[@]}"; do [ "$name" = "$1" ] && return 0; done
  return 1
}

echo "==> subtitle material"
cat > "$WORK/sub_en.srt" <<'SRT'
1
00:00:00,000 --> 00:00:01,000
first line

2
00:00:01,000 --> 00:00:02,000
second line
SRT
cat > "$WORK/sub_zh.srt" <<'SRT'
1
00:00:00,000 --> 00:00:01,000
第一行

2
00:00:01,000 --> 00:00:02,000
第二行
SRT

if want multi_track.mkv; then
echo "==> multi_track.mkv: 1 video + 2 audio + 2 subtitle tracks"
# The two audio tracks differ on purpose in both frequency (440 / 880) and
# channel count (1 / 2): the frequency shows a switch really changed what
# plays, the channel count that the output was set up again for the new
# track. Do not make them alike: the switching tests would pass and prove
# nothing.
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=320x240:rate=25:duration=3" \
  -f lavfi -i "sine=frequency=440:duration=3" \
  -f lavfi -i "sine=frequency=880:duration=3" \
  -i "$WORK/sub_en.srt" \
  -i "$WORK/sub_zh.srt" \
  -map 0:v -map 1:a -map 2:a -map 3:s -map 4:s \
  -c:v mpeg4 -c:a:0 aac -c:a:1 ac3 -c:s srt \
  -ac:a:0 1 -ac:a:1 2 \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title="stereo" \
  -metadata:s:a:1 language=jpn \
  -metadata:s:s:0 language=eng \
  -metadata:s:s:1 language=chi \
  -disposition:a:0 default \
  -disposition:s:1 forced \
  "$OUT/multi_track.mkv"
fi

if want backward_tracks.mkv; then
echo "==> backward_tracks.mkv: long playback with alternate audio and early subtitle cues"
ffmpeg -y -loglevel error \
  -f lavfi -i "color=c=black:size=160x90:rate=25:duration=24" \
  -f lavfi -i "sine=frequency=440:duration=24" \
  -i "$WORK/sub_en.srt" -i "$WORK/sub_zh.srt" \
  -map 0:v -map 1:a -map 1:a -map 2:s -map 3:s \
  -c:v mpeg4 -g 25 -bf 0 -c:a aac -c:s srt \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn \
  -metadata:s:s:0 language=eng -metadata:s:s:1 language=jpn \
  -disposition:a:0 default -disposition:s:0 0 -disposition:s:1 forced \
  "$OUT/backward_tracks.mkv"
fi

if want moov_at_end.mp4; then
echo "==> moov_at_end.mp4: index at the end of the file, for reading back while probing"
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=160x120:rate=25:duration=2" \
  -f lavfi -i "sine=frequency=440:duration=2" \
  -map 0:v -map 1:a \
  -c:v h264_videotoolbox -c:a aac \
  "$OUT/moov_at_end.mp4"
fi

if want h264_16x16.mp4; then
echo "==> h264_16x16.mp4: one macroblock, which hardware decoding refuses once it has read the headers"
# No encoder makes one: the system encoder codes nothing that small. The
# stream is written by Tools/make_tiny_h264.py and only wrapped here.
python3 "$HERE/make_tiny_h264.py" "$WORK/tiny.h264" 50
ffmpeg -y -loglevel error -f h264 -framerate 25 -i "$WORK/tiny.h264" -c copy "$OUT/h264_16x16.mp4"
fi

if want short.mp4; then
echo "==> short.mp4: the smallest single video track, for quick checks"
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=64x64:rate=10:duration=1" \
  -c:v mpeg4 \
  "$OUT/short.mp4"
fi

if want live_like.ts; then
echo "==> live_like.ts: a container that declares no duration, like a live stream"
# MP4's moov states the duration, readable even reading straight through, so
# it cannot test an unknown duration. MPEG-TS has no duration field; FFmpeg
# usually estimates one by seeking to the end, and where it cannot seek the
# duration really is unknown — which is what live looks like.
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=64x64:rate=10:duration=1" \
  -c:v mpeg4 -f mpegts \
  "$OUT/live_like.ts"
fi

if want live_stream.ts; then
echo "==> live_stream.ts: sound and picture long enough to play off a stream that never ends"
# live_like.ts is too short for that: with so few frames the decoder gives no
# picture before the end of the stream, and a stream that is not over has
# none. Six seconds of 25 fps video and a 440 Hz sine, from LGPL-safe
# encoders only; small enough to send over a loopback socket in one go.
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc2=size=320x180:rate=25:duration=6" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=6" \
  -c:v mpeg4 -b:v 150k -g 25 -c:a aac -b:a 48k -f mpegts \
  "$OUT/live_stream.ts"
fi

if want audio_only.m4a; then
echo "==> audio_only.m4a: sound only, for decoding tests"
# A 440 Hz sine, 2 seconds, stereo. Sound alone spares decoding tests a video
# track to step around.
ffmpeg -y -loglevel error \
  -f lavfi -i "sine=frequency=440:duration=2:sample_rate=48000" \
  -ac 2 -c:a aac \
  "$OUT/audio_only.m4a"
fi

if want truehd_51.mka; then
echo "==> truehd_51.mka: TrueHD 5.1, whose decoder puts out interleaved 32-bit integers"
# FFmpeg's own TrueHD encoder (experimental, hence -strict -2): a tone in
# each of the six channels, a second long. Decoded, it comes out as
# interleaved 32-bit integer samples, a format the other fixtures never give.
ffmpeg -y -loglevel error \
  -f lavfi -i "sine=frequency=440:duration=1:sample_rate=48000" \
  -af "pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0" \
  -c:a truehd -strict -2 \
  "$OUT/truehd_51.mka"
fi

if want sync_check.mp4; then
echo "==> sync_check.mp4: a white flash and a beep each second, to check sync by eye and ear"
# The picture is white for the first tenth of each second and black the rest;
# a short 1 kHz beep sounds at the same moment. Were they apart, eyes and ears
# would notice at once — which no automated test can.
ffmpeg -y -loglevel error \
  -f lavfi -i "color=c=black:s=320x240:r=30:d=6" \
  -f lavfi -i "sine=frequency=1000:duration=6:sample_rate=48000" \
  -filter_complex "\
[0:v]geq=lum='if(lt(mod(T,1),0.1),235,16)':cb=128:cr=128[v];\
[1:a]volume='if(lt(mod(t,1),0.1),3.0,0)':eval=frame[a]" \
  -map "[v]" -map "[a]" \
  -c:v h264_videotoolbox -c:a aac \
  "$OUT/sync_check.mp4"
fi

for depth in 8 10; do
if want "av1_${depth}bit.mp4"; then
echo "==> av1_${depth}bit.mp4: six seconds of flashes and tones, sparse keyframes"
pixel_format=yuv420p
[ "$depth" = 8 ] || pixel_format=yuv420p10le
ffmpeg -y -loglevel error \
  -f lavfi -i "color=c=black:s=320x240:r=30:d=6" \
  -f lavfi -i "sine=frequency=1000:duration=6:sample_rate=48000" \
  -filter_complex "[0:v]geq=lum='if(lt(mod(T,1),0.1),235,16)':cb=128:cr=128,format=$pixel_format[v];[1:a]volume='if(lt(mod(t,1),0.1),3.0,0)':eval=frame[a]" \
  -map "[v]" -map "[a]" -c:v libsvtav1 -preset 12 -crf 25 -g 60 \
  -svtav1-params lp=2 -c:a aac -movflags +faststart "$OUT/av1_${depth}bit.mp4"
fi
done

if want seek_grid.mp4; then
echo "==> seek_grid.mp4: 30 seconds for seeking, with keyframes kept sparse"
# A keyframe every 60 frames (2 seconds). Do not lower -g: exact seeking and
# seeking to keyframes differ only where keyframes are sparse; with nearly
# every frame a keyframe the two agree, and the seeking tests would pass and
# prove nothing. The pattern is sync_check's: white with a beep for the first
# tenth of each second, black and silent the rest.
ffmpeg -y -loglevel error \
  -f lavfi -i "color=c=black:s=320x240:r=30:d=30" \
  -f lavfi -i "sine=frequency=1000:duration=30:sample_rate=48000" \
  -filter_complex "\
[0:v]geq=lum='if(lt(mod(T,1),0.1),235,16)':cb=128:cr=128[v];\
[1:a]volume='if(lt(mod(t,1),0.1),3.0,0)':eval=frame[a]" \
  -map "[v]" -map "[a]" \
  -c:v h264_videotoolbox -g 60 -c:a aac \
  "$OUT/seek_grid.mp4"
fi

if want truncated.mp4; then
echo "==> truncated.mp4: a file cut short, for the error paths"
head -c 2048 "$OUT/moov_at_end.mp4" > "$OUT/truncated.mp4"
fi

if want hevc10_white.mp4; then
echo "==> hevc10_white.mp4: 10-bit HEVC (Main 10), all white"
# 10 bits is usual for HEVC found online, HDR or not. It decodes to P010, 16
# bits a sample, and read as 8-bit it is garbage. All white keeps the check
# simple: drawn right, it is bright. The system encoder, not the GPL x265.
ffmpeg -y -loglevel error \
  -f lavfi -i "color=c=white:s=320x240:r=25:d=1" \
  -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -tag:v hvc1 \
  "$OUT/hevc10_white.mp4"
fi

# ── DV ─────────────────────────────────────────────────
# Ordinary 10-bit HEVC from the system encoder, with a DV configuration box
# written into the sample entry by Tools/make_dovi_config.py. The pictures
# are plain YUV, not a DV encoding: what is tested is how the player tells
# DV apart and routes it, and how it packages profile 5 for the system —
# not what the system shows. Two seconds, a keyframe every 12 frames, so a
# seek lands between keyframes.
dv_fixture() {
  local name="$1" profile="$2" compatibility="$3" entry="$4"; shift 4
  echo "==> $name: DV profile $profile, base layer compatibility $compatibility"
  ffmpeg -y -loglevel error \
    -f lavfi -i "testsrc=s=320x240:r=25:d=2" \
    -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -g 12 -tag:v hvc1 "$@" \
    "$WORK/$name"
  python3 "$HERE/make_dovi_config.py" "$WORK/$name" "$OUT/$name" \
    --profile "$profile" --compatibility "$compatibility" ${entry:+--entry "$entry"}
}
if want dv_p5.mp4; then
  # Profile 5 has no base layer of its own: no colour tags, sample entry dvhe.
  dv_fixture dv_p5.mp4 5 0 dvhe
fi
if want dv_p5_rotated.mp4; then
  # As dv_p5.mp4, declared turned a quarter clockwise (-display_rotation
  # counts counter-clockwise; -noautorotate keeps ffmpeg from turning the
  # pictures itself before encoding, which would drop the declaration). The
  # system shows profile 5 as stored, so the player must not turn it,
  # whatever the stream declares.
  echo "==> dv_p5_rotated.mp4: DV profile 5, declared turned a quarter clockwise"
  ffmpeg -y -loglevel error -noautorotate -display_rotation 270 \
    -f lavfi -i "testsrc=s=320x240:r=25:d=2" \
    -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -g 12 -tag:v hvc1 \
    "$WORK/dv_p5_rotated.mp4"
  python3 "$HERE/make_dovi_config.py" "$WORK/dv_p5_rotated.mp4" "$OUT/dv_p5_rotated.mp4" \
    --profile 5 --compatibility 0 --entry dvhe
fi
if want dv_p81.mp4; then
  dv_fixture dv_p81.mp4 8 1 "" \
    -bsf:v hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9:video_full_range_flag=0
fi
if want dv_p84.mp4; then
  dv_fixture dv_p84.mp4 8 4 "" \
    -bsf:v hevc_metadata=colour_primaries=9:transfer_characteristics=18:matrix_coefficients=9:video_full_range_flag=0
fi
if want dv_p5_inband.mp4; then
  # Profile 5 as some real files are: no parameter sets in the hvcC, and in
  # the stream only at its start — a seek lands on keyframes without them.
  echo "==> dv_p5_inband.mp4: DV profile 5, parameter sets at the stream's start only"
  ffmpeg -y -loglevel error \
    -f lavfi -i "testsrc=s=320x240:r=25:d=2" \
    -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -g 12 -f hevc "$WORK/inband.hevc"
  python3 "$HERE/make_inband_hevc.py" "$WORK/inband.hevc" "$WORK/inband_first.hevc"
  ffmpeg -y -loglevel error -f hevc -r 25 -i "$WORK/inband_first.hevc" -c copy -tag:v hev1 \
    "$WORK/dv_p5_inband.mp4"
  python3 "$HERE/make_dovi_config.py" "$WORK/dv_p5_inband.mp4" "$OUT/dv_p5_inband.mp4" \
    --profile 5 --compatibility 0 --entry dvhe --no-arrays
fi
if want dv_p81_untagged.mp4; then
  # An HDR10 base layer that forgot to say so: its colour comes from the DV box.
  dv_fixture dv_p81_untagged.mp4 8 1 ""
fi

# ── Text subtitles ─────────────────────────────────────
# Video and sound only carry them, from deterministic software encoders; the
# subtitles are what is tested.

if want styled_subs.mkv; then
echo "==> styled_subs.mkv: an ASS track, an SRT track with tags, a forced Japanese track, two audio tracks"
# For the tests of:
# - the ASS track: parsing the style sheet (a top-aligned Sign style) and
#   override tags (italic, colour)
# - the SRT track: FFmpeg turns <i> into {\i1}, showing tags get through the
#   decoder to the dialogue parser
# - the forced Japanese track: shown by itself with the Japanese audio track,
#   not with the English one
# - the ASS track marked default: an ordinary subtitle track is not chosen
#   for being marked default, and this track is the counterexample. Keep
#   its default flag.
# - the third ASS line placed with \pos: the CoreText path ignores \pos, so
#   landing in the right place shows libass drew it
# - the fourth ASS line in the Silkscreen font, attached to the MKV: the
#   system has no such font, so the right glyph widths show the attached font
#   reached libass. The font is from the Google Fonts repository
#   (github.com/google/fonts, ofl/silkscreen), under the SIL Open Font
#   License 1.1, whose text is with it in Tests/Fixtures/fonts/OFL.txt.
cat > "$WORK/styled.ass" <<'ASS'
[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,24,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,20,20,20,1
Style: Sign,Arial,30,&H0000FFFF,&H00FFFFFF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,2,0,8,20,20,40,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.50,0:00:02.00,Default,,0,0,0,,plain {\i1}italic{\i0} {\c&H0000FF&}red
Dialogue: 0,0:00:02.00,0:00:04.00,Sign,,0,0,0,,sign on top
Dialogue: 0,0:00:04.00,0:00:05.00,Default,,0,0,0,,{\pos(160,90)}placed
Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,{\fnSilkscreen}Embedded font
ASS
cat > "$WORK/tagged.srt" <<'SRT'
1
00:00:00,500 --> 00:00:02,000
<i>tagged</i> line

2
00:00:02,000 --> 00:00:04,000
second tagged
SRT
cat > "$WORK/forced_ja.srt" <<'SRT'
1
00:00:01,000 --> 00:00:03,000
強制字幕
SRT
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=160x120:rate=25:duration=6" \
  -f lavfi -i "sine=frequency=440:duration=6" \
  -f lavfi -i "sine=frequency=880:duration=6" \
  -i "$WORK/styled.ass" -i "$WORK/tagged.srt" -i "$WORK/forced_ja.srt" \
  -map 0:v -map 1:a -map 2:a -map 3:s -map 4:s -map 5:s \
  -c:v mpeg4 -c:a aac -c:s:0 ass -c:s:1 srt -c:s:2 srt \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn \
  -metadata:s:s:0 language=eng -metadata:s:s:1 language=eng -metadata:s:s:2 language=jpn \
  -disposition:a:0 default -disposition:a:1 0 \
  -disposition:s:0 default -disposition:s:1 0 -disposition:s:2 forced \
  -attach "$OUT/fonts/Silkscreen-Regular.ttf" -metadata:s:t mimetype=font/ttf \
  "$OUT/styled_subs.mkv"
fi

if want clustered_subs.mkv; then
echo "==> clustered_subs.mkv: an MKV of small clusters, one subtitle line across several"
# For the test of a first seek landing in the middle of a line. Seeking an
# MKV, FFmpeg goes to the start of the keyframe's cluster, keeping the
# subtitle packets in it; a small file is one cluster by default, where the
# packets are read whatever happens, and the test would pass and prove
# nothing. Real files have a cluster every few seconds; -cluster_time_limit
# starts one at every keyframe here. Keep -cluster_time_limit.
cat > "$WORK/long_line.srt" <<'SRT'
1
00:00:00,500 --> 00:00:03,500
long line across clusters
SRT
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=160x120:rate=25:duration=4" \
  -f lavfi -i "sine=frequency=440:duration=4" \
  -i "$WORK/long_line.srt" \
  -map 0:v -map 1:a -map 2:s \
  -c:v mpeg4 -g 12 -c:a aac -c:s srt -cluster_time_limit 100 \
  "$OUT/clustered_subs.mkv"
fi

if want movtext_subs.mp4; then
echo "==> movtext_subs.mp4: MP4's mov_text subtitles"
cat > "$WORK/movtext.srt" <<'SRT'
1
00:00:00,500 --> 00:00:01,500
mov text line
SRT
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=160x120:rate=25:duration=2" \
  -f lavfi -i "sine=frequency=440:duration=2" \
  -i "$WORK/movtext.srt" \
  -map 0:v -map 1:a -map 2:s \
  -c:v mpeg4 -c:a aac -c:s mov_text \
  "$OUT/movtext_subs.mp4"
fi

# An audio track the engine can name but not decode. No encoder makes AC-4,
# so an AC-3 track is made and its sample entry renamed from ac-3 to ac-4,
# the four bytes FFmpeg reads the codec from; the frames stay AC-3 and are
# never decoded. The rename must hit exactly one place, the sample entry.
make_ac4() {
  local out="$1"; shift
  ffmpeg -y -loglevel error \
    -f lavfi -i "color=c=gray:s=160x120:r=10:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2:sample_rate=48000" \
    -f lavfi -i "sine=frequency=880:duration=2:sample_rate=48000" \
    "$@" -c:v mpeg4 -g 10 "$out"
  [ "$(grep -c -a -o 'ac-3' "$out")" = 1 ] || { echo "✗ $out: expected one ac-3 sample entry" >&2; exit 1; }
  perl -0777 -pi -e 's/ac-3/ac-4/' "$out"
}
if want ac4_then_aac.mp4; then
echo "==> ac4_then_aac.mp4: a default AC-4 track first, then AAC"
make_ac4 "$OUT/ac4_then_aac.mp4" -map 0:v -map 1:a -map 2:a \
  -c:a:0 ac3 -c:a:1 aac -disposition:a:0 default -disposition:a:1 0
fi
if want ac4_only.mp4; then
echo "==> ac4_only.mp4: picture with an AC-4 track alone"
make_ac4 "$OUT/ac4_only.mp4" -map 0:v -map 1:a -c:a ac3
fi

if want eac3_movie.mkv; then
# Picture with an E-AC-3 5.1 track, from FFmpeg's own E-AC-3 encoder: the
# format carried to the system player. No object coding — no encoder that
# is free to use makes it — so tests choose that route themselves.
echo "==> eac3_movie.mkv: 12 s of picture with E-AC-3 5.1"
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=160x120:rate=10:duration=12" \
  -f lavfi -i "sine=frequency=440:duration=12:sample_rate=48000" \
  -filter_complex "[1:a]pan=5.1|FL=c0|FR=c0|FC=c0|LFE=0*c0|BL=c0|BR=c0[a]" \
  -map 0:v -map "[a]" -c:v mpeg4 -g 10 -c:a eac3 -b:a 384k \
  "$OUT/eac3_movie.mkv"
fi

if want eac3_short_sound.mkv; then
# As eac3_movie.mkv, but the sound stops two seconds before the picture:
# the system player playing it is done before the film is.
echo "==> eac3_short_sound.mkv: 12 s of picture, 10 s of E-AC-3 5.1"
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=160x120:rate=10:duration=12" \
  -f lavfi -i "sine=frequency=440:duration=10:sample_rate=48000" \
  -filter_complex "[1:a]pan=5.1|FL=c0|FR=c0|FC=c0|LFE=0*c0|BL=c0|BR=c0[a]" \
  -map 0:v -map "[a]" -c:v mpeg4 -g 10 -c:a eac3 -b:a 384k \
  "$OUT/eac3_short_sound.mkv"
fi

if want eac3_long_movie.mkv; then
# As eac3_movie.mkv, but long enough that reading runs well ahead of what the
# system player has asked for: sound then waits in the cache, as it does in
# a film, rather than the whole of it being handed over at once.
echo "==> eac3_long_movie.mkv: 30 s of picture with E-AC-3 5.1"
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=160x120:rate=10:duration=30" \
  -f lavfi -i "sine=frequency=440:duration=30:sample_rate=48000" \
  -filter_complex "[1:a]pan=5.1|FL=c0|FR=c0|FC=c0|LFE=0*c0|BL=c0|BR=c0[a]" \
  -map 0:v -map "[a]" -c:v mpeg4 -g 10 -b:v 100k -c:a eac3 -b:a 128k \
  "$OUT/eac3_long_movie.mkv"
fi

if want long_movtext.mp4; then
# One line from 1 s to 13.5 s over a black picture: a line still showing more
# than ten seconds after it began. Anything bright on the picture is the line.
echo "==> long_movtext.mp4: a mov_text line lasting 12.5 seconds"
cat > "$WORK/long_movtext.srt" <<'SRT'
1
00:00:01,000 --> 00:00:13,500
a long line
SRT
ffmpeg -y -loglevel error \
  -f lavfi -i "color=c=black:s=160x120:r=10:d=14" \
  -f lavfi -i "sine=frequency=440:duration=14" \
  -i "$WORK/long_movtext.srt" \
  -map 0:v -map 1:a -map 2:s \
  -c:v mpeg4 -g 10 -c:a aac -c:s mov_text \
  "$OUT/long_movtext.mp4"
fi

if want webvtt_subs.mkv; then
echo "==> webvtt_subs.mkv: WebVTT subtitles"
cat > "$WORK/cues.vtt" <<'VTT'
WEBVTT

00:00:00.500 --> 00:00:01.500
vtt <b>bold</b> line
VTT
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=160x120:rate=25:duration=2" \
  -f lavfi -i "sine=frequency=440:duration=2" \
  -i "$WORK/cues.vtt" \
  -map 0:v -map 1:a -map 2:s \
  -c:v mpeg4 -c:a aac -c:s webvtt \
  "$OUT/webvtt_subs.mkv"
fi

if want external_gbk.srt; then
echo "==> external_gbk.srt: an external SRT in GBK"
# Much older Chinese subtitling is in GBK, and FFmpeg's text demuxers read
# UTF-8 only; this shows loading detects the encoding and converts it. The
# first entry spans 1 to 5 seconds: a seek to 3 seconds still has to find it,
# since an external track is read whole and loses no long entry. The entries
# are long: on text too short any encoding detector can guess wrong, and real
# subtitle files are not that short.
cat > "$WORK/external_utf8.srt" <<'SRT'
1
00:00:01,000 --> 00:00:05,000
外挂字幕的第一条，持续四秒钟，用来检验定位之后长条目仍然显示。

2
00:00:05,000 --> 00:00:06,000
第二条字幕：简体中文，国标扩展编码。

3
00:00:06,000 --> 00:00:08,000
第三条字幕：这里的文字只是为了让编码探测有足够的样本。
SRT
iconv -f UTF-8 -t GBK "$WORK/external_utf8.srt" > "$OUT/external_gbk.srt"
fi

if want external_bom.ass; then
echo "==> external_bom.ass: an external ASS with a UTF-8 BOM"
# A file with a BOM goes by it, without detection; its style (top-aligned)
# has to come through whole.
printf '\xEF\xBB\xBF' > "$OUT/external_bom.ass"
cat >> "$OUT/external_bom.ass" <<'ASS'
[Script Info]
ScriptType: v4.00+
PlayResY: 360

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, Bold, Italic, Alignment, MarginL, MarginR, MarginV
Style: Default,Arial,24,&H00FFFFFF,&H00000000,0,0,8,20,20,20

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.50,0:00:01.50,Default,,0,0,0,,外挂 ASS
ASS
fi

# ── Bitmap subtitles ───────────────────────────────────
# FFmpeg decodes PGS but cannot encode it, so Tools/make_pgs.py writes it to
# the published format: a white block at the bottom from 0.5 to 2.0 seconds
# (100×20 at 110,200), a red one at the top left from 2.5 to 3.5 seconds
# (60×30 at 40,20), on a 320×240 canvas. The video is plain grey, so pixels
# read back by compositing tests are white, red or grey at a glance.

if want pgs_subs.mkv; then
echo "==> pgs_subs.mkv: grey video with PGS subtitles"
# -copyts keeps the timestamps in the .sup; without it FFmpeg moves the first
# event to zero and every time is half a second early. PGS events have no
# duration: the next event, a clear, ends one.
python3 "$HERE/make_pgs.py" "$WORK/sub.sup"
ffmpeg -y -loglevel error \
  -f lavfi -i "color=c=0x808080:s=320x240:r=25:d=4" \
  -copyts -i "$WORK/sub.sup" \
  -map 0:v -map 1:s -c:v mpeg4 -q:v 2 -c:s copy \
  -metadata:s:s:0 language=eng \
  "$OUT/pgs_subs.mkv"
fi

if want dvd_subs.mkv; then
echo "==> dvd_subs.mkv: the same subtitles as DVD subtitles"
# DVD subtitles carry their end. -fix_sub_duration has FFmpeg end each event
# where the next, a clear, starts; without it the end is "never" and neither
# event goes away.
python3 "$HERE/make_pgs.py" "$WORK/sub.sup"
ffmpeg -y -loglevel error \
  -f lavfi -i "color=c=0x808080:s=320x240:r=25:d=4" \
  -copyts -fix_sub_duration -i "$WORK/sub.sup" \
  -map 0:v -map 1:s -c:v mpeg4 -q:v 2 -c:s dvdsub \
  -metadata:s:s:0 language=eng \
  "$OUT/dvd_subs.mkv"
fi

if want dvb_subs_offset.ts; then
echo "==> dvb_subs_offset.ts: a TS whose timestamps start near 101 seconds, with DVB subtitles"
# Two things in one fixture:
# - A start that is not zero. Broadcast recordings and VOBs cut from discs
#   start tens or thousands of seconds in, and a player moves the timeline
#   to zero. -output_ts_offset 100 makes such a file, starting near 101.39
#   seconds (the TS muxer adds 1.4 of its own). Keep it.
# - DVB subtitles: the same PGS events through FFmpeg's dvbsub encoder.
#   -fix_sub_duration as for dvd_subs.mkv: without it the clears' times go
#   wrong.
# Video in mpeg2video, sound in mp2: FFmpeg's own LGPL encoders.
python3 "$HERE/make_pgs.py" "$WORK/sub.sup"
ffmpeg -y -loglevel error \
  -f lavfi -i "color=c=0x808080:s=320x240:r=25:d=4" \
  -f lavfi -i "sine=frequency=440:duration=4" \
  -copyts -fix_sub_duration -i "$WORK/sub.sup" \
  -map 0:v -map 1:a -map 2:s -c:v mpeg2video -q:v 4 -g 12 -c:a mp2 -c:s dvbsub \
  -metadata:s:s:0 language=eng -output_ts_offset 100 \
  "$OUT/dvb_subs_offset.ts"
fi

if want clustered_subs_offset.mkv; then
echo "==> clustered_subs_offset.mkv: clustered_subs.mkv with timestamps starting at 50 seconds"
# Subtitle preroll asks the index where a line starts, and both the question
# and the answer have to move with the timeline. The same line as
# clustered_subs.mkv (0.5 to 3.5 seconds), with -output_ts_offset 50.
cat > "$WORK/long_line_offset.srt" <<'SRT'
1
00:00:00,500 --> 00:00:03,500
long line across clusters
SRT
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=160x120:rate=25:duration=4" \
  -f lavfi -i "sine=frequency=440:duration=4" \
  -i "$WORK/long_line_offset.srt" \
  -map 0:v -map 1:a -map 2:s \
  -c:v mpeg4 -g 12 -c:a aac -c:s srt -cluster_time_limit 100 \
  -output_ts_offset 50 \
  "$OUT/clustered_subs_offset.mkv"
fi

# ── Sound whose format changes midway ──────────────────
if want rate_change.ts; then
echo "==> rate_change.ts: 48 kHz stereo, then 44.1 kHz mono, in one stream"
# What a stream with an ad spliced in carries: the second part is encoded
# otherwise. It differs in both rate and channel count, so a test sees both
# converted; timestamps run on across the join.
ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" \
  -ac 2 -c:a aac -f mpegts "$WORK/rate_a.ts"
ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=880:sample_rate=44100:duration=2" \
  -ac 1 -c:a aac -output_ts_offset 2 -f mpegts "$WORK/rate_b.ts"
cat "$WORK/rate_a.ts" "$WORK/rate_b.ts" > "$OUT/rate_change.ts"
fi

# ── Pixels that are not square ─────────────────────────
# Nearly all DVD and standard-definition broadcast: 352×288 or 720×576
# pixels, shown at 16:9 or 4:3. Laid out by pixel count, the picture is
# squashed.

if want anamorphic.ts; then
echo "==> anamorphic.ts: 352×288, the bitstream declaring 16:9 (pixel aspect 16:11)"
# A TS container has no aspect ratio, only the bitstream's: a player reads it
# off the decoded frames.
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=352x288:rate=25:duration=1" \
  -c:v mpeg2video -q:v 4 -aspect 16:9 \
  "$OUT/anamorphic.ts"
fi

if want anamorphic_container.mkv; then
echo "==> anamorphic_container.mkv: the same bitstream, the container declaring 4:3 (pixel aspect 12:11)"
# The bitstream says 16:9, the container 4:3; where they disagree the
# container wins, as FFmpeg's av_guess_sample_aspect_ratio has it. Copied as
# a stream: -aspect changes the container only and leaves the bitstream as it
# is. Do not make it a re-encode.
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=352x288:rate=25:duration=1" \
  -c:v mpeg2video -q:v 4 -aspect 16:9 -f mpegts "$WORK/anamorphic.ts"
ffmpeg -y -loglevel error -i "$WORK/anamorphic.ts" -c:v copy -aspect 4:3 \
  "$OUT/anamorphic_container.mkv"
fi

# ── HDR and colour matrices ────────────────────────────
# Tools/make_raw_frame.py writes the pictures at exact sample values, which
# the tests compare with values from the standards' formulas, with no colour
# conversion's rounding in between. hevc_metadata and h264_metadata write the
# colour tags into the bitstream: the system encoders ignore options such as
# -color_trc.

if want hdr10_pq.mp4; then
echo "==> hdr10_pq.mp4: PQ, 1000 nits above and 50 nits below, with HDR10 static metadata"
# Limited-range 10 bits: value = 64 + 876 × PQ signal. PQ(1000) = 0.7518 → 723,
# PQ(50) = 0.4403 → 450. Tools/make_hdr_sei.py writes the mastering display
# and content light level SEI per H.265 annex D.
python3 "$HERE/make_raw_frame.py" "$WORK/pq.yuv" 320 240 10 723 450 512 512
ffmpeg -y -loglevel error \
  -f rawvideo -pix_fmt yuv420p10le -s 320x240 -r 25 -stream_loop 24 -i "$WORK/pq.yuv" \
  -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le \
  -bsf:v hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9:video_full_range_flag=0 \
  -f hevc "$WORK/pq.hevc"
python3 "$HERE/make_hdr_sei.py" "$WORK/pq.hevc" "$WORK/pq_sei.hevc"
ffmpeg -y -loglevel error -f hevc -r 25 -i "$WORK/pq_sei.hevc" -c copy -tag:v hvc1 \
  "$OUT/hdr10_pq.mp4"
fi

if want hlg.mp4; then
echo "==> hlg.mp4: HLG, 0.75 above (BT.2408 reference white, 203 nits) and 0.5 below"
# value = 64 + 876 × signal: 0.75 → 721, 0.5 → 502. HLG has no static metadata.
python3 "$HERE/make_raw_frame.py" "$WORK/hlg.yuv" 320 240 10 721 502 512 512
ffmpeg -y -loglevel error \
  -f rawvideo -pix_fmt yuv420p10le -s 320x240 -r 25 -stream_loop 24 -i "$WORK/hlg.yuv" \
  -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le \
  -bsf:v hevc_metadata=colour_primaries=9:transfer_characteristics=18:matrix_coefficients=9:video_full_range_flag=0 \
  -tag:v hvc1 "$OUT/hlg.mp4"
fi

if want bt601_sd.mp4; then
echo "==> bt601_sd.mp4: standard definition 352×288, tagged BT.601, pure red under BT.601"
# Y=81, Cb=90, Cr=240 is (255, 0, 0) under BT.601 and orange under BT.709:
# the two matrices draw it differently, so the tests can tell which was used.
python3 "$HERE/make_raw_frame.py" "$WORK/red601.yuv" 352 288 8 81 81 90 240
ffmpeg -y -loglevel error \
  -f rawvideo -pix_fmt yuv420p -s 352x288 -r 25 -stream_loop 24 -i "$WORK/red601.yuv" \
  -c:v h264_videotoolbox -b:v 2M \
  -bsf:v h264_metadata=colour_primaries=6:transfer_characteristics=6:matrix_coefficients=6:video_full_range_flag=0 \
  "$OUT/bt601_sd.mp4"
fi

if want b_frames.mkv; then
echo "==> b_frames.mkv: video with B frames nothing refers to, a keyframe each second, no sound"
# MPEG-4 Part 2 never refers to a B frame, so a decoder skipping frames
# nothing refers to leaves exactly the I and P frames. Closed groups of
# pictures: decoding from a keyframe after dropping to it lacks no reference
# (the encoder then wants scene-change detection off).
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=160x120:rate=25:duration=4" \
  -c:v mpeg4 -q:v 4 -bf 2 -g 25 -flags +cgop -sc_threshold 1000000000 \
  "$OUT/b_frames.mkv"
fi

# ── A playlist with an ad spliced in ───────────────────
if want hls; then
echo "==> hls/: a film cut into segments, an ad spliced in, and variants"
# The film: 12 s, 320x240, 48 kHz stereo, a keyframe every 2 s so each 2 s
# segment starts on one. Its segment names have no extension, as some
# sites'. The ad: 4 s, 256x144, 44.1 kHz mono, its own timestamps starting
# over — what the ads spliced into real sites' playlists look like. The
# film's timestamps run on past the ad, as there too.
HLS="$OUT/hls"
rm -rf "$HLS"
mkdir -p "$HLS"
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=320x240:rate=25:duration=12" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=12" \
  -c:v h264_videotoolbox -b:v 300k -force_key_frames "expr:gte(t,n_forced*2)" \
  -c:a aac -ac 2 \
  -f hls -hls_time 2 -hls_list_size 0 -hls_segment_filename "$HLS/main%d" "$WORK/main.m3u8"
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc2=size=256x144:rate=25:duration=4" \
  -f lavfi -i "sine=frequency=880:sample_rate=44100:duration=4" \
  -c:v h264_videotoolbox -b:v 200k -force_key_frames "expr:gte(t,n_forced*2)" \
  -c:a aac -ac 1 \
  -f hls -hls_time 2 -hls_list_size 0 -hls_segment_filename "$HLS/ad%d.ts" "$WORK/ad.m3u8"
# An ad with no sound at all.
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc2=size=256x144:rate=25:duration=4" \
  -c:v h264_videotoolbox -b:v 200k -force_key_frames "expr:gte(t,n_forced*2)" \
  -f hls -hls_time 2 -hls_list_size 0 -hls_segment_filename "$HLS/silent%d.ts" "$WORK/silent.m3u8"
# What some servers answer a lost segment with: a page, and 200.
printf '<html><body>not found</body></html>\n' > "$HLS/page"

# A playlist's duration and address pairs, one pair to two lines.
entries() {
  awk '/^#EXTINF/ { duration = $0; next } /^[^#]/ { print duration; n = split($0, part, "/"); print part[n] }' "$1"
}
main=$(entries "$WORK/main.m3u8")
ad=$(entries "$WORK/ad.m3u8")
silent=$(entries "$WORK/silent.m3u8")
header='#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n'
{
  printf "$header"
  echo "$main" | head -n 6; echo '#EXT-X-DISCONTINUITY'; echo "$ad"
  echo '#EXT-X-DISCONTINUITY'; echo "$main" | tail -n 6
  echo '#EXT-X-ENDLIST'
} > "$HLS/ad.m3u8"
# Tags every two segments with nothing behind them: the timestamps run on.
{
  printf "$header"
  echo "$main" | awk 'NR > 1 && NR % 4 == 1 { print "#EXT-X-DISCONTINUITY" } { print }'
  echo '#EXT-X-ENDLIST'
} > "$HLS/tagged.m3u8"
{
  printf "$header"
  echo "$main" | head -n 6; echo '#EXT-X-DISCONTINUITY'; echo "$silent"
  echo '#EXT-X-DISCONTINUITY'; echo "$main" | tail -n 6
  echo '#EXT-X-ENDLIST'
} > "$HLS/silent_ad.m3u8"
{
  printf "$header"
  echo "$main" | sed 's/^main2$/page/'
  echo '#EXT-X-ENDLIST'
} > "$HLS/soft404.m3u8"
fi

# ── Playlists for the fallback ─────────────────────────
if want hls_fallback; then
echo "==> hls/alt_audio, hls/packed: playlists read by FFmpeg's own demuxer"
# Sound in a playlist of its own, which the demuxer here does not join up.
ALT="$OUT/hls/alt_audio"
rm -rf "$ALT"
mkdir -p "$ALT"
ffmpeg -y -loglevel error -f lavfi -i "testsrc=size=320x240:rate=25:duration=6" \
  -c:v h264_videotoolbox -b:v 300k -force_key_frames "expr:gte(t,n_forced*2)" -an \
  -f hls -hls_time 2 -hls_list_size 0 -hls_playlist_type vod \
  -hls_segment_filename "$ALT/v%d.ts" "$ALT/video.m3u8"
ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=6" \
  -c:a aac -ac 2 -f hls -hls_time 2 -hls_list_size 0 -hls_playlist_type vod \
  -hls_segment_filename "$ALT/a%d.ts" "$ALT/audio.m3u8"
printf '%s\n' '#EXTM3U' \
  '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="en",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"' \
  '#EXT-X-STREAM-INF:BANDWIDTH=400000,AUDIO="aud"' 'video.m3u8' > "$ALT/master.m3u8"
# Two variants of the film: the one with more bandwidth, and the ad, is the
# one to play.
printf '%s\n' '#EXTM3U' '#EXT-X-VERSION:3' \
  '#EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=320x240,CODECS="avc1.4d401e,mp4a.40.2"' 'tagged.m3u8' \
  '#EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=320x240,CODECS="avc1.4d401e,mp4a.40.2"' 'ad.m3u8' \
  > "$OUT/hls/master.m3u8"
# The film's first three segments in one file, after another segment the
# playlist leaves out — so no range starts at the file's start — listed by
# byte range, with sound of its own beside them: FFmpeg's reading plays it.
RANGES="$OUT/hls/ranges"
rm -rf "$RANGES"
mkdir -p "$RANGES"
cat "$OUT/hls/main5" "$OUT/hls/main0" "$OUT/hls/main1" "$OUT/hls/main2" > "$RANGES/all.ts"
{
  printf '#EXTM3U\n#EXT-X-VERSION:4\n#EXT-X-TARGETDURATION:2\n'
  offset=$(wc -c < "$OUT/hls/main5" | tr -d ' ')
  for i in 0 1 2; do
    size=$(wc -c < "$OUT/hls/main$i" | tr -d ' ')
    printf '#EXTINF:2.0,\n#EXT-X-BYTERANGE:%s@%s\nall.ts\n' "$size" "$offset"
    offset=$((offset + size))
  done
  printf '#EXT-X-ENDLIST\n'
} > "$RANGES/video.m3u8"
printf '%s\n' '#EXTM3U' \
  '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="en",DEFAULT=YES,AUTOSELECT=YES,URI="../alt_audio/audio.m3u8"' \
  '#EXT-X-STREAM-INF:BANDWIDTH=400000,AUDIO="aud"' 'video.m3u8' > "$RANGES/master.m3u8"
# Audio-only HLS as raw AAC segments: not transport streams.
PACKED="$OUT/hls/packed"
rm -rf "$PACKED"
mkdir -p "$PACKED"
ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=6" \
  -c:a aac -ac 2 -f segment -segment_time 2 -segment_format adts "$PACKED/a%d.aac"
{
  printf '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n'
  for f in "$PACKED"/a*.aac; do printf '#EXTINF:2.0,\n%s\n' "$(basename "$f")"; done
  printf '#EXT-X-ENDLIST\n'
} > "$PACKED/index.m3u8"
fi

# ── Separate fragmented tracks ─────────────────────────
if want hls_alt_fmp4; then
echo "==> hls/alt_fmp4: separate picture and sound in byte ranges"
ALT="$OUT/hls/alt_fmp4"
mkdir -p "$ALT"
for track in video audio; do
  stream=v
  [ "$track" = audio ] && stream=a
  ffmpeg -hide_banner -loglevel error -y -i "$OUT/sync_check.mp4" \
    -map "0:$stream:0" -c copy -f hls -hls_time 2 -hls_playlist_type vod \
    -hls_segment_type fmp4 -hls_flags single_file "$ALT/$track.m3u8"
done
printf '%s\n' '#EXTM3U' \
  '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="audio.m3u8"' \
  '#EXT-X-STREAM-INF:BANDWIDTH=400000,AUDIO="aud"' 'video.m3u8' > "$ALT/master.m3u8"
fi

# ── Encrypted segments ─────────────────────────────────
if want hls_aes; then
echo "==> hls/aes: the film's first segments encrypted with AES-128"
# Encrypted here with a fixed key rather than by the muxer, so the clear
# segments they came from are at hand to compare with. aes/ names its IV;
# aes_seq/ leaves it out, so the IV is each segment's sequence number.
# aes_badkey/ points one segment at a key that is a web page.
KEY=000102030405060708090a0b0c0d0e0f
IV=0f0e0d0c0b0a09080706050403020100
AES="$OUT/hls/aes"
rm -rf "$AES" "$OUT/hls/aes_seq" "$OUT/hls/aes_badkey"
mkdir -p "$AES" "$OUT/hls/aes_seq" "$OUT/hls/aes_badkey"
printf '%s' "$KEY" | xxd -r -p > "$AES/key.bin"
cp "$AES/key.bin" "$OUT/hls/aes_seq/key.bin"
for i in 0 1 2; do
  openssl enc -aes-128-cbc -K "$KEY" -iv "$IV" -in "$OUT/hls/main$i" -out "$AES/e$i.ts"
  openssl enc -aes-128-cbc -K "$KEY" -iv "$(printf '%032x' $((5 + i)))" \
    -in "$OUT/hls/main$i" -out "$OUT/hls/aes_seq/s$i.ts"
done
openssl enc -aes-128-cbc -K "$KEY" -iv "$IV" -in "$OUT/hls/main1" -out "$OUT/hls/aes_badkey/e1.ts"
{
  printf '#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
  printf '#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x%s\n' "$IV"
  for i in 0 1 2; do printf '#EXTINF:2.0,\ne%s.ts\n' "$i"; done
  printf '#EXT-X-KEY:METHOD=NONE\n#EXTINF:2.0,\n../main3\n#EXT-X-ENDLIST\n'
} > "$AES/index.m3u8"
{
  printf '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:5\n'
  printf '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
  for i in 0 1 2; do printf '#EXTINF:2.0,\ns%s.ts\n' "$i"; done
  printf '#EXT-X-ENDLIST\n'
} > "$OUT/hls/aes_seq/index.m3u8"
{
  printf '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0,\n../main0\n'
  printf '#EXT-X-KEY:METHOD=AES-128,URI="../page",IV=0x%s\n#EXTINF:2.0,\ne1.ts\n' "$IV"
  printf '#EXT-X-KEY:METHOD=NONE\n#EXTINF:2.0,\n../main2\n#EXT-X-ENDLIST\n'
} > "$OUT/hls/aes_badkey/index.m3u8"
fi

# ── Segments dressed up as pictures ───────────────────
if want hls_disguised; then
echo "==> hls/disguised: the film's first segments behind a picture's header"
# Some sites serve segments as images: a PNG header and a little picture
# data in front of the transport stream.
DIS="$OUT/hls/disguised"
rm -rf "$DIS"
mkdir -p "$DIS"
ffmpeg -y -loglevel error -f lavfi -i "color=c=red:size=8x8" -frames:v 1 "$WORK/dot.png"
for i in 0 1 2; do cat "$WORK/dot.png" "$OUT/hls/main$i" > "$DIS/p$i.png"; done
{
  printf '#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
  for i in 0 1 2; do printf '#EXTINF:2.0,\np%s.png\n' "$i"; done
  printf '#EXT-X-ENDLIST\n'
} > "$DIS/index.m3u8"
fi

# ── Fragmented MP4 segments ───────────────────────────
if want hls_fmp4; then
echo "==> hls/fmp4: the film as fragmented MP4 segments, and a change of initialisation"
FM="$OUT/hls/fmp4"
rm -rf "$FM"
mkdir -p "$FM"
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc=size=320x240:rate=25:duration=12" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=12" \
  -c:v h264_videotoolbox -b:v 300k -force_key_frames "expr:gte(t,n_forced*2)" -c:a aac -ac 2 \
  -f hls -hls_time 2 -hls_list_size 0 -hls_playlist_type vod -hls_segment_type fmp4 \
  -hls_fmp4_init_filename init.mp4 -hls_segment_filename "$FM/seg%d.m4s" "$FM/index.m3u8"
# Another encoding, another picture size, its own initialisation segment.
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc2=size=256x144:rate=25:duration=6" \
  -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=6" \
  -c:v h264_videotoolbox -b:v 200k -force_key_frames "expr:gte(t,n_forced*2)" -c:a aac -ac 2 \
  -f hls -hls_time 2 -hls_list_size 0 -hls_playlist_type vod -hls_segment_type fmp4 \
  -hls_fmp4_init_filename init2.mp4 -hls_segment_filename "$FM/other%d.m4s" "$WORK/other.m3u8"
# The initialisation segment goes beside the playlist it was made for.
cp "$WORK/init2.mp4" "$FM/init2.mp4"
{
  printf '#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-MAP:URI="init.mp4"\n'
  for i in 0 1 2; do printf '#EXTINF:2.0,\nseg%s.m4s\n' "$i"; done
  printf '#EXT-X-MAP:URI="init2.mp4"\n'
  for i in 0 1 2; do printf '#EXTINF:2.0,\nother%s.m4s\n' "$i"; done
  printf '#EXT-X-ENDLIST\n'
} > "$FM/remap.m3u8"
# Encrypted, initialisation segment and all: the headers need the key too.
AF="$OUT/hls/aes_fmp4"
KEY=000102030405060708090a0b0c0d0e0f
IV=0f0e0d0c0b0a09080706050403020100
rm -rf "$AF"
mkdir -p "$AF"
printf '%s' "$KEY" | xxd -r -p > "$AF/key.bin"
openssl enc -aes-128-cbc -K "$KEY" -iv "$IV" -in "$FM/init.mp4" -out "$AF/init.mp4"
for i in 0 1 2; do
  openssl enc -aes-128-cbc -K "$KEY" -iv "$IV" -in "$FM/seg$i.m4s" -out "$AF/seg$i.m4s"
done
{
  printf '#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n'
  printf '#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x%s\n#EXT-X-MAP:URI="init.mp4"\n' "$IV"
  for i in 0 1 2; do printf '#EXTINF:2.0,\nseg%s.m4s\n' "$i"; done
  printf '#EXT-X-ENDLIST\n'
} > "$AF/index.m3u8"
fi

# ── Display rotation ───────────────────────────────────
# One 128×64 picture, bright in its top-left quadrant only, so where that
# corner ends up says which way the picture is turned. The same stream is
# copied six times with another display matrix written beside it.
# -display_rotation counts counter-clockwise; the names count clockwise, as
# UmbelVideoRotation does. rotation_flipped is a horizontal flip, which an
# angle alone reads as a half turn; rotation_45 is no right angle.

rotation_base() {
  if [ ! -f "$WORK/rotation_upright.mp4" ]; then
    ffmpeg -y -loglevel error \
      -f lavfi -i "color=c=black:s=128x64:r=10:d=1,drawbox=x=0:y=0:w=64:h=32:color=white:t=fill,format=yuv420p" \
      -c:v h264_videotoolbox -b:v 400k -g 5 -pix_fmt yuv420p "$WORK/rotation_upright.mp4"
  fi
}

rotation_fixture() {
  local name="$1"; shift
  want "$name.mp4" || return 0
  echo "==> $name.mp4"
  rotation_base
  ffmpeg -y -loglevel error "$@" -i "$WORK/rotation_upright.mp4" -c copy "$OUT/$name.mp4"
}

rotation_fixture rotation_none
rotation_fixture rotation_cw90 -display_rotation 270
rotation_fixture rotation_cw180 -display_rotation 180
rotation_fixture rotation_cw270 -display_rotation 90
rotation_fixture rotation_flipped -display_hflip
rotation_fixture rotation_45 -display_rotation 45

# ── Interlaced video ───────────────────────────────────
# A 40-pixel white bar crossing black at 600 pixels a second, 50 fields a
# second, woven two by two into 25 interlaced frames: the bar sits 12 pixels
# apart in the two fields, so a frame shown as it is has combed edges.
# Each row is drawn as of the time of its own field: geq takes the frame
# number N and the row Y, and the rows of the field that is earlier in time
# are drawn half a frame before the others. (The interlace filter would do
# this in one step, but it is one of FFmpeg's GPL filters; geq is not.)
# MPEG-2 from FFmpeg's own encoder, coded as interlaced, one file per field
# order.
interlaced_fixture() {
  local name="$1" scan="$2" order="$3" earlier="$4"
  want "$name" || return 0
  echo "==> $name: 320×240, 25 interlaced frames a second, $scan"
  local when="(N/25+if(eq(mod(Y,2),$earlier),0,1)/50)*600"
  ffmpeg -y -loglevel error \
    -f lavfi -i "color=c=black:s=320x240:r=25:d=1,format=yuv420p,geq=lum='if(between(X,mod($when,280),mod($when,280)+39),235,16)':cb=128:cr=128,setfield=$scan" \
    -c:v mpeg2video -b:v 3M -g 12 -flags +ilme+ildct -field_order "$order" -f mpegts \
    "$OUT/$name"
}
# The earlier field is the even rows (0) for top first, the odd rows (1) for bottom first.
interlaced_fixture interlaced_tff.ts tff tt 0
interlaced_fixture interlaced_bff.ts bff bb 1

# 4:2:2 whose fields each have a colour of their own: the even rows carry
# chroma (64, 192), the odd rows (192, 64), luma flat. Woven and turned into
# 4:2:0 as one picture, the two colours average into one grey; turned field by
# field, the rows keep their field's colour. One file coded as interlaced
# frames, one coded progressive with the same rows: the second is no pair of
# fields, and its rows do average.
chroma_fields_fixture() {
  local name="$1" scan="$2"; shift 2
  want "$name" || return 0
  echo "==> $name: 320×240 4:2:2, 25 frames, $scan"
  ffmpeg -y -loglevel error \
    -f lavfi -i "color=c=black:s=320x240:r=25:d=1,format=yuv422p,geq=lum=128:cb='if(eq(mod(Y,2),0),64,192)':cr='if(eq(mod(Y,2),0),192,64)',setfield=$scan" \
    -c:v mpeg2video -b:v 3M -g 12 -pix_fmt yuv422p "$@" -f mpegts "$OUT/$name"
}
chroma_fields_fixture interlaced_422.ts tff -flags +ilme+ildct -field_order tt
chroma_fields_fixture progressive_422.ts prog

# What rotation_cw90 turns into, stored that way: 64×128, bright top-right.
# A turned picture has to look, subtitles and all, like this one.
if want rotation_portrait.mp4; then
echo "==> rotation_portrait.mp4"
ffmpeg -y -loglevel error \
  -f lavfi -i "color=c=black:s=64x128:r=10:d=1,drawbox=x=32:y=0:w=32:h=64:color=white:t=fill,format=yuv420p" \
  -c:v h264_videotoolbox -b:v 400k -g 5 -pix_fmt yuv420p "$OUT/rotation_portrait.mp4"
fi

echo
echo "==> made"
ls -lh "$OUT"
echo "✓ fixtures made"
