import 'dart:js_interop';
import 'dart:typed_data';

import 'audio_analysis.dart';
import 'wav_decoder.dart';
import 'waveform.dart';

@JS('AudioContext')
extension type _AudioContext._(JSObject _) implements JSObject {
  external factory _AudioContext();
  external JSPromise<_AudioBuffer> decodeAudioData(JSArrayBuffer data);
  external JSPromise<JSAny?> close();
}

extension type _AudioBuffer._(JSObject _) implements JSObject {
  external int get length;
  external int get numberOfChannels;
  external double get duration;
  external JSFloat32Array getChannelData(int channel);
}

AudioInfo? analyzeWav(Uint8List bytes) {
  final wav = WavPcm.parse(bytes);
  if (wav == null) return null;
  return AudioInfo(
    duration: wav.durationSeconds,
    peaks: normalizePeaks(wav.peaks(waveformBuckets)),
  );
}

// WAV first (no decode needed), then WebAudio for anything the browser can
// decode (mp3, m4a, ogg, ...).
Future<AudioInfo?> analyzeAudio(Uint8List bytes, String mimeType) async {
  try {
    final wav = analyzeWav(bytes);
    if (wav != null) return wav;
  } catch (_) {}

  _AudioContext? ctx;
  try {
    ctx = _AudioContext();
    // decodeAudioData detaches the buffer, so hand it a copy
    final copy = Uint8List.fromList(bytes);
    final decoded = await ctx
        .decodeAudioData(copy.buffer.toJS)
        .toDart
        .timeout(const Duration(seconds: 20));
    final frames = decoded.length;
    final channels = decoded.numberOfChannels;
    if (frames == 0) return null;
    final data = [
      for (var c = 0; c < channels; c++) decoded.getChannelData(c).toDart,
    ];
    final peaks = List<double>.filled(waveformBuckets, 0);
    for (var b = 0; b < waveformBuckets; b++) {
      final start = frames * b ~/ waveformBuckets;
      final end = frames * (b + 1) ~/ waveformBuckets;
      final span = end - start;
      if (span <= 0) continue;
      final stride = span > 4000 ? span ~/ 4000 : 1;
      var peak = 0.0;
      for (var f = start; f < end; f += stride) {
        for (final ch in data) {
          final v = ch[f].abs();
          if (v > peak) peak = v;
        }
      }
      peaks[b] = peak;
    }
    return AudioInfo(duration: decoded.duration, peaks: normalizePeaks(peaks));
  } catch (_) {
    return null;
  } finally {
    try {
      await ctx?.close().toDart;
    } catch (_) {}
  }
}
