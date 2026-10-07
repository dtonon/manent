import 'dart:async';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';

import 'audio_playback.dart';

AudioPlayback createAudioPlayback() => _HtmlAudioPlayback();

// Hidden <audio> element on a blob URL of the decrypted bytes
class _HtmlAudioPlayback extends AudioPlayback {
  html.AudioElement? _audio;
  String? _url;
  bool _disposed = false;
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  Future<void> load(Uint8List bytes, String mimeType, String filename) async {
    try {
      final blob = html.Blob([bytes], mimeType);
      _url = html.Url.createObjectUrlFromBlob(blob);
      final audio = html.AudioElement()
        ..src = _url!
        ..preload = 'metadata';
      _audio = audio;
      _subs.addAll([
        audio.onLoadedMetadata.listen((_) => _readDuration()),
        audio.onDurationChange.listen((_) => _readDuration()),
        audio.onTimeUpdate.listen((_) {
          if (_disposed) return;
          position.value = _toDuration(audio.currentTime);
        }),
        audio.onPlay.listen((_) {
          if (!_disposed) isPlaying.value = true;
        }),
        audio.onPause.listen((_) {
          if (!_disposed) isPlaying.value = false;
        }),
        audio.onEnded.listen((_) {
          if (_disposed) return;
          isPlaying.value = false;
          position.value = Duration.zero;
          audio.currentTime = 0;
        }),
        audio.onError.listen((_) {
          if (!_disposed) error.value = 'Could not play this audio';
        }),
      ]);
      audio.load();
    } catch (_) {
      if (!_disposed) error.value = 'Could not play this audio';
    }
  }

  void _readDuration() {
    final audio = _audio;
    if (audio == null || _disposed) return;
    final d = audio.duration;
    if (d.isFinite && d > 0) duration.value = _toDuration(d);
  }

  Duration _toDuration(num seconds) =>
      Duration(milliseconds: (seconds * 1000).round());

  @override
  Future<void> play() async {
    try {
      await _audio?.play();
    } catch (_) {
      if (!_disposed) error.value = 'Could not play this audio';
    }
  }

  @override
  Future<void> pause() async => _audio?.pause();

  @override
  Future<void> seek(Duration pos) async {
    final audio = _audio;
    if (audio == null) return;
    position.value = pos;
    audio.currentTime = pos.inMilliseconds / 1000;
  }

  @override
  Future<void> setSpeed(double speed) async => _audio?.playbackRate = speed;

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _audio?.pause();
    _audio?.src = '';
    _audio = null;
    final url = _url;
    if (url != null) html.Url.revokeObjectUrl(url);
    await super.dispose();
  }
}
