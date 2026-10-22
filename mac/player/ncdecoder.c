// See ncdecoder.h.
#include "ncdecoder.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <math.h>
#include <string.h>

// Packets read from the file but not yet wanted by their decoder.
typedef struct {
  AVPacket **items;
  int head, count, cap;
} PacketQueue;

struct NCDecoder {
  AVFormatContext *fmt;
  double start, duration;
  int vidx, aidx;          // stream indexes, -1 none
  int *audioStreams, audioCount, audioSel;
  AVCodecContext *vctx, *actx;
  AVBufferRef *hwdev;
  PacketQueue vq, aq;
  int demuxEof;
  int hwFrames;  // the last video frame came from VideoToolbox
  int vFlushing, aFlushing;
  double vDropBefore, aDropBefore;  // < 0: nothing to drop
  double vNext, aNext;              // predicted next timestamps, < 0 unknown
  AVPacket *pkt;
  AVFrame *frame;
  // software video -> CVPixelBuffer
  struct SwsContext *sws;
  CVPixelBufferPoolRef pool;
  int poolW, poolH;
  OSType poolFmt;
  // audio -> float stereo
  SwrContext *swr;
  int swrRate, swrFmt;
  AVChannelLayout swrLayout;
  float *pcm;
  int pcmCap;
};

static void pq_push(PacketQueue *q, AVPacket *p) {
  if (q->count == q->cap) {
    int cap = q->cap ? q->cap * 2 : 64;
    AVPacket **items = av_malloc_array(cap, sizeof(*items));
    for (int i = 0; i < q->count; i++) items[i] = q->items[(q->head + i) % q->cap];
    av_free(q->items);
    q->items = items;
    q->head = 0;
    q->cap = cap;
  }
  q->items[(q->head + q->count) % q->cap] = p;
  q->count++;
}

static AVPacket *pq_pop(PacketQueue *q) {
  if (!q->count) return NULL;
  AVPacket *p = q->items[q->head];
  q->head = (q->head + 1) % q->cap;
  q->count--;
  return p;
}

static void pq_clear(PacketQueue *q) {
  AVPacket *p;
  while ((p = pq_pop(q))) av_packet_free(&p);
}

static void pq_free(PacketQueue *q) {
  pq_clear(q);
  av_freep(&q->items);
  q->cap = 0;
}

static void set_err(char *err, int len, const char *what, int code) {
  if (!err || len <= 0) return;
  char buf[AV_ERROR_MAX_STRING_SIZE] = "";
  if (code) av_strerror(code, buf, sizeof buf);
  snprintf(err, len, "%s%s%s", what, code ? ": " : "", buf);
}

