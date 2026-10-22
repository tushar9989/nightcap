// The part of the Nightcap player that talks to ffmpeg: opens a file, reads it,
// decodes video into CVPixelBuffers (VideoToolbox for HD H.264/HEVC/ProRes) and
// audio into interleaved float32 stereo. Not thread-safe: one thread drives it.
// Times are seconds from the start of the file (the container's start offset
// is removed), the same timeline the engine uses for progress and detection.
#ifndef NCDECODER_H
#define NCDECODER_H

#include <CoreVideo/CoreVideo.h>
#include <stdint.h>

typedef struct NCDecoder NCDecoder;

typedef struct {
  double duration;      // 0 when unknown
  int hasVideo;
  int width, height;    // coded size
  int sarNum, sarDen;   // pixel aspect ratio (1:1 when unknown)
  double fps;           // 0 when unknown
  int audioCount;       // audio streams in the file
  int audioIndex;       // the selected one (0-based among audio streams), -1 none
  int hardware;         // 1 when the last frame came from VideoToolbox
  char videoCodec[32];
  char container[64];
} NCInfo;

typedef struct {
  char codec[32];
  char language[16];
  char title[128];
  int channels;
  int isDefault;
} NCAudioTrack;

typedef struct {
  CVPixelBufferRef pixbuf;  // retained: the caller releases it
  double pts, duration;
  int sarNum, sarDen;
} NCVideoFrame;

typedef struct {
  const float *samples;  // interleaved stereo, owned by the decoder until the next call
  int frames;
  int rate;
  double pts;
} NCAudioChunk;

// Returns NULL and fills err on failure.
NCDecoder *nc_open(const char *path, int audioIndex, char *err, int errlen);
void nc_close(NCDecoder *d);
void nc_info(NCDecoder *d, NCInfo *out);
int nc_audio_track(NCDecoder *d, int i, NCAudioTrack *out);
// Switches the audio stream (0-based among audio streams); seek afterwards to refill.
int nc_select_audio(NCDecoder *d, int i);

// Jumps to the keyframe at or before t. With exact, frames before t are decoded
// but not returned; otherwise the keyframe itself comes first.
int nc_seek(NCDecoder *d, double t, int exact);
// Audio before t is dropped (set after the first video frame of a seek is known).
void nc_audio_start(NCDecoder *d, double t);

// 1 = a frame, 0 = end of stream, <0 = error.
int nc_next_video(NCDecoder *d, NCVideoFrame *out);
int nc_next_audio(NCDecoder *d, NCAudioChunk *out);

#endif
