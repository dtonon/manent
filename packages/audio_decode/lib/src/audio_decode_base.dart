import 'dart:ffi';
import 'dart:typed_data';

import 'wav_decoder.dart';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

/// The container format of an encoded audio buffer, as identified by
/// [detectFormat].
enum AudioFormat {
  /// Ogg Vorbis, decoded by [decodeOgg].
  ogg,

  /// MPEG audio (MP3), decoded by [decodeMp3].
  mp3,

  /// Uncompressed RIFF/WAVE, decoded by [decodeWav].
  wav,

  /// Not a format this package recognises.
  unknown,
}

/// Thrown when decoding fails: the bytes are not valid audio of the expected
/// format, or the native decoder rejected them.
///
/// [ArgumentError] is used instead for programming errors such as empty input;
/// this exception is reserved for bad or corrupt data.
final class AudioDecodeException implements Exception {
  /// Creates an exception with a human-readable [message].
  AudioDecodeException(this.message);

  /// A short description of what went wrong.
  final String message;

  @override
  String toString() => 'AudioDecodeException: $message';
}

/// Decoded pulse-code-modulation audio: raw 16-bit samples plus their
/// geometry.
///
/// [samples] holds signed 16-bit samples interleaved by channel, so for stereo
/// the order is left, right, left, right and so on. A single audio frame is one
/// sample per channel; [frameCount] is the number of frames and [duration] is
/// how long they play at [sampleRate].
final class PcmAudio {
  /// Creates a [PcmAudio] from its geometry and interleaved [samples].
  ///
  /// `samples.length` must be a whole multiple of [channels]; the decoders in
  /// this package always produce such a buffer.
  PcmAudio({
    required this.sampleRate,
    required this.channels,
    required this.samples,
  });

  /// Samples per second per channel, for example 44100 or 48000.
  final int sampleRate;

  /// The number of interleaved channels: 1 for mono, 2 for stereo.
  final int channels;

  /// The signed 16-bit samples, interleaved by channel.
  final Int16List samples;

  /// The number of audio frames, where one frame is a sample for every
  /// channel. Equals `samples.length ~/ channels`.
  int get frameCount => channels == 0 ? 0 : samples.length ~/ channels;

  /// How long the audio plays at [sampleRate].
  Duration get duration => sampleRate == 0
      ? Duration.zero
      : Duration(microseconds: (frameCount * 1000000) ~/ sampleRate);

  /// The samples as normalized floats in the range `[-1.0, 1.0]`, interleaved
  /// by channel like [samples].
  ///
  /// Each 16-bit sample is divided by 32768, so the full-scale negative value
  /// -32768 maps to -1.0 and +16384 maps to 0.5. This is the form most FFT,
  /// machine-learning and waveform code expects; use it instead of dividing
  /// [samples] by hand.
  Float32List toFloat32() {
    final out = Float32List(samples.length);
    for (var i = 0; i < samples.length; i++) {
      out[i] = samples[i] / _int16Scale;
    }
    return out;
  }

  /// The normalized samples of a single channel, deinterleaved.
  ///
  /// [index] selects the channel, from 0 up to `channels - 1`; for stereo, 0 is
  /// the left channel and 1 is the right. The result has one value per frame,
  /// each divided by 32768 into the range `[-1.0, 1.0]` like [toFloat32].
  ///
  /// Throws a [RangeError] if [index] is not a valid channel.
  Float32List channel(int index) {
    if (index < 0 || index >= channels) {
      throw RangeError.range(index, 0, channels - 1, 'index');
    }
    final frames = frameCount;
    final out = Float32List(frames);
    for (var i = 0; i < frames; i++) {
      out[i] = samples[i * channels + index] / _int16Scale;
    }
    return out;
  }

  /// A single-channel copy of this audio, averaging the channels frame by frame.
  ///
  /// The [sampleRate] is preserved and the result has `channels == 1`; each
  /// mono sample is the mean of that frame's channel samples, rounded to the
  /// nearest 16-bit value. Returns this instance unchanged when it is already
  /// mono.
  PcmAudio toMono() {
    if (channels <= 1) return this;
    final frames = frameCount;
    final mono = Int16List(frames);
    for (var i = 0; i < frames; i++) {
      final base = i * channels;
      var sum = 0;
      for (var c = 0; c < channels; c++) {
        sum += samples[base + c];
      }
      mono[i] = (sum / channels).round();
    }
    return PcmAudio(sampleRate: sampleRate, channels: 1, samples: mono);
  }
}

