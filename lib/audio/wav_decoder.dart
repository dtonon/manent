import 'dart:math' as math;
import 'dart:typed_data';

// Minimal RIFF/WAVE reader: integer PCM (8/16/24/32-bit) and 32-bit float,
// any channel count. Samples are read lazily from the data chunk.
// encodeWavPcm16 at the bottom is the matching writer for 16-bit PCM.
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

// Scales 16-bit PCM so the loudest sample reaches [targetPeak], with the gain
// capped at [maxGain] so near-silent takes are not turned into noise. Other
// formats are returned unchanged. Modifies and returns the same bytes.
Uint8List normalizeWavInPlace(
  Uint8List bytes, {
  double targetPeak = 0.9,
  double maxGain = 32,
}) {
  final wav = WavPcm.parse(bytes);
  if (wav == null || wav.bitsPerSample != 16 || wav.frameCount == 0) {
    return bytes;
  }
  final bd = ByteData.sublistView(bytes);
  final start = wav._dataOffset;
  final end = start + wav.frameCount * wav.channels * 2;

  var peak = 0;
  for (var o = start; o < end; o += 2) {
    final v = bd.getInt16(o, Endian.little).abs();
    if (v > peak) peak = v;
  }
  if (peak == 0) return bytes;

  final gain = (targetPeak * 32767 / peak).clamp(0.0, maxGain);
  if (gain <= 1.0) return bytes;

  for (var o = start; o < end; o += 2) {
    final v = (bd.getInt16(o, Endian.little) * gain).round();
    bd.setInt16(o, v.clamp(-32768, 32767), Endian.little);
  }
  return bytes;
}

// Cuts the silence before the first and after the last [windowMs] window
// that rises clearly above the recording's own noise floor, keeping [leadMs]
// and [tailMs] of padding. Levels are measured after pre-emphasis
// (x[n] - [preEmphasis] * x[n-1]), a first-order high-pass that keeps the
// speech harmonics but drops the handling rumble and mic hiss that otherwise
// anchor the ends. The floor is the RMS of the quietest tenth of the windows
// and speech must exceed it by [marginDb], a threshold then clamped to
// [minBelowPeakDb]..[maxBelowPeakDb] under the peak, which is the loudest
// 100 ms median so a single tap cannot set it. A window only counts as speech
// when most of its [sustainWindows] neighbourhood is loud too. 16-bit PCM
// only; other formats and all-silent input are returned unchanged. Returns a
// new buffer with the chunk sizes rewritten.
Uint8List trimWavSilence(
  Uint8List bytes, {
  int windowMs = 20,
  int leadMs = 150,
  int tailMs = 300,
  double preEmphasis = 0.97,
  double marginDb = 12,
  double minBelowPeakDb = 15,
  double maxBelowPeakDb = 25,
  int sustainWindows = 11,
}) {
  final wav = WavPcm.parse(bytes);
  if (wav == null || wav.bitsPerSample != 16 || wav.frameCount == 0) {
    return bytes;
  }
  final bd = ByteData.sublistView(bytes);
  final start = wav._dataOffset;
  final frameBytes = wav.channels * 2;
  final windowFrames = math.max(1, wav.sampleRate * windowMs ~/ 1000);

  // Some mics sit off centre, which would lift the RMS of silence too
  final end = start + wav.frameCount * frameBytes;
  var total = 0;
  for (var o = start; o < end; o += 2) {
    total += bd.getInt16(o, Endian.little);
  }
  final mean = total / (wav.frameCount * wav.channels);

  final rms = <double>[];
  var prev = 0.0;
  for (var f = 0; f < wav.frameCount; f += windowFrames) {
    final wEnd = math.min(f + windowFrames, wav.frameCount);
    var sum = 0.0;
    for (var o = start + f * frameBytes;
        o < start + wEnd * frameBytes;
        o += 2) {
      final x = bd.getInt16(o, Endian.little) - mean;
      final v = x - preEmphasis * prev;
      prev = x;
      sum += v * v;
    }
    rms.add(math.sqrt(sum / ((wEnd - f) * wav.channels)));
  }

  final sorted = List<double>.from(rms)..sort();
  final floor = sorted[sorted.length ~/ 10];
  var peak = 0.0;
  for (var w = 0; w + 5 <= rms.length; w++) {
    final m = (rms.sublist(w, w + 5)..sort())[2];
    if (m > peak) peak = m;
  }
  if (peak == 0) peak = sorted.last;
  if (peak == 0) return bytes;

  double db(double x) => 20 * math.log(x) / math.ln10;
  final limitDb = (floor > 0 ? db(floor) + marginDb : double.negativeInfinity)
      .clamp(db(peak) - maxBelowPeakDb, db(peak) - minBelowPeakDb);
  final limit = math.pow(10, limitDb / 20);

  final loud = [for (final r in rms) r >= limit];
  final half = sustainWindows ~/ 2;
  bool sustained(int w) {
    var n = 0;
    for (var i = math.max(0, w - half);
        i <= math.min(loud.length - 1, w + half);
        i++) {
      if (loud[i]) n++;
    }
    return n > half;
  }

  int? firstLoud;
  var lastLoud = 0;
  for (var w = 0; w < rms.length; w++) {
    if (loud[w] && sustained(w)) {
      firstLoud ??= w * windowFrames;
      lastLoud = math.min((w + 1) * windowFrames, wav.frameCount);
    }
  }
  if (firstLoud == null) return bytes;

  final from = math.max(0, firstLoud - wav.sampleRate * leadMs ~/ 1000);
  final to =
      math.min(wav.frameCount, lastLoud + wav.sampleRate * tailMs ~/ 1000);
  if (from == 0 && to == wav.frameCount) return bytes;

  final dataLen = (to - from) * frameBytes;
  final out = Uint8List(start + dataLen);
  out.setRange(0, start, bytes);
  out.setRange(start, start + dataLen, bytes, start + from * frameBytes);
  final ob = ByteData.sublistView(out);
  ob.setUint32(4, out.length - 8, Endian.little);
  ob.setUint32(start - 4, dataLen, Endian.little);
  return out;
}

// Wraps raw little-endian 16-bit PCM in a 44-byte WAV header. A trailing
// partial frame (a capture cut mid-sample) is dropped.
Uint8List encodeWavPcm16(Uint8List pcm,
    {required int sampleRate, required int channels}) {
  const bits = 16;
  final blockAlign = channels * bits ~/ 8;
  final dataLen = pcm.length - pcm.length % blockAlign;
  final out = ByteData(44 + dataLen);
  void tag(int offset, String s) {
    for (var i = 0; i < 4; i++) {
      out.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  out.setUint32(4, 36 + dataLen, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little);
  out.setUint16(22, channels, Endian.little);
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, sampleRate * blockAlign, Endian.little);
  out.setUint16(32, blockAlign, Endian.little);
  out.setUint16(34, bits, Endian.little);
  tag(36, 'data');
  out.setUint32(40, dataLen, Endian.little);
  final bytes = out.buffer.asUint8List();
  bytes.setRange(44, 44 + dataLen, pcm);
  return bytes;
}
