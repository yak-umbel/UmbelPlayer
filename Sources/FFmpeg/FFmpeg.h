// The FFmpeg interfaces the package uses, as the module `FFmpeg`.
//
// The headers are FFmpeg's own, in UmbelFFmpeg.framework under Binaries/
// (built by Tools/BuildFFmpeg), a directory to a library, found through the
// framework search path: <UmbelFFmpeg/libavutil/avutil.h>. They include one
// another by relative paths, rewritten so when the framework was made.
#include <UmbelFFmpeg/libavutil/avutil.h>
#include <UmbelFFmpeg/libavutil/pixdesc.h>
#include <UmbelFFmpeg/libavutil/mastering_display_metadata.h>
#include <UmbelFFmpeg/libavutil/dovi_meta.h>
#include <UmbelFFmpeg/libavutil/display.h>
#include <UmbelFFmpeg/libavcodec/avcodec.h>
#include <UmbelFFmpeg/libavformat/avformat.h>
#include <UmbelFFmpeg/libswresample/swresample.h>
#include <UmbelFFmpeg/libswscale/swscale.h>