/// Full-scale divisor for signed 16-bit PCM: samples run to -32768, so dividing
/// by 32768 maps them into `[-1.0, 1.0]`.
const double _int16Scale = 32768.0;

/// Identifies the container format of [bytes] from its leading bytes.
///
/// Ogg streams begin with the capture pattern `OggS`. MP3 streams begin with
/// either an `ID3` tag or an MPEG frame sync (`0xFF` followed by a byte whose
/// top three bits are set). Anything else is [AudioFormat.unknown]. This reads
/// only a handful of bytes and never throws.
AudioFormat detectFormat(Uint8List bytes) {
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 && // 'R'
      bytes[1] == 0x49 && // 'I'
      bytes[2] == 0x46 && // 'F'
      bytes[3] == 0x46 && // 'F'
      bytes[8] == 0x57 && // 'W'
      bytes[9] == 0x41 && // 'A'
      bytes[10] == 0x56 && // 'V'
      bytes[11] == 0x45) {
    // 'E' — the RIFF tag alone is not enough; AVI and others share it.
    return AudioFormat.wav;
  }
  if (bytes.length >= 4 &&
      bytes[0] == 0x4F && // 'O'
      bytes[1] == 0x67 && // 'g'
      bytes[2] == 0x67 && // 'g'
      bytes[3] == 0x53) {
    // 'S'
    return AudioFormat.ogg;
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0x49 && // 'I'
      bytes[1] == 0x44 && // 'D'
      bytes[2] == 0x33) {
    // '3' (ID3v2 tag)
    return AudioFormat.mp3;
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {
    // MPEG audio frame sync: 11 set bits across the first two bytes.
    return AudioFormat.mp3;
  }
  return AudioFormat.unknown;
}

/// Decodes an Ogg Vorbis stream to 16-bit PCM.
///
/// ```dart
/// final pcm = decodeOgg(await File('clip.ogg').readAsBytes());
/// print('${pcm.sampleRate} Hz, ${pcm.channels} ch, ${pcm.duration}');
/// ```
///
/// Throws an [ArgumentError] if [bytes] is empty, and an [AudioDecodeException]
/// if the bytes are not a decodable Vorbis stream.
PcmAudio decodeOgg(Uint8List bytes) =>
    _decode(bytes, adDecodeVorbis, 'Ogg Vorbis');

/// Decodes an MP3 stream to 16-bit PCM.
///
/// Leading ID3v2 tags and junk before the first frame are skipped. Because MP3
/// is a lossy frame format, the decoded length includes the codec's own
/// encoder and decoder delay, so it is typically a little longer than the
/// original audio (on the order of a thousand samples per channel).
///
/// ```dart
/// final pcm = decodeMp3(await File('clip.mp3').readAsBytes());
/// ```
///
/// Throws an [ArgumentError] if [bytes] is empty, and an [AudioDecodeException]
/// if no decodable MP3 frame is found.
PcmAudio decodeMp3(Uint8List bytes) => _decode(bytes, adDecodeMp3, 'MP3');

/// Decodes [bytes] after sniffing its format with [detectFormat], dispatching
/// to [decodeOgg], [decodeMp3] or [decodeWav].
///
/// ```dart
/// final pcm = decodeAudio(await File('clip.mp3').readAsBytes());
/// ```
///
/// Throws an [ArgumentError] if [bytes] is empty, and an [AudioDecodeException]
/// if the format is none of Ogg Vorbis, MP3 or WAV.
PcmAudio decodeAudio(Uint8List bytes) {
  _checkNotEmpty(bytes);
  switch (detectFormat(bytes)) {
    case AudioFormat.ogg:
      return decodeOgg(bytes);
    case AudioFormat.mp3:
      return decodeMp3(bytes);
    case AudioFormat.wav:
      return decodeWav(bytes);
    case AudioFormat.unknown:
      throw AudioDecodeException('unrecognized audio format');
  }
}

/// An audio stream's geometry, read without decoding it to PCM.
///
/// This is what [PcmAudio] reports minus the samples themselves. Reach for it
/// when you only need the shape of a file: showing track lengths in a
/// playlist, validating an upload's duration, or picking which files to
/// process. Decoding a whole album to PCM just to display its running time
/// costs orders of magnitude more memory than the answer is worth.
final class AudioInfo {
  /// Creates an [AudioInfo]; normally you get one from [audioInfo].
  const AudioInfo({
    required this.sampleRate,
    required this.channels,
    required this.frameCount,
  });