static enum AVPixelFormat pick_format(AVCodecContext *ctx, const enum AVPixelFormat *fmts) {
  (void)ctx;
  for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++)
    if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
  for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++) {
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(*p);
    if (desc && !(desc->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *p;
  }
  return AV_PIX_FMT_NONE;
}

// Video worth sending to VideoToolbox: HD and up in the codecs it handles.
// Anything smaller (DVD rips, Xvid, MPEG-2) decodes faster in software, which
// matters when catching up from a keyframe after a seek.
static int wants_hardware(const AVCodecParameters *par) {
  enum AVCodecID id = par->codec_id;
  return (id == AV_CODEC_ID_H264 || id == AV_CODEC_ID_HEVC || id == AV_CODEC_ID_PRORES) &&
         par->width * par->height >= 1280 * 720;
}

static AVCodecContext *open_codec(NCDecoder *d, int idx, int video, char *err, int errlen) {
  AVStream *st = d->fmt->streams[idx];
  const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
  if (!codec) {
    set_err(err, errlen, "No decoder for this format", 0);
    return NULL;
  }
  AVCodecContext *ctx = avcodec_alloc_context3(codec);
  if (!ctx) return NULL;
  int r = avcodec_parameters_to_context(ctx, st->codecpar);
  if (r < 0) goto fail;
  ctx->pkt_timebase = st->time_base;
  ctx->thread_count = 0;
  if (video) {
    ctx->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    if (wants_hardware(st->codecpar)) {
      if (!d->hwdev) av_hwdevice_ctx_create(&d->hwdev, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0);
      if (d->hwdev) {
        ctx->hw_device_ctx = av_buffer_ref(d->hwdev);
        ctx->get_format = pick_format;
      }
    }
  }
  r = avcodec_open2(ctx, codec, NULL);
  if (r < 0) goto fail;
  return ctx;
fail:
  set_err(err, errlen, video ? "Can't open the video decoder" : "Can't open the audio decoder", r);
  avcodec_free_context(&ctx);
  return NULL;
}

static void update_discard(NCDecoder *d) {
  for (unsigned i = 0; i < d->fmt->nb_streams; i++)
    d->fmt->streams[i]->discard = ((int)i == d->vidx || (int)i == d->aidx) ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
}

NCDecoder *nc_open(const char *path, int audioIndex, char *err, int errlen) {
  NCDecoder *d = av_mallocz(sizeof *d);
  if (!d) return NULL;
  d->vidx = d->aidx = d->audioSel = -1;
  d->vDropBefore = d->aDropBefore = d->vNext = d->aNext = -1;
  int r = avformat_open_input(&d->fmt, path, NULL, NULL);
  if (r < 0) {
    set_err(err, errlen, "Can't open the file", r);
    goto fail;
  }
  r = avformat_find_stream_info(d->fmt, NULL);
  if (r < 0) {
    set_err(err, errlen, "Can't read the file", r);
    goto fail;
  }
  d->start = d->fmt->start_time != AV_NOPTS_VALUE ? d->fmt->start_time / (double)AV_TIME_BASE : 0;
  d->duration = d->fmt->duration != AV_NOPTS_VALUE ? d->fmt->duration / (double)AV_TIME_BASE : 0;

  int v = av_find_best_stream(d->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  if (v >= 0 && !(d->fmt->streams[v]->disposition & AV_DISPOSITION_ATTACHED_PIC)) d->vidx = v;

  d->audioStreams = av_malloc_array(d->fmt->nb_streams ? d->fmt->nb_streams : 1, sizeof(int));
  for (unsigned i = 0; i < d->fmt->nb_streams; i++)
    if (d->fmt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) d->audioStreams[d->audioCount++] = i;

  d->pkt = av_packet_alloc();
  d->frame = av_frame_alloc();
  if (d->vidx >= 0) {
    d->vctx = open_codec(d, d->vidx, 1, err, errlen);
    if (!d->vctx) goto fail;
  }
  int a = -1;
  if (audioIndex >= 0 && audioIndex < d->audioCount) a = audioIndex;
  else if (d->audioCount) {
    int best = av_find_best_stream(d->fmt, AVMEDIA_TYPE_AUDIO, -1, d->vidx, NULL, 0);
    for (int i = 0; i < d->audioCount; i++)
      if (d->audioStreams[i] == best) a = i;
    if (a < 0) a = 0;
  }
  if (a >= 0 && nc_select_audio(d, a) < 0 && d->vidx < 0) {
    set_err(err, errlen, "Can't open the audio decoder", 0);
    goto fail;
  }
  if (d->vidx < 0 && d->aidx < 0) {
    set_err(err, errlen, "The file has no video or audio that can be played", 0);
    goto fail;
  }
  update_discard(d);
  return d;
fail:
  nc_close(d);
  return NULL;
}

void nc_close(NCDecoder *d) {
  if (!d) return;
  pq_free(&d->vq);
  pq_free(&d->aq);
  avcodec_free_context(&d->vctx);
  avcodec_free_context(&d->actx);
  av_buffer_unref(&d->hwdev);
  avformat_close_input(&d->fmt);
  av_packet_free(&d->pkt);
  av_frame_free(&d->frame);
  sws_freeContext(d->sws);
  if (d->pool) CVPixelBufferPoolRelease(d->pool);
  swr_free(&d->swr);
  av_channel_layout_uninit(&d->swrLayout);
  av_free(d->pcm);
  av_free(d->audioStreams);
  av_free(d);
}

void nc_info(NCDecoder *d, NCInfo *o) {
  memset(o, 0, sizeof *o);
  o->duration = d->duration;
  o->audioCount = d->audioCount;
  o->audioIndex = d->audioSel;
  o->sarNum = o->sarDen = 1;
  snprintf(o->container, sizeof o->container, "%s", d->fmt->iformat->name);
  if (d->vidx < 0) return;
  AVStream *st = d->fmt->streams[d->vidx];
  o->hasVideo = 1;
  o->width = d->vctx->width;
  o->height = d->vctx->height;
  AVRational sar = av_guess_sample_aspect_ratio(d->fmt, st, NULL);
  if (sar.num > 0 && sar.den > 0) {
    o->sarNum = sar.num;
    o->sarDen = sar.den;
  }
  AVRational fr = av_guess_frame_rate(d->fmt, st, NULL);
  if (fr.num > 0 && fr.den > 0) o->fps = av_q2d(fr);
  o->hardware = d->hwFrames;
  snprintf(o->videoCodec, sizeof o->videoCodec, "%s", avcodec_get_name(st->codecpar->codec_id));
}

int nc_audio_track(NCDecoder *d, int i, NCAudioTrack *o) {
  memset(o, 0, sizeof *o);
  if (i < 0 || i >= d->audioCount) return -1;
  AVStream *st = d->fmt->streams[d->audioStreams[i]];
  snprintf(o->codec, sizeof o->codec, "%s", avcodec_get_name(st->codecpar->codec_id));
  AVDictionaryEntry *e = av_dict_get(st->metadata, "language", NULL, 0);
  if (e) snprintf(o->language, sizeof o->language, "%s", e->value);
  e = av_dict_get(st->metadata, "title", NULL, 0);
  if (e) snprintf(o->title, sizeof o->title, "%s", e->value);
  o->channels = st->codecpar->ch_layout.nb_channels;
  o->isDefault = (st->disposition & AV_DISPOSITION_DEFAULT) != 0;
  return 0;
}

int nc_select_audio(NCDecoder *d, int i) {
  if (i < 0 || i >= d->audioCount) return -1;
  AVCodecContext *ctx = open_codec(d, d->audioStreams[i], 0, NULL, 0);
  if (!ctx) return -1;
  avcodec_free_context(&d->actx);
  pq_clear(&d->aq);
  d->actx = ctx;
  d->aidx = d->audioStreams[i];
  d->audioSel = i;
  d->aFlushing = 0;
  d->aNext = -1;
  if (d->fmt) update_discard(d);
  return 0;
}

int nc_seek(NCDecoder *d, double t, int exact) {
  if (t < 0) t = 0;
  int64_t ts = (int64_t)((t + d->start) * AV_TIME_BASE);
  int r = avformat_seek_file(d->fmt, -1, INT64_MIN, ts, ts, 0);
  if (r < 0) r = av_seek_frame(d->fmt, -1, ts, AVSEEK_FLAG_BACKWARD);
  pq_clear(&d->vq);
  pq_clear(&d->aq);
  if (d->vctx) avcodec_flush_buffers(d->vctx);
  if (d->actx) avcodec_flush_buffers(d->actx);
  d->demuxEof = 0;
  d->vFlushing = d->aFlushing = 0;
  d->vNext = d->aNext = -1;
  d->vDropBefore = exact ? t : -1;
  d->aDropBefore = t;
  return r < 0 ? r : 0;
}

void nc_audio_start(NCDecoder *d, double t) { d->aDropBefore = t; }

// Reads one packet into its stream's queue. 0 = read (or skipped), <0 = end of file.
static int read_packet(NCDecoder *d) {
  if (d->demuxEof) return AVERROR_EOF;
  int r = av_read_frame(d->fmt, d->pkt);
  if (r == AVERROR(EAGAIN)) return 0;
  if (r < 0) {
    d->demuxEof = 1;
    return AVERROR_EOF;
  }
  if (d->pkt->stream_index == d->vidx || d->pkt->stream_index == d->aidx) {
    AVPacket *p = av_packet_alloc();
    av_packet_move_ref(p, d->pkt);
    pq_push(p->stream_index == d->vidx ? &d->vq : &d->aq, p);
  } else {
    av_packet_unref(d->pkt);
  }
  return 0;
}

// Feeds the next queued packet of one stream to its decoder (reading the file
// as needed). 1 = fed, 0 = nothing left to feed.
static int feed(NCDecoder *d, int video) {
  PacketQueue *q = video ? &d->vq : &d->aq;
  AVCodecContext *ctx = video ? d->vctx : d->actx;
  int *flushing = video ? &d->vFlushing : &d->aFlushing;
  while (!q->count && !d->demuxEof) read_packet(d);
  AVPacket *p = pq_pop(q);
  if (!p) {
    if (*flushing) return 0;
    avcodec_send_packet(ctx, NULL);
    *flushing = 1;
    return 1;
  }
  if (video && d->vDropBefore >= 0) {
    // While catching up to a seek target, skip frames nothing else refers to.
    int64_t ts = p->pts != AV_NOPTS_VALUE ? p->pts : p->dts;
    double t = ts != AV_NOPTS_VALUE ? ts * av_q2d(d->fmt->streams[d->vidx]->time_base) - d->start : -1;
    ctx->skip_frame = (t >= 0 && t < d->vDropBefore - 0.5) ? AVDISCARD_NONREF : AVDISCARD_DEFAULT;
  }
  avcodec_send_packet(ctx, p);
  av_packet_free(&p);
  return 1;
}

static double frame_time(NCDecoder *d, AVFrame *f, int idx) {
  int64_t ts = f->best_effort_timestamp;
  if (ts == AV_NOPTS_VALUE) ts = f->pts;
  if (ts == AV_NOPTS_VALUE) return -1;
  return ts * av_q2d(d->fmt->streams[idx]->time_base) - d->start;
}

static int ensure_pool(NCDecoder *d, int w, int h, OSType fmt) {
  if (d->pool && d->poolW == w && d->poolH == h && d->poolFmt == fmt) return 0;
  if (d->pool) CVPixelBufferPoolRelease(d->pool);
  d->pool = NULL;
  CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFNumberRef nw = CFNumberCreate(NULL, kCFNumberIntType, &w);
  CFNumberRef nh = CFNumberCreate(NULL, kCFNumberIntType, &h);
  CFNumberRef nf = CFNumberCreate(NULL, kCFNumberSInt32Type, &fmt);
  CFDictionaryRef io = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(attrs, kCVPixelBufferWidthKey, nw);
  CFDictionarySetValue(attrs, kCVPixelBufferHeightKey, nh);
  CFDictionarySetValue(attrs, kCVPixelBufferPixelFormatTypeKey, nf);
  CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, io);
  CVReturn r = CVPixelBufferPoolCreate(NULL, NULL, attrs, &d->pool);
  CFRelease(nw);
  CFRelease(nh);
  CFRelease(nf);
  CFRelease(io);
  CFRelease(attrs);
  if (r != kCVReturnSuccess) return -1;
  d->poolW = w;
  d->poolH = h;
  d->poolFmt = fmt;
  return 0;
}

static void set_color(CVPixelBufferRef pb, AVFrame *f) {
  av_vt_pixbuf_set_attachments(NULL, pb, f);
  if (f->colorspace == AVCOL_SPC_UNSPECIFIED) {
    // Untagged video: standard definition is BT.601, anything bigger BT.709.
    CFStringRef m = (f->width < 1280 && f->height < 720) ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2;
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, m, kCVAttachmentMode_ShouldPropagate);
  }
}

