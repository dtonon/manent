import 'package:flutter/foundation.dart';

import '../notes/note_attachment.dart';
import '../notes/note_cache.dart';
import 'audio_playback.dart';

// One active audio player app-wide, keyed by attachment sha256. Starting a
// different note stops the previous one; playback survives the note card
// scrolling out of view.
class AudioPlayerService {
  AudioPlayerService._();
  static final instance = AudioPlayerService._();

  // sha256 of the loaded attachment, null when nothing is loaded
  final ValueNotifier<String?> activeSha = ValueNotifier(null);
  // sha256 currently being loaded (bytes fetch + player init)
  final ValueNotifier<String?> loadingSha = ValueNotifier(null);

  AudioPlayback? _playback;
  int _generation = 0;

  AudioPlayback? playbackFor(String sha256) =>
      activeSha.value == sha256 ? _playback : null;

  // Loads the attachment (replacing any active player) and returns its
  // playback, or null when the bytes are unavailable.
  Future<AudioPlayback?> acquire(NoteAttachment attachment) async {
    final existing = playbackFor(attachment.sha256);
    if (existing != null) return existing;

    final gen = ++_generation;
    await stop();
    loadingSha.value = attachment.sha256;
    try {
      final bytes = await NoteCache.instance.getFileBytes(attachment);
      if (gen != _generation) return null;
      if (bytes == null) return null;
      final playback = createAudioPlayback();
      await playback.load(bytes, attachment.mimeType, attachment.filename);
      if (gen != _generation) {
        await playback.dispose();
        return null;
      }
      _playback = playback;
      activeSha.value = attachment.sha256;
      return playback;
    } finally {
      if (gen == _generation) loadingSha.value = null;
    }
  }

  Future<void> stop() async {
    final playback = _playback;
    _playback = null;
    // Listeners detach on this change, before the notifiers are disposed
    activeSha.value = null;
    await playback?.dispose();
  }
}
