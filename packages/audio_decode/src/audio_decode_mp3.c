// C ABI shim over the vendored MP3 decoder, lieff's minimp3.
//
// This is the only translation unit that defines the minimp3 implementation,
// so it is compiled exactly once. It is a separate translation unit from the
// Ogg Vorbis shim (audio_decode_shim.c) on purpose: minimp3 and stb_vorbis
// each define file-local symbols with the same name (for example get_bits), so
// including both in one translation unit is a redefinition error.

#if defined(_WIN32)
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#endif

#include <limits.h>
#include <stdlib.h>
#include <string.h>

// Default configuration: 16-bit integer output (mp3d_sample_t == int16_t).
#define MINIMP3_IMPLEMENTATION
#include "minimp3.h"

#if defined(_WIN32)
#define AD_EXPORT __declspec(dllexport)
#else
#define AD_EXPORT __attribute__((visibility("default")))
#endif

// Decodes a whole MP3 stream from memory into interleaved int16 PCM.
//
// minimp3 decodes one frame per call, so this loops over the buffer, appending
// each frame's samples to a geometrically growing heap buffer and advancing by
// info.frame_bytes, which also skips ID3 tags and any leading junk before the
// first frame sync. On success returns 0 and writes the channel count, sample
// rate and per-channel sample count through the out-parameters, storing the
// interleaved buffer in `*out`. Returns non-zero on allocation failure or when
// no audio frame is found. Free the result with ad_free().
AD_EXPORT int ad_decode_mp3(const unsigned char* bytes, int len, int* channels,
                            int* rate, int* totalSamplesPerChannel,
                            short** out) {
  mp3dec_t decoder;
  mp3dec_init(&decoder);

  short* buffer = NULL;
  size_t count = 0;     // int16 samples written so far
  size_t capacity = 0;  // int16 samples the buffer can hold

  int stream_channels = 0;
  int stream_rate = 0;

  mp3d_sample_t frame_pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];
  mp3dec_frame_info_t info;

  const unsigned char* cursor = bytes;
  int remaining = len;

  while (remaining > 0) {
    int frame_samples =
        mp3dec_decode_frame(&decoder, cursor, remaining, frame_pcm, &info);

    // frame_bytes is the number of input bytes this call consumed: a decoded
    // frame, or a run of skipped tag/junk bytes. Zero means no frame sync was
    // found in what remains, so the stream is exhausted.
    if (info.frame_bytes <= 0) {
      break;
    }

    if (frame_samples > 0) {
      stream_channels = info.channels;
      stream_rate = info.hz;

      const size_t produced = (size_t)frame_samples * (size_t)info.channels;
      const size_t needed = count + produced;
      if (needed > capacity) {
        size_t new_capacity = capacity == 0 ? 16384 : capacity;
        while (new_capacity < needed) {
          new_capacity *= 2;
        }
        short* grown = (short*)realloc(buffer, new_capacity * sizeof(short));
        if (grown == NULL) {
          free(buffer);
          return 1;
        }
        buffer = grown;
        capacity = new_capacity;
      }
      memcpy(buffer + count, frame_pcm, produced * sizeof(short));
      count += produced;
    }

    cursor += info.frame_bytes;
    remaining -= info.frame_bytes;
  }

  if (buffer == NULL || stream_channels <= 0) {
    // No decodable frame: either not MP3, or a header-only stream.
    free(buffer);
    return 1;
  }

  const size_t samples_per_channel = count / (size_t)stream_channels;
  if (samples_per_channel > (size_t)INT_MAX) {
    // Narrowing to the caller's int* would wrap; report failure instead of a
    // silently corrupt sample count.
    free(buffer);
    return 1;
  }

  *channels = stream_channels;
  *rate = stream_rate;
  *totalSamplesPerChannel = (int)samples_per_channel;
  *out = buffer;
  return 0;
}

// Reads an MP3 stream's geometry without producing any audio.
//
// minimp3 parses a frame's header and returns that frame's sample count when
// `pcm` is NULL, skipping the synthesis step entirely, so this walks the same
// frames ad_decode_mp3() would but allocates nothing and does no filtering.
// The stream still has to be walked because MP3 carries no total-length field
// in its header; what is saved is the PCM buffer and the decode work, not the
// scan. On success returns 0 and writes the channel count, sample rate and
// per-channel sample count. Returns non-zero when no audio frame is found.
AD_EXPORT int ad_info_mp3(const unsigned char* bytes, int len, int* channels,
                          int* rate, int* totalSamplesPerChannel) {
  mp3dec_t decoder;
  mp3dec_init(&decoder);

  mp3dec_frame_info_t info;
  size_t samples_per_channel = 0;
  int stream_channels = 0;
  int stream_rate = 0;

  const unsigned char* cursor = bytes;
  int remaining = len;

  while (remaining > 0) {
    const int frame_samples =
        mp3dec_decode_frame(&decoder, cursor, remaining, NULL, &info);
    if (info.frame_bytes <= 0) {
      break;
    }
    if (frame_samples > 0) {
      stream_channels = info.channels;
      stream_rate = info.hz;
      samples_per_channel += (size_t)frame_samples;
    }
    cursor += info.frame_bytes;
    remaining -= info.frame_bytes;
  }

  if (stream_channels <= 0) {
    return 1;
  }
  if (samples_per_channel > (size_t)INT_MAX) {
    // Narrowing to the caller's int* would wrap; report failure instead of a
    // silently corrupt sample count.
    return 1;
  }
  *channels = stream_channels;
  *rate = stream_rate;
  *totalSamplesPerChannel = (int)samples_per_channel;
  return 0;
}
