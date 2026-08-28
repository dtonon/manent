// Ogg Opus decoding to 48 kHz 16-bit PCM. libopus is compiled from the
// vendored source in src/opus by hook/build.dart; the Ogg container is parsed
// in Dart. Channel mapping family 0 only (mono and stereo).
library;

export 'src/decoder.dart'
    show OpusDecodeException, OpusPcm, decodeOggOpus, isOggOpus, opusVersion;
export 'src/ogg.dart' show isOggStream;