  /// Frames per second.
  final int sampleRate;

  /// Interleaved channel count: 1 is mono, 2 is stereo.
  final int channels;

  /// The number of frames, that is samples per channel.
  final int frameCount;

  /// How long the audio plays at [sampleRate].
  Duration get duration => sampleRate == 0
      ? Duration.zero
      : Duration(microseconds: (frameCount * 1000000) ~/ sampleRate);

  @override
  bool operator ==(Object other) =>
      other is AudioInfo &&
      sampleRate == other.sampleRate &&
      channels == other.channels &&
      frameCount == other.frameCount;

  @override
  int get hashCode => Object.hash(sampleRate, channels, frameCount);

  @override
  String toString() =>
      'AudioInfo($sampleRate Hz, $channels ch, $frameCount frames, $duration)';
}

/// Reads an Ogg Vorbis stream's geometry without decoding any audio.
///
/// Vorbis stores the stream length in its container, so this is answered from
/// the header pages: no frames are decoded and no PCM is allocated.
///
/// Throws an [ArgumentError] if [bytes] is empty, and an [AudioDecodeException]
/// if the bytes are not a readable Vorbis stream.
AudioInfo oggInfo(Uint8List bytes) => _info(bytes, adInfoVorbis, 'Ogg Vorbis');

/// Reads an MP3 stream's geometry without producing any audio.
///
/// MP3 carries no total-length field, so the frame headers still have to be
/// walked; what is skipped is the decoding itself and the PCM buffer, which is
/// where the time and the memory go. The frame count matches [decodeMp3]'s,
/// including the codec's encoder and decoder delay.
///
/// Throws an [ArgumentError] if [bytes] is empty, and an [AudioDecodeException]
/// if no MP3 frame is found.
AudioInfo mp3Info(Uint8List bytes) => _info(bytes, adInfoMp3, 'MP3');

/// Reads [bytes]'s geometry after sniffing its format with [detectFormat],
/// dispatching to [oggInfo], [mp3Info] or [wavInfo].
///
/// ```dart
/// final info = audioInfo(await File('track.mp3').readAsBytes());
/// print('${info.duration} at ${info.sampleRate} Hz');
/// ```
///
/// Throws an [ArgumentError] if [bytes] is empty, and an [AudioDecodeException]
/// if the format is none of Ogg Vorbis, MP3 or WAV.
AudioInfo audioInfo(Uint8List bytes) {
  _checkNotEmpty(bytes);
  switch (detectFormat(bytes)) {
    case AudioFormat.ogg:
      return oggInfo(bytes);
    case AudioFormat.mp3:
      return mp3Info(bytes);
    case AudioFormat.wav:
      return wavInfo(bytes);
    case AudioFormat.unknown:
      throw AudioDecodeException('unrecognized audio format');
  }
}

/// Encodes [audio] as a canonical 16-bit PCM WAV (RIFF) file.
///
/// The result is a standard little-endian WAV with a 44-byte header and the
/// interleaved samples, playable by any audio tool and a convenient bridge to
/// the rest of the ecosystem. This is a pure-Dart writer; it never calls into
/// native code.
///
/// ```dart
/// final pcm = decodeMp3(await File('clip.mp3').readAsBytes());
/// await File('clip.wav').writeAsBytes(encodeWav(pcm));
/// ```
Uint8List encodeWav(PcmAudio audio) {
  const headerSize = 44;
  const bitsPerSample = 16;
  const bytesPerSample = bitsPerSample ~/ 8;
  final channels = audio.channels;
  final sampleRate = audio.sampleRate;
  final dataLength = audio.samples.length * bytesPerSample;
  final byteRate = sampleRate * channels * bytesPerSample;
  final blockAlign = channels * bytesPerSample;

  final bytes = Uint8List(headerSize + dataLength);
  final view = ByteData.sublistView(bytes);

  // RIFF chunk descriptor.
  _writeAscii(bytes, 0, 'RIFF');
  view.setUint32(4, 36 + dataLength, Endian.little);
  _writeAscii(bytes, 8, 'WAVE');

  // fmt sub-chunk.
  _writeAscii(bytes, 12, 'fmt ');
  view.setUint32(16, 16, Endian.little); // PCM fmt chunk size
  view.setUint16(20, 1, Endian.little); // audio format 1 = PCM
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, byteRate, Endian.little);
  view.setUint16(32, blockAlign, Endian.little);
  view.setUint16(34, bitsPerSample, Endian.little);

  // data sub-chunk.
  _writeAscii(bytes, 36, 'data');
  view.setUint32(40, dataLength, Endian.little);
  for (var i = 0; i < audio.samples.length; i++) {
    view.setInt16(
      headerSize + i * bytesPerSample,
      audio.samples[i],
      Endian.little,
    );
  }
  return bytes;
}

