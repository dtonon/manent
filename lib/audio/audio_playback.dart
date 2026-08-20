import 'package:flutter/foundation.dart';

// Platform factory: video_player (iOS/Android/macOS), media_kit
// (Linux/Windows) or an HTML audio element (web).
export 'audio_playback_io.dart' if (dart.library.html) 'audio_playback_web.dart'
    show createAudioPlayback;

// One loaded audio file. Position is reported as the backend sees it; the UI
// interpolates between reports for a smooth cursor.
abstract class AudioPlayback {
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration?> duration = ValueNotifier(null);
  final ValueNotifier<bool> isPlaying = ValueNotifier(false);
  final ValueNotifier<String?> error = ValueNotifier(null);

  Future<void> load(Uint8List bytes, String mimeType, String filename);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  @mustCallSuper
  Future<void> dispose() async {
    position.dispose();
    duration.dispose();
    isPlaying.dispose();
    error.dispose();
  }
}
