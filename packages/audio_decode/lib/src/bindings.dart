import 'dart:ffi';

// Bindings to the C ABI shim over the vendored stb_vorbis and minimp3
// decoders. The native library is produced by hook/build.dart, which registers
// it under the asset id of this file (src/bindings.dart), so every @Native
// symbol below resolves to it.
//
// Each decode function takes the encoded bytes and their length, writes the
// channel count, sample rate and per-channel sample count through int
// out-parameters, and stores a freshly allocated buffer of interleaved int16
// samples through the `short**` out-parameter. It returns 0 on success and a
// non-zero value on failure, in which case no buffer is allocated.

/// Decodes an Ogg Vorbis stream. Returns 0 on success, non-zero on failure.
@Native<
  Int Function(
    Pointer<Uint8>,
    Int,
    Pointer<Int>,
    Pointer<Int>,
    Pointer<Int>,
    Pointer<Pointer<Int16>>,
  )
>(symbol: 'ad_decode_vorbis')
external int adDecodeVorbis(
  Pointer<Uint8> bytes,
  int length,
  Pointer<Int> outChannels,
  Pointer<Int> outRate,
  Pointer<Int> outSamplesPerChannel,
  Pointer<Pointer<Int16>> outSamples,
);

/// Decodes an MP3 stream. Returns 0 on success, non-zero on failure.
@Native<
  Int Function(
    Pointer<Uint8>,
    Int,
    Pointer<Int>,
    Pointer<Int>,
    Pointer<Int>,
    Pointer<Pointer<Int16>>,
  )
>(symbol: 'ad_decode_mp3')
external int adDecodeMp3(
  Pointer<Uint8> bytes,
  int length,
  Pointer<Int> outChannels,
  Pointer<Int> outRate,
  Pointer<Int> outTotalSamplesPerChannel,
  Pointer<Pointer<Int16>> outSamples,
);

/// Reads an Ogg Vorbis stream's geometry without decoding audio. Returns 0 on
/// success, non-zero on failure. Allocates nothing, so there is no buffer to
/// free.
@Native<
  Int Function(Pointer<Uint8>, Int, Pointer<Int>, Pointer<Int>, Pointer<Int>)
>(symbol: 'ad_info_vorbis')
external int adInfoVorbis(
  Pointer<Uint8> bytes,
  int length,
  Pointer<Int> outChannels,
  Pointer<Int> outRate,
  Pointer<Int> outSamplesPerChannel,
);

/// Reads an MP3 stream's geometry without producing audio. Returns 0 on
/// success, non-zero on failure.
@Native<
  Int Function(Pointer<Uint8>, Int, Pointer<Int>, Pointer<Int>, Pointer<Int>)
>(symbol: 'ad_info_mp3')
external int adInfoMp3(
  Pointer<Uint8> bytes,
  int length,
  Pointer<Int> outChannels,
  Pointer<Int> outRate,
  Pointer<Int> outSamplesPerChannel,
);

/// Frees a sample buffer returned by [adDecodeVorbis] or [adDecodeMp3].
@Native<Void Function(Pointer<Int16>)>(symbol: 'ad_free')
external void adFree(Pointer<Int16> samples);