/// The shared decode path: validate, copy into native memory, call the decoder,
/// copy the samples back into a Dart [Int16List] and free the native buffer.
typedef _DecodeFn =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Int>,
      Pointer<Int>,
      Pointer<Int>,
      Pointer<Pointer<Int16>>,
    );

PcmAudio _decode(Uint8List bytes, _DecodeFn decode, String formatName) {
  _checkNotEmpty(bytes);

  final dataPtr = malloc<Uint8>(bytes.length);
  final outChannels = malloc<Int>();
  final outRate = malloc<Int>();
  final outSamplesPerChannel = malloc<Int>();
  final outSamples = malloc<Pointer<Int16>>();
  Pointer<Int16>? nativeSamples;
  try {
    dataPtr.asTypedList(bytes.length).setAll(0, bytes);
    final rc = decode(
      dataPtr,
      bytes.length,
      outChannels,
      outRate,
      outSamplesPerChannel,
      outSamples,
    );
    if (rc != 0) {
      throw AudioDecodeException('not a decodable $formatName stream');
    }
    final channels = outChannels.value;
    final rate = outRate.value;
    final samplesPerChannel = outSamplesPerChannel.value;
    if (samplesPerChannel <= 0 || channels <= 0 || rate <= 0) {
      // A stream whose header parses but which yields nothing. Truncating an
      // Ogg file part way through its first audio page lands here: the decoder
      // reports success and zero frames, and every caller then works with an
      // empty result it never checked for. There is no input for which an
      // empty decode is a useful answer, so it is an error.
      nativeSamples = outSamples.value;
      if (nativeSamples != nullptr) adFree(nativeSamples);
      nativeSamples = null;
      throw AudioDecodeException(
        'decoded no audio from this $formatName stream; it is empty or '
        'truncated before the first complete audio frame',
      );
    }
    nativeSamples = outSamples.value;
    final total = channels * samplesPerChannel;
    // Copy out of native memory before freeing it; callers never see a native
    // pointer.
    final samples = Int16List.fromList(nativeSamples.asTypedList(total));
    adFree(nativeSamples);
    nativeSamples = null;
    return PcmAudio(sampleRate: rate, channels: channels, samples: samples);
  } finally {
    malloc.free(dataPtr);
    malloc.free(outChannels);
    malloc.free(outRate);
    malloc.free(outSamplesPerChannel);
    malloc.free(outSamples);
    // Catches a native buffer that was allocated but never reached adFree(),
    // for example because copying it out threw.
    if (nativeSamples != null) {
      adFree(nativeSamples);
    }
  }
}

typedef _InfoFn =
    int Function(Pointer<Uint8>, int, Pointer<Int>, Pointer<Int>, Pointer<Int>);

AudioInfo _info(Uint8List bytes, _InfoFn readInfo, String formatName) {
  _checkNotEmpty(bytes);

  final dataPtr = malloc<Uint8>(bytes.length);
  final outChannels = malloc<Int>();
  final outRate = malloc<Int>();
  final outFrames = malloc<Int>();
  try {
    dataPtr.asTypedList(bytes.length).setAll(0, bytes);
    final rc = readInfo(dataPtr, bytes.length, outChannels, outRate, outFrames);
    if (rc != 0) {
      throw AudioDecodeException('not a readable $formatName stream');
    }
    return AudioInfo(
      sampleRate: outRate.value,
      channels: outChannels.value,
      frameCount: outFrames.value,
    );
  } finally {
    malloc.free(dataPtr);
    malloc.free(outChannels);
    malloc.free(outRate);
    malloc.free(outFrames);
  }
}

void _checkNotEmpty(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw ArgumentError.value(bytes, 'bytes', 'must not be empty');
  }
}

void _writeAscii(Uint8List bytes, int offset, String ascii) {
  for (var i = 0; i < ascii.length; i++) {
    bytes[offset + i] = ascii.codeUnitAt(i);
  }
}