static CVPixelBufferRef to_pixbuf(NCDecoder *d, AVFrame *f) {
  d->hwFrames = f->format == AV_PIX_FMT_VIDEOTOOLBOX;
  if (f->format == AV_PIX_FMT_VIDEOTOOLBOX) {
    CVPixelBufferRef pb = (CVPixelBufferRef)f->data[3];
    if (!pb) return NULL;
    CVPixelBufferRetain(pb);
    set_color(pb, f);
    return pb;
  }
  const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(f->format);
  if (!desc) return NULL;
  int full = f->color_range == AVCOL_RANGE_JPEG || f->format == AV_PIX_FMT_YUVJ420P ||
             f->format == AV_PIX_FMT_YUVJ422P || f->format == AV_PIX_FMT_YUVJ444P;
  enum AVPixelFormat dst;
  OSType cv;
  if (desc->flags & (AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_PAL) || desc->nb_components < 3) {
    dst = AV_PIX_FMT_BGRA;
    cv = kCVPixelFormatType_32BGRA;
    full = 1;
  } else if (desc->comp[0].depth > 8) {
    dst = AV_PIX_FMT_P010LE;
    cv = full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
  } else {
    dst = AV_PIX_FMT_NV12;
    cv = full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  }
  if (ensure_pool(d, f->width, f->height, cv) < 0) return NULL;
  CVPixelBufferRef pb = NULL;
  if (CVPixelBufferPoolCreatePixelBuffer(NULL, d->pool, &pb) != kCVReturnSuccess) return NULL;
  d->sws = sws_getCachedContext(d->sws, f->width, f->height, f->format, f->width, f->height, dst, SWS_BICUBIC, NULL, NULL, NULL);
  if (!d->sws) {
    CVPixelBufferRelease(pb);
    return NULL;
  }
  if (dst != AV_PIX_FMT_BGRA) {
    // Keep the source's range: the buffer is tagged with it.
    int *inv, *tab, srcRange, dstRange, bri, con, sat;
    if (sws_getColorspaceDetails(d->sws, &inv, &srcRange, &tab, &dstRange, &bri, &con, &sat) >= 0)
      sws_setColorspaceDetails(d->sws, inv, full, tab, full, bri, con, sat);
  }
  CVPixelBufferLockBaseAddress(pb, 0);
  uint8_t *data[4] = {0};
  int lines[4] = {0};
  if (CVPixelBufferIsPlanar(pb)) {
    for (size_t i = 0; i < CVPixelBufferGetPlaneCount(pb) && i < 4; i++) {
      data[i] = CVPixelBufferGetBaseAddressOfPlane(pb, i);
      lines[i] = (int)CVPixelBufferGetBytesPerRowOfPlane(pb, i);
    }
  } else {
    data[0] = CVPixelBufferGetBaseAddress(pb);
    lines[0] = (int)CVPixelBufferGetBytesPerRow(pb);
  }
  sws_scale(d->sws, (const uint8_t *const *)f->data, f->linesize, 0, f->height, data, lines);
  CVPixelBufferUnlockBaseAddress(pb, 0);
  set_color(pb, f);
  return pb;
}

