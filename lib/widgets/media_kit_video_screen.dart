import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// Bare media_kit video view for a local file (Linux/Windows, where
// video_player has no desktop implementation). Plays with media_kit's built-in
// controls; the host provides the surrounding window chrome. The media_kit
// equivalent of VideoPlayerView, used by the separate desktop media window.
class MediaKitVideoView extends StatefulWidget {
  final File file;

  const MediaKitVideoView({super.key, required this.file});

  @override
  State<MediaKitVideoView> createState() => _MediaKitVideoViewState();
}

class _MediaKitVideoViewState extends State<MediaKitVideoView> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await _player.open(Media(widget.file.path));
      await _player.setPlaylistMode(PlaylistMode.loop);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not play this video');
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: Colors.white70)),
      );
    }
    return Video(controller: _controller);
  }
}

// In-app video player for Linux/Windows (video_player has no desktop support).
// Decrypts bytes → temp file → media_kit Video widget with built-in controls,
// a close button and Esc-to-close. Matches VideoPlayerScreen's chrome.
class MediaKitVideoScreen extends StatefulWidget {
  final Future<Uint8List?> bytesFuture;
  final String filename;

  const MediaKitVideoScreen({
    super.key,
    required this.bytesFuture,
    required this.filename,
  });

  @override
  State<MediaKitVideoScreen> createState() => _MediaKitVideoScreenState();
}

class _MediaKitVideoScreenState extends State<MediaKitVideoScreen> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  File? _file;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.bytesFuture;
      if (bytes == null) {
        if (mounted) setState(() => _error = 'Could not load video');
        return;
      }
      final file =
          File('${Directory.systemTemp.path}/manent_play_${widget.filename}');
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      _file = file;
      await _player.open(Media(file.path));
      await _player.setPlaylistMode(PlaylistMode.loop);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not play this video');
    }
  }

  @override
  void dispose() {
    _player.dispose();
    try {
      _file?.deleteSync();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: _error != null
                  ? Center(
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.white70)))
                  : Video(controller: _controller),
            ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 16,
              child: Semantics(
                label: 'Close video',
                button: true,
                child: GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(8),
                    child:
                        const Icon(Icons.close, color: Colors.white, size: 24),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
