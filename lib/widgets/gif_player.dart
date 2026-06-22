import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

// True if bytes start with the GIF magic number ("GIF8")
bool isGifBytes(Uint8List b) =>
    b.length >= 4 &&
    b[0] == 0x47 &&
    b[1] == 0x49 &&
    b[2] == 0x46 &&
    b[3] == 0x38;

class _Frame {
  final ui.Image image;
  final Duration duration;
  const _Frame(this.image, this.duration);
}

// Animated GIF viewer with correct-speed playback, play/pause and a timeline
// scrubber. Uses dart:ui to decode frames so per-frame delays are honored and
// near-zero delays are clamped (browsers do the same) instead of running at
// full speed like Image.memory does. Falls back to a static image for
// single-frame / non-animated input.
class GifPlayer extends StatefulWidget {
  final Uint8List bytes;
  final String semanticLabel;
  final double minScale;
  final double maxScale;

  const GifPlayer({
    super.key,
    required this.bytes,
    required this.semanticLabel,
    this.minScale = 0.5,
    this.maxScale = 10.0,
  });

  @override
  State<GifPlayer> createState() => _GifPlayerState();
}

class _GifPlayerState extends State<GifPlayer> {
  final _transformController = TransformationController();
  List<_Frame>? _frames;
  int _index = 0;
  bool _playing = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.bytes);
      final frames = <_Frame>[];
      for (var i = 0; i < codec.frameCount; i++) {
        final f = await codec.getNextFrame();
        // Browser-style clamp: near-zero delays play at 100ms, not full speed
        final d = f.duration < const Duration(milliseconds: 20)
            ? const Duration(milliseconds: 100)
            : f.duration;
        frames.add(_Frame(f.image, d));
      }
      codec.dispose();
      if (!mounted) {
        for (final fr in frames) {
          fr.image.dispose();
        }
        return;
      }
      setState(() => _frames = frames);
      if (frames.length > 1) _scheduleNext();
    } catch (_) {
      if (mounted) setState(() => _frames = []);
    }
  }

  void _scheduleNext() {
    _timer?.cancel();
    final frames = _frames;
    if (frames == null || frames.length < 2 || !_playing) return;
    _timer = Timer(frames[_index].duration, () {
      if (!mounted || !_playing) return;
      setState(() => _index = (_index + 1) % frames.length);
      _scheduleNext();
    });
  }

  void _togglePlay() {
    setState(() => _playing = !_playing);
    if (_playing) {
      _scheduleNext();
    } else {
      _timer?.cancel();
    }
  }

  void _seek(int index) {
    _timer?.cancel();
    final count = _frames?.length ?? 1;
    setState(() {
      _playing = false;
      _index = index.clamp(0, count - 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _transformController.dispose();
    for (final f in _frames ?? const <_Frame>[]) {
      f.image.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frames = _frames;
    if (frames == null) {
      return const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Colors.white54),
        ),
      );
    }
    if (frames.isEmpty) {
      // Decode failed — fall back to Flutter's own decoder
      return Center(
        child: Image.memory(
          widget.bytes,
          fit: BoxFit.contain,
          semanticLabel: widget.semanticLabel,
        ),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: InteractiveViewer(
            transformationController: _transformController,
            minScale: widget.minScale,
            maxScale: widget.maxScale,
            child: Center(
              child: Semantics(
                label: widget.semanticLabel,
                image: true,
                child: RawImage(
                  image: frames[_index].image,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        ),
        if (frames.length > 1)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _controls(frames.length),
          ),
      ],
    );
  }

  Widget _controls(int frameCount) {
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
            label: _playing ? 'Pause' : 'Play',
            button: true,
            child: IconButton(
              icon: Icon(_playing ? Icons.pause : Icons.play_arrow,
                  color: Colors.white),
              onPressed: _togglePlay,
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: const SliderThemeData(
                trackHeight: 2,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                min: 0,
                max: (frameCount - 1).toDouble(),
                divisions: frameCount - 1,
                value: _index.toDouble().clamp(0, (frameCount - 1).toDouble()),
                activeColor: Colors.white,
                inactiveColor: Colors.white30,
                label: '${_index + 1}',
                onChanged: (v) => _seek(v.round()),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${_index + 1}/$frameCount',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
