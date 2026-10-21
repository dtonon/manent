import 'dart:typed_data';

import 'audio_decode_base.dart';

/// Decodes a RIFF/WAVE file holding uncompressed audio.
///
/// This is the one format here that needs no native code: a WAV file is a
/// header and the samples themselves. It is also the format [encodeWav]
/// writes, so without it the package could not read back what it had just
/// written.
///
/// Handles integer PCM at 8, 16, 24 and 32 bits and IEEE float at 32 and 64,
/// converting all of them to the signed 16-bit samples [PcmAudio] carries.
/// Compressed payloads inside a WAV container — ADPCM, µ-law, an MP3 in a
/// RIFF wrapper — are rejected by name rather than decoded as noise. The
/// big-endian RIFX variant is not read; it is rare enough that guessing at it
/// would be worse than saying so.
///
/// Throws an [AudioDecodeException] when the file is truncated, when a
/// required chunk is missing, or when the payload is a codec this does not
/// implement.
PcmAudio decodeWav(Uint8List bytes) {
  final header = _parseWav(bytes);
  final formatTag = header.formatTag;
  final bitsPerSample = header.bitsPerSample;
  final channels = header.channels;
  final samples = header.samples;

  final pcm = switch ((formatTag, bitsPerSample)) {
    (1, 8) => _fromUint8(samples),
    (1, 16) => _fromInt16(samples),
    (1, 24) => _fromInt24(samples),
    (1, 32) => _fromInt32(samples),
    (3, 32) => _fromFloat32(samples),
    (3, 64) => _fromFloat64(samples),
    _ => throw AudioDecodeException(
      'WAV payload is ${_codecName(formatTag)} at $bitsPerSample bits, which '
      'this package does not decode; it reads uncompressed PCM and IEEE float',
    ),
  };

  // A file whose data chunk does not divide evenly by its channel count is
  // malformed; drop the partial frame rather than shifting every later sample
  // into the wrong channel.
  final usable = pcm.length - (pcm.length % channels);
  return PcmAudio(
    sampleRate: header.sampleRate,
    channels: channels,
    samples: usable == pcm.length ? pcm : Int16List.sublistView(pcm, 0, usable),
  );
}

/// Reads a WAV file's geometry from its header, without decoding the samples.
///
/// The frame count comes from the size of the data chunk rather than from
/// counting anything, so this costs the same on a four-second clip and a
/// four-hour recording.
AudioInfo wavInfo(Uint8List bytes) {
  final header = _parseWav(bytes);
  final bytesPerFrame = (header.bitsPerSample ~/ 8) * header.channels;
  if (bytesPerFrame < 1) {
    throw AudioDecodeException(
      'WAV file declares ${header.bitsPerSample} bits across '
      '${header.channels} channels, which describes no frame',
    );
  }
  return AudioInfo(
    sampleRate: header.sampleRate,
    channels: header.channels,
    frameCount: header.samples.length ~/ bytesPerFrame,
  );
}

/// The fields both [decodeWav] and [wavInfo] need, plus the raw sample bytes.
final class _WavHeader {
  const _WavHeader({
    required this.formatTag,
    required this.channels,
    required this.sampleRate,
    required this.bitsPerSample,
    required this.samples,
  });

  final int formatTag;
  final int channels;
  final int sampleRate;
  final int bitsPerSample;
  final Uint8List samples;
}

