/// Native Ogg Vorbis and MP3 decoding to raw PCM for Dart, backed by Sean
/// Barrett's stb_vorbis and lieff's minimp3 over FFI.
///
/// The C decoders are compiled from source by a Dart build hook, so there is
/// no prebuilt binary to ship and no platform plugin or system library to
/// install beyond a C toolchain. Decoding runs in native code and copies the
/// result into a Dart [Int16List], so callers never manage native memory. The
/// same code path runs in pure Dart (CLI, servers, tests) and in Flutter.
///
/// Decoding is deterministic for a given build, and the geometry it reports is
/// the same everywhere. Sample values are not bit-identical across CPU
/// architectures: the decoders compute in floating point, so around 0.03% of
/// samples can differ by one least-significant bit between arm64 and x86-64.
/// Do not compare checksums of decoded PCM across a mixed fleet.
///
/// This is a decoder, not a player: it turns encoded bytes into PCM samples
/// for waveforms, analysis, resampling, machine-learning preprocessing, games
/// and servers. For playback, pair it with a player package such as just_audio
/// or flutter_sound. [encodeWav] writes the decoded PCM back out as a WAV file
/// so the samples can be saved or handed to other tools.
///
/// ```dart
/// import 'dart:io';
/// import 'package:audio_decode/audio_decode.dart';
///
/// void main() {
///   final bytes = File('clip.mp3').readAsBytesSync();
///   final pcm = decodeAudio(bytes);
///   print('${pcm.sampleRate} Hz, ${pcm.channels} ch, ${pcm.duration}');
///   File('clip.wav').writeAsBytesSync(encodeWav(pcm));
/// }
/// ```
///
/// See [decodeAudio], [decodeOgg], [decodeMp3], [detectFormat], [PcmAudio] and
/// [encodeWav] for the full API.
library;

export 'src/audio_decode_base.dart'
    show
        AudioDecodeException,
        AudioFormat,
        AudioInfo,
        PcmAudio,
        audioInfo,
        decodeAudio,
        decodeMp3,
        decodeOgg,
        detectFormat,
        encodeWav,
        mp3Info,
        oggInfo;
export 'src/resample.dart' show resample, toMono, toSpeechPcm;
export 'src/wav_decoder.dart' show decodeWav, wavInfo;
