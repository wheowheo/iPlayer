#ifndef CFFMPEG_SHIM_H
#define CFFMPEG_SHIM_H

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/time.h>
#include <libavutil/channel_layout.h>
#include <libavutil/display.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

// FFmpeg inline function wrappers that Swift can't call directly
static inline int iplayer_av_ts2timebase(int64_t ts, AVRational tb) {
    return (int)(ts * av_q2d(tb));
}

static inline double iplayer_pts_to_seconds(int64_t pts, AVRational time_base) {
    return (double)pts * av_q2d(time_base);
}

static inline int64_t iplayer_seconds_to_pts(double seconds, AVRational time_base) {
    return (int64_t)(seconds / av_q2d(time_base));
}

static inline int iplayer_av_sample_fmt_is_planar(enum AVSampleFormat fmt) {
    return av_sample_fmt_is_planar(fmt);
}

static inline int iplayer_av_get_bytes_per_sample(enum AVSampleFormat fmt) {
    return av_get_bytes_per_sample(fmt);
}

static inline int64_t iplayer_av_rescale_q(int64_t a, AVRational bq, AVRational cq) {
    return av_rescale_q(a, bq, cq);
}

// 스트림에서 회전 각도를 가져온다 (Display Matrix side data)
static inline double iplayer_get_stream_rotation(const AVStream *stream) {
    const AVPacketSideData *sd = av_packet_side_data_get(
        stream->codecpar->coded_side_data,
        stream->codecpar->nb_coded_side_data,
        AV_PKT_DATA_DISPLAYMATRIX
    );
    if (sd) {
        double theta = av_display_rotation_get((const int32_t *)sd->data);
        // av_display_rotation_get returns the angle by which the video
        // needs to be rotated clockwise. Negate for display angle.
        if (!isnan(theta)) {
            theta = -theta;
            // 정규화: 0~360
            while (theta < 0) theta += 360;
            while (theta >= 360) theta -= 360;
            return theta;
        }
    }
    return 0;
}

static inline AVRational iplayer_av_make_q(int num, int den) {
    AVRational r;
    r.num = num;
    r.den = den;
    return r;
}

#endif
