import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

// Plays a local video file with play/pause + a scrub bar. No Scaffold/close —
// the host provides the surrounding chrome. Reused by the mobile full-screen
// route and the desktop image/video window.
class VideoPlayerView extends StatefulWidget {
  final File file;

  const VideoPlayerView({super.key, required this.file});

  @override
  State<VideoPlayerView> createState() => _VideoPlayerViewState();
}

class _VideoPlayerViewState extends State<VideoPlayerView> {
  VideoPlayerController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final controller = VideoPlayerController.file(widget.file);
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      controller
        ..setLooping(true)
        ..addListener(_tick)
        ..play();
      setState(() => _controller = controller);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not play this video');
    }
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    setState(() => c.value.isPlaying ? c.pause() : c.play());
  }

  @override
  void dispose() {
    _controller?.removeListener(_tick);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Stack(
      children: [
        Center(
          child: _error != null
              ? Text(_error!, style: const TextStyle(color: Colors.white70))
              : controller == null
                  ? const CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white54),
                    )
                  : AspectRatio(
                      aspectRatio: controller.value.aspectRatio == 0
                          ? 16 / 9
                          : controller.value.aspectRatio,
                      child: VideoPlayer(controller),
                    ),
        ),
        if (controller != null)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _togglePlay,
            ),
          ),
        if (controller != null && controller.value.isInitialized)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _controls(controller),
          ),
      ],
    );
  }

  Widget _controls(VideoPlayerController controller) {
    final value = controller.value;
    return Container(
      padding: EdgeInsets.fromLTRB(
          8, 24, 16, 8 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withValues(alpha: 0.6), Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          Semantics(
            label: value.isPlaying ? 'Pause' : 'Play',
            button: true,
            child: IconButton(
              icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white),
              onPressed: _togglePlay,
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: VideoProgressIndicator(
                controller,
                allowScrubbing: true,
                colors: const VideoProgressColors(
                  playedColor: Colors.white,
                  bufferedColor: Colors.white38,
                  backgroundColor: Colors.white24,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${_fmt(value.position)} / ${_fmt(value.duration)}',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

// Mobile full-screen player: decrypts bytes → temp file → VideoPlayerView,
// with a close button and Esc-to-close.
class VideoPlayerScreen extends StatefulWidget {
  final Future<Uint8List?> bytesFuture;
  final String filename;

  const VideoPlayerScreen({
    super.key,
    required this.bytesFuture,
    required this.filename,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
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
      setState(() => _file = file);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not play this video');
    }
  }

  @override
  void dispose() {
    try {
      _file?.deleteSync();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
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
                  : file == null
                      ? const Center(
                          child: CircularProgressIndicator(
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white54),
                          ),
                        )
                      : VideoPlayerView(file: file),
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
