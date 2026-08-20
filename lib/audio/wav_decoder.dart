import 'dart:typed_data';

// Minimal RIFF/WAVE reader: integer PCM (8/16/24/32-bit) and 32-bit float,
// any channel count. Samples are read lazily from the data chunk.
class WavPcm {
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final bool isFloat;
  final int frameCount;
  final ByteData _data;
  final int _dataOffset;

  WavPcm._({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.isFloat,
    required this.frameCount,
    required ByteData data,
    required int dataOffset,
  })  : _data = data,
        _dataOffset = dataOffset;

  double get durationSeconds => sampleRate == 0 ? 0 : frameCount / sampleRate;

  static bool looksLikeWav(Uint8List bytes) =>
      bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x41 &&
      bytes[10] == 0x56 &&
      bytes[11] == 0x45;

  static WavPcm? parse(Uint8List bytes) {
    if (!looksLikeWav(bytes)) return null;
    final bd = ByteData.sublistView(bytes);
    int pos = 12;
    int? format, channels, sampleRate, bits;
    int? dataOffset, dataLength;

    while (pos + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes, pos, pos + 4);
      final size = bd.getUint32(pos + 4, Endian.little);
      final body = pos + 8;
      if (id == 'fmt ' && body + 16 <= bytes.length) {
        format = bd.getUint16(body, Endian.little);
        channels = bd.getUint16(body + 2, Endian.little);
        sampleRate = bd.getUint32(body + 4, Endian.little);
        bits = bd.getUint16(body + 14, Endian.little);
        // WAVE_FORMAT_EXTENSIBLE: the real format is in the sub-format GUID
        if (format == 0xFFFE && size >= 26 && body + 26 <= bytes.length) {
          format = bd.getUint16(body + 24, Endian.little);
        }
      } else if (id == 'data') {
        dataOffset = body;
        dataLength = size;
        break;
      }
      // Chunks are word-aligned
      pos = body + size + (size & 1);
    }

    if (format == null ||
        channels == null ||
        sampleRate == null ||
        bits == null ||
        dataOffset == null ||
        dataLength == null) {
      return null;
    }
    final isFloat = format == 3;
    if (!(format == 1 &&
            (bits == 8 || bits == 16 || bits == 24 || bits == 32)) &&
        !(isFloat && bits == 32)) {
      return null;
    }
    if (channels < 1 || sampleRate < 1) return null;

    final available = bytes.length - dataOffset;
    final length = dataLength > available ? available : dataLength;
    final frameSize = channels * (bits ~/ 8);
    return WavPcm._(
      sampleRate: sampleRate,
      channels: channels,
      bitsPerSample: bits,
      isFloat: isFloat,
      frameCount: length ~/ frameSize,
      data: bd,
      dataOffset: dataOffset,
    );
  }

  // Sample in -1..1 for the given frame and channel
  double sample(int frame, int channel) {
    final bytesPerSample = bitsPerSample ~/ 8;
    final offset = _dataOffset + (frame * channels + channel) * bytesPerSample;
    switch (bitsPerSample) {
      case 8:
        return (_data.getUint8(offset) - 128) / 128;
      case 16:
        return _data.getInt16(offset, Endian.little) / 32768;
      case 24:
        final b0 = _data.getUint8(offset);
        final b1 = _data.getUint8(offset + 1);
        final b2 = _data.getInt8(offset + 2);
        return ((b2 << 16) | (b1 << 8) | b0) / 8388608;
      default:
        return isFloat
            ? _data.getFloat32(offset, Endian.little).clamp(-1.0, 1.0)
            : _data.getInt32(offset, Endian.little) / 2147483648;
    }
  }

  // Peak amplitude across channels, for each of [buckets] equal time slices
  List<double> peaks(int buckets) {
    if (frameCount == 0) return List.filled(buckets, 0);
    final out = List<double>.filled(buckets, 0);
    for (var b = 0; b < buckets; b++) {
      final start = frameCount * b ~/ buckets;
      final end = frameCount * (b + 1) ~/ buckets;
      final span = end - start;
      if (span <= 0) continue;
      // Stride so a bucket never scans more than ~4000 frames
      final stride = span > 4000 ? span ~/ 4000 : 1;
      var peak = 0.0;
      for (var f = start; f < end; f += stride) {
        for (var c = 0; c < channels; c++) {
          final v = sample(f, c).abs();
          if (v > peak) peak = v;
        }
      }
      out[b] = peak;
    }
    return out;
  }
}
