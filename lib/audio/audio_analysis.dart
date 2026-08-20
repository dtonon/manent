// Extracts duration and a peak waveform from raw audio bytes.
// WAV is parsed in pure Dart everywhere; web additionally decodes any
// browser-supported format through WebAudio. Returns null when the format
// cannot be decoded on this platform.
export 'audio_analysis_io.dart'
    if (dart.library.html) 'audio_analysis_web.dart';

class AudioInfo {
  final double duration; // seconds
  final List<double> peaks; // normalized 0..1, waveformBuckets long

  const AudioInfo({required this.duration, required this.peaks});
}
