import 'dart:ffi';

// Direct bindings to libopus, built by hook/build.dart and registered under
// this file's asset id. Only the decoder entry points are needed.

final class OpusDecoder extends Opaque {}

@Native<Pointer<OpusDecoder> Function(Int32, Int, Pointer<Int>)>(
  symbol: 'opus_decoder_create',
)
external Pointer<OpusDecoder> opusDecoderCreate(
  int sampleRate,
  int channels,
  Pointer<Int> error,
);

@Native<
  Int Function(
    Pointer<OpusDecoder>,
    Pointer<Uint8>,
    Int32,
    Pointer<Int16>,
    Int,
    Int,
  )
>(symbol: 'opus_decode')
external int opusDecode(
  Pointer<OpusDecoder> decoder,
  Pointer<Uint8> data,
  int length,
  Pointer<Int16> pcm,
  int frameSize,
  int decodeFec,
);

@Native<Void Function(Pointer<OpusDecoder>)>(symbol: 'opus_decoder_destroy')
external void opusDecoderDestroy(Pointer<OpusDecoder> decoder);

@Native<Pointer<Utf8Char> Function()>(symbol: 'opus_get_version_string')
external Pointer<Utf8Char> opusGetVersionString();

typedef Utf8Char = Uint8;
