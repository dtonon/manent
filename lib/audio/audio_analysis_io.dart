import 'dart:typed_data';

import 'package:audio_decode/audio_decode.dart' as ad;
import 'package:flutter/foundation.dart' show compute;

import 'audio_analysis.dart';
import 'wav_decoder.dart';
import 'waveform.dart';

AudioInfo? analyzeWav(Uint8List bytes) {
  final wav = WavPcm.parse(bytes);
  if (wav == null) return null;
  return AudioInfo(
    duration: wav.durationSeconds,
    peaks: normalizePeaks(wav.peaks(waveformBuckets)),
  );
}

// WAV is read in place; mp3 and Ogg Vorbis are decoded to PCM in a
// background isolate, since the decoded audio can be large.
Future<AudioInfo?> analyzeAudio(Uint8List bytes, String mimeType) async {
  try {
    final wav = analyzeWav(bytes);
    if (wav != null) return wav;
  } catch (_) {}
  try {
    if (ad.detectFormat(bytes) == ad.AudioFormat.unknown) return null;
    return await compute(_decodeAndAnalyze, bytes);
  } catch (_) {
    return null;
  }
}

AudioInfo? _decodeAndAnalyze(Uint8List bytes) {
  final pcm = ad.decodeAudio(bytes);
  final channels = pcm.channels;
  final frames = pcm.frameCount;
  if (frames == 0 || channels == 0) return null;
  final samples = pcm.samples;
  final peaks = List<double>.filled(waveformBuckets, 0);
  for (var b = 0; b < waveformBuckets; b++) {
    final start = frames * b ~/ waveformBuckets;
    final end = frames * (b + 1) ~/ waveformBuckets;
    final span = end - start;
    if (span <= 0) continue;
    final stride = span > 4000 ? span ~/ 4000 : 1;
    var peak = 0;
    for (var f = start; f < end; f += stride) {
      final base = f * channels;
      for (var c = 0; c < channels; c++) {
        final v = samples[base + c].abs();
        if (v > peak) peak = v;
      }
    }
    peaks[b] = peak / 32768;
  }
  return AudioInfo(
    duration: pcm.duration.inMilliseconds / 1000,
    peaks: normalizePeaks(peaks),
  );
}
