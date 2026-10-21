import 'dart:convert';
import 'dart:typed_data';

// Number of peaks stored in the attachment payload
const waveformBuckets = 100;

// Scales peaks so the loudest one is 1.0; silence stays flat
List<double> normalizePeaks(List<double> peaks) {
  var max = 0.0;
  for (final p in peaks) {
    if (p > max) max = p;
  }
  if (max < 0.005) return List.filled(peaks.length, 0);
  return [for (final p in peaks) (p / max).clamp(0.0, 1.0)];
}

String encodeWaveform(List<double> peaks) => base64Encode(Uint8List.fromList(
    [for (final p in peaks) (p.clamp(0.0, 1.0) * 255).round()]));

List<double>? decodeWaveform(String? encoded) {
  if (encoded == null || encoded.isEmpty) return null;
  try {
    final bytes = base64Decode(encoded);
    if (bytes.isEmpty) return null;
    return [for (final b in bytes) b / 255];
  } catch (_) {
    return null;
  }
}

// Resamples peaks to [count] bars, keeping the max of each covered range
List<double> resamplePeaks(List<double> peaks, int count) {
  if (count <= 0 || peaks.isEmpty) return const [];
  if (peaks.length == count) return peaks;
  final out = List<double>.filled(count, 0);
  for (var i = 0; i < count; i++) {
    final start = peaks.length * i ~/ count;
    var end = peaks.length * (i + 1) ~/ count;
    if (end <= start) end = start + 1;
    var max = 0.0;
    for (var j = start; j < end && j < peaks.length; j++) {
      if (peaks[j] > max) max = peaks[j];
    }
    out[i] = max;
  }
  return out;
}