int nc_next_video(NCDecoder *d, NCVideoFrame *out) {
  if (!d->vctx) return 0;
  AVStream *st = d->fmt->streams[d->vidx];
  for (;;) {
    int r = avcodec_receive_frame(d->vctx, d->frame);
    if (r == AVERROR_EOF) return 0;
    if (r == AVERROR(EAGAIN) || r < 0) {
      if (r < 0 && r != AVERROR(EAGAIN) && d->vFlushing) return 0;
      if (!feed(d, 1)) return 0;
      continue;
    }
    AVFrame *f = d->frame;
    double dur = f->duration > 0 ? f->duration * av_q2d(st->time_base) : 0;
    if (dur <= 0) {
      AVRational fr = av_guess_frame_rate(d->fmt, st, NULL);
      dur = fr.num > 0 && fr.den > 0 ? 1 / av_q2d(fr) : 1 / 25.0;
    }
    double t = frame_time(d, f, d->vidx);
    if (t < 0) t = d->vNext >= 0 ? d->vNext : 0;
    d->vNext = t + dur;
    if (d->vDropBefore >= 0 && t + dur <= d->vDropBefore + 1e-4) {
      av_frame_unref(f);
      continue;
    }
    d->vDropBefore = -1;
    d->vctx->skip_frame = AVDISCARD_DEFAULT;
    CVPixelBufferRef pb = to_pixbuf(d, f);
    AVRational sar = f->sample_aspect_ratio;
    av_frame_unref(f);
    if (!pb) continue;
    out->pixbuf = pb;
    out->pts = t;
    out->duration = dur;
    out->sarNum = sar.num > 0 && sar.den > 0 ? sar.num : 1;
    out->sarDen = sar.num > 0 && sar.den > 0 ? sar.den : 1;
    return 1;
  }
}

