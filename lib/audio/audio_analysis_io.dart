import 'dart:typed_data';

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

Future<AudioInfo?> analyzeAudio(Uint8List bytes, String mimeType) async {
  try {
    return analyzeWav(bytes);
  } catch (_) {
    return null;
  }
}
