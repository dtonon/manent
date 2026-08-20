import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import 'audio_playback.dart';

AudioPlayback createAudioPlayback() =>
    defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.windows
        ? _MediaKitPlayback()
        : _VideoPlayerPlayback();

// Both native backends need a path, so the decrypted bytes go to a temp file
// that is removed on dispose.
Future<File> _writeTemp(Uint8List bytes, String filename) async {
  final ext = p.extension(filename);
  final file = File(p.join(Directory.systemTemp.path,
      'manent_audio_${DateTime.now().microsecondsSinceEpoch}$ext'));
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

Future<void> _deleteTemp(File? file) async {
  if (file == null) return;
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

class _VideoPlayerPlayback extends AudioPlayback {
  VideoPlayerController? _controller;
  File? _file;
  bool _disposed = false;
  bool _handlingCompletion = false;

  @override
  Future<void> load(Uint8List bytes, String mimeType, String filename) async {
    try {
      _file = await _writeTemp(bytes, filename);
      final c = VideoPlayerController.file(_file!);
      await c.initialize();
      if (_disposed) {
        await c.dispose();
        return;
      }
      _controller = c;
      duration.value = c.value.duration;
      c.addListener(_onChange);
    } catch (_) {
      if (!_disposed) error.value = 'Could not play this audio';
    }
  }

  void _onChange() {
    final c = _controller;
    if (c == null || _disposed) return;
    final v = c.value;
    if (v.hasError) {
      error.value = 'Could not play this audio';
      return;
    }
    if (v.duration > Duration.zero) duration.value = v.duration;
    if (v.isCompleted && !_handlingCompletion) {
      _handlingCompletion = true;
      isPlaying.value = false;
      position.value = Duration.zero;
      c.seekTo(Duration.zero).whenComplete(() => _handlingCompletion = false);
      return;
    }
    if (_handlingCompletion) return;
    position.value = v.position;
    isPlaying.value = v.isPlaying;
  }

  @override
  Future<void> play() async => _controller?.play();

  @override
  Future<void> pause() async => _controller?.pause();

  @override
  Future<void> seek(Duration pos) async {
    final c = _controller;
    if (c == null) return;
    position.value = pos;
    await c.seekTo(pos);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _controller?.removeListener(_onChange);
    await _controller?.dispose();
    _controller = null;
    await _deleteTemp(_file);
    await super.dispose();
  }
}

class _MediaKitPlayback extends AudioPlayback {
  static bool _initialized = false;

  Player? _player;
  File? _file;
  bool _disposed = false;
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  Future<void> load(Uint8List bytes, String mimeType, String filename) async {
    try {
      if (!_initialized) {
        MediaKit.ensureInitialized();
        _initialized = true;
      }
      _file = await _writeTemp(bytes, filename);
      final player = Player();
      _player = player;
      _subs.addAll([
        player.stream.position.listen((d) {
          if (!_disposed) position.value = d;
        }),
        player.stream.duration.listen((d) {
          if (!_disposed && d > Duration.zero) duration.value = d;
        }),
        player.stream.playing.listen((v) {
          if (!_disposed) isPlaying.value = v;
        }),
        player.stream.completed.listen((done) async {
          if (!done || _disposed) return;
          isPlaying.value = false;
          position.value = Duration.zero;
          await player.pause();
          await player.seek(Duration.zero);
        }),
        player.stream.error.listen((e) {
          if (!_disposed && e.isNotEmpty) {
            error.value = 'Could not play this audio';
          }
        }),
      ]);
      await player.setPlaylistMode(PlaylistMode.none);
      await player.open(Media(_file!.path), play: false);
      if (_disposed) await player.dispose();
    } catch (_) {
      if (!_disposed) error.value = 'Could not play this audio';
    }
  }

  @override
  Future<void> play() async => _player?.play();

  @override
  Future<void> pause() async => _player?.pause();

  @override
  Future<void> seek(Duration pos) async {
    final player = _player;
    if (player == null) return;
    position.value = pos;
    await player.seek(pos);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _player?.dispose();
    _player = null;
    await _deleteTemp(_file);
    await super.dispose();
  }
}