_WavHeader _parseWav(Uint8List bytes) {
  if (bytes.length < 12) {
    throw AudioDecodeException('not a WAV file: shorter than a RIFF header');
  }
  final data = ByteData.sublistView(bytes);
  if (!_tagAt(bytes, 0, 'RIFF') || !_tagAt(bytes, 8, 'WAVE')) {
    throw AudioDecodeException('not a WAV file: missing the RIFF/WAVE tags');
  }

  int? formatTag;
  var channels = 0;
  var sampleRate = 0;
  var bitsPerSample = 0;
  Uint8List? samples;

  // Walk the chunk list rather than assuming fmt comes first and data second.
  // Real files carry LIST, fact and cue chunks in between, and a writer is
  // free to order them as it likes.
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes, offset, offset + 4);
    final size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    // Chunks are word-aligned: an odd size is followed by a pad byte.
    final next = body + size + (size.isOdd ? 1 : 0);

    if (id == 'fmt ') {
      if (size < 16 || body + 16 > bytes.length) {
        throw AudioDecodeException('WAV fmt chunk is truncated');
      }
      formatTag = data.getUint16(body, Endian.little);
      channels = data.getUint16(body + 2, Endian.little);
      sampleRate = data.getUint32(body + 4, Endian.little);
      bitsPerSample = data.getUint16(body + 14, Endian.little);
      // WAVE_FORMAT_EXTENSIBLE keeps the real codec in a sub-format GUID whose
      // first two bytes are the tag it stands in for.
      if (formatTag == 0xFFFE && size >= 40 && body + 26 <= bytes.length) {
        formatTag = data.getUint16(body + 24, Endian.little);
      }
    } else if (id == 'data') {
      // A streamed file can carry a placeholder length; take what is there.
      final end = body + size <= bytes.length ? body + size : bytes.length;
      if (body > end) throw AudioDecodeException('WAV data chunk is truncated');
      samples = Uint8List.sublistView(bytes, body, end);
    }

    if (next <= offset) break; // A zero-size loop would never terminate.
    offset = next;
  }

  if (formatTag == null) {
    throw AudioDecodeException('WAV file has no fmt chunk');
  }
  if (samples == null) {
    throw AudioDecodeException('WAV file has no data chunk');
  }
  if (channels < 1) {
    throw AudioDecodeException('WAV file declares $channels channels');
  }
  if (sampleRate < 1) {
    throw AudioDecodeException(
      'WAV file declares a sample rate of $sampleRate',
    );
  }
  return _WavHeader(
    formatTag: formatTag,
    channels: channels,
    sampleRate: sampleRate,
    bitsPerSample: bitsPerSample,
    samples: samples,
  );
}

bool _tagAt(Uint8List bytes, int offset, String tag) {
  for (var i = 0; i < tag.length; i++) {
    if (bytes[offset + i] != tag.codeUnitAt(i)) return false;
  }
  return true;
}

String _codecName(int tag) => switch (tag) {
  0x0002 => 'MS ADPCM',
  0x0006 => 'A-law',
  0x0007 => 'µ-law',
  0x0011 => 'IMA ADPCM',
  0x0055 => 'MP3',
  _ => 'format tag 0x${tag.toRadixString(16).padLeft(4, '0')}',
};

/// 8-bit WAV is unsigned, centred on 128, unlike every other width.
Int16List _fromUint8(Uint8List raw) {
  final out = Int16List(raw.length);
  for (var i = 0; i < raw.length; i++) {
    out[i] = (raw[i] - 128) << 8;
  }
  return out;
}

Int16List _fromInt16(Uint8List raw) {
  final count = raw.length ~/ 2;
  final view = ByteData.sublistView(raw);
  final out = Int16List(count);
  for (var i = 0; i < count; i++) {
    out[i] = view.getInt16(i * 2, Endian.little);
  }
  return out;
}

Int16List _fromInt24(Uint8List raw) {
  final count = raw.length ~/ 3;
  final out = Int16List(count);
  for (var i = 0; i < count; i++) {
    // Keep the top 16 bits; the low byte is below what Int16 can hold.
    out[i] = (raw[i * 3 + 1] | (raw[i * 3 + 2] << 8)).toSigned(16);
  }
  return out;
}

Int16List _fromInt32(Uint8List raw) {
  final count = raw.length ~/ 4;
  final view = ByteData.sublistView(raw);
  final out = Int16List(count);
  for (var i = 0; i < count; i++) {
    out[i] = view.getInt32(i * 4, Endian.little) >> 16;
  }
  return out;
}

Int16List _fromFloat32(Uint8List raw) {
  final count = raw.length ~/ 4;
  final view = ByteData.sublistView(raw);
  final out = Int16List(count);
  for (var i = 0; i < count; i++) {
    out[i] = _clampToInt16(view.getFloat32(i * 4, Endian.little));
  }
  return out;
}

Int16List _fromFloat64(Uint8List raw) {
  final count = raw.length ~/ 8;
  final view = ByteData.sublistView(raw);
  final out = Int16List(count);
  for (var i = 0; i < count; i++) {
    out[i] = _clampToInt16(view.getFloat64(i * 8, Endian.little));
  }
  return out;
}

/// Float WAV nominally runs -1..1 but recordings overshoot, and NaN appears in
/// files written by broken encoders. Clamping keeps both from wrapping into a
/// loud opposite-sign sample.
int _clampToInt16(double value) {
  if (value.isNaN) return 0;
  final scaled = value * 32767.0;
  if (scaled >= 32767.0) return 32767;
  if (scaled <= -32768.0) return -32768;
  return scaled.round();
}