static int ensure_swr(NCDecoder *d, AVFrame *f) {
  if (d->swr && d->swrRate == f->sample_rate && d->swrFmt == f->format &&
      !av_channel_layout_compare(&d->swrLayout, &f->ch_layout))
    return 0;
  swr_free(&d->swr);
  av_channel_layout_uninit(&d->swrLayout);
  AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
  AVChannelLayout in;
  if (f->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC || !f->ch_layout.nb_channels)
    av_channel_layout_default(&in, f->ch_layout.nb_channels ? f->ch_layout.nb_channels : 2);
  else
    av_channel_layout_copy(&in, &f->ch_layout);
  int r = swr_alloc_set_opts2(&d->swr, &stereo, AV_SAMPLE_FMT_FLT, f->sample_rate, &in, f->format, f->sample_rate, 0, NULL);
  if (r >= 0) r = swr_init(d->swr);
  av_channel_layout_uninit(&in);
  if (r < 0) {
    swr_free(&d->swr);
    return r;
  }
  d->swrRate = f->sample_rate;
  d->swrFmt = f->format;
  av_channel_layout_copy(&d->swrLayout, &f->ch_layout);
  return 0;
}

int nc_next_audio(NCDecoder *d, NCAudioChunk *out) {
  if (!d->actx) return 0;
  for (;;) {
    int r = avcodec_receive_frame(d->actx, d->frame);
    if (r == AVERROR_EOF) return 0;
    if (r == AVERROR(EAGAIN) || r < 0) {
      if (r < 0 && r != AVERROR(EAGAIN) && d->aFlushing) return 0;
      if (!feed(d, 0)) return 0;
      continue;
    }
    AVFrame *f = d->frame;
    if (f->sample_rate <= 0 || f->nb_samples <= 0 || ensure_swr(d, f) < 0) {
      av_frame_unref(f);
      continue;
    }
    int need = f->nb_samples + 256;
    if (need > d->pcmCap) {
      av_free(d->pcm);
      d->pcm = av_malloc_array(need * 2, sizeof(float));
      d->pcmCap = d->pcm ? need : 0;
      if (!d->pcm) return AVERROR(ENOMEM);
    }
    uint8_t *dst = (uint8_t *)d->pcm;
    int n = swr_convert(d->swr, &dst, d->pcmCap, (const uint8_t **)f->extended_data, f->nb_samples);
    int rate = f->sample_rate;
    double t = frame_time(d, f, d->aidx);
    av_frame_unref(f);
    if (n <= 0) continue;
    // Keep chunks back to back unless the file's own timestamps jump.
    if (d->aNext >= 0 && (t < 0 || fabs(t - d->aNext) < 0.1)) t = d->aNext;
    if (t < 0) t = 0;
    d->aNext = t + n / (double)rate;
    int skip = 0;
    if (d->aDropBefore >= 0) {
      if (d->aNext <= d->aDropBefore) continue;
      if (t < d->aDropBefore) {
        skip = (int)llround((d->aDropBefore - t) * rate);
        if (skip >= n) continue;
        t += skip / (double)rate;
      }
      d->aDropBefore = -1;
    }
    out->samples = d->pcm + skip * 2;
    out->frames = n - skip;
    out->rate = rate;
    out->pts = t;
    return 1;
  }
}
