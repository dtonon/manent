import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../audio/audio_analysis.dart';
import '../audio/audio_playback.dart';
import '../audio/audio_player_service.dart';
import '../audio/waveform.dart';
import '../notes/note_attachment.dart';
import '../notes/note_cache.dart';
import '../theme.dart';

// Inline audio player strip: play/pause button, peak waveform with a
// draggable cursor, and the duration or elapsed time.
class AudioNotePlayer extends StatefulWidget {
  final NoteAttachment attachment;

  const AudioNotePlayer({super.key, required this.attachment});

  @override
  State<AudioNotePlayer> createState() => _AudioNotePlayerState();
}

class _AudioNotePlayerState extends State<AudioNotePlayer>
    with SingleTickerProviderStateMixin {
  // sha256 -> analysis result (null = tried and failed)
  static final Map<String, AudioInfo?> _analysisCache = {};

  final _service = AudioPlayerService.instance;

  List<double>? _peaks;
  double? _durationSec;

  AudioPlayback? _playback;
  bool _playing = false;
  Duration _reportedPos = Duration.zero;
  DateTime _reportedAt = DateTime.now();
  Duration _shownPos = Duration.zero;
  late final Ticker _ticker;

  bool _dragging = false;
  double _dragFraction = 0;

  String get _sha => widget.attachment.sha256;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _peaks = decodeWaveform(widget.attachment.waveform);
    _durationSec = widget.attachment.duration;
    if (_peaks == null || _durationSec == null) _analyze();
    _service.activeSha.addListener(_onActiveChanged);
    _service.loadingSha.addListener(_rebuild);
    _onActiveChanged();
  }

  @override
  void didUpdateWidget(AudioNotePlayer old) {
    super.didUpdateWidget(old);
    if (old.attachment.sha256 != _sha) {
      _detach();
      _peaks = decodeWaveform(widget.attachment.waveform);
      _durationSec = widget.attachment.duration;
      if (_peaks == null || _durationSec == null) _analyze();
      _onActiveChanged();
    }
  }

  @override
  void dispose() {
    _service.activeSha.removeListener(_onActiveChanged);
    _service.loadingSha.removeListener(_rebuild);
    _detach();
    _ticker.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _analyze() async {
    final sha = _sha;
    if (_analysisCache.containsKey(sha)) {
      _applyAnalysis(_analysisCache[sha]);
      return;
    }
    final bytes = await NoteCache.instance.getFileBytes(widget.attachment);
    if (bytes == null) return;
    final info = await analyzeAudio(bytes, widget.attachment.mimeType);
    _analysisCache[sha] = info;
    if (mounted && sha == _sha) _applyAnalysis(info);
  }

  void _applyAnalysis(AudioInfo? info) {
    if (info == null) return;
    setState(() {
      _peaks ??= info.peaks;
      _durationSec ??= info.duration;
    });
  }

  // --- playback binding ---

  void _onActiveChanged() {
    final pb = _service.playbackFor(_sha);
    if (pb == _playback) return;
    _detach();
    if (pb != null) _attach(pb);
    _rebuild();
  }

  void _attach(AudioPlayback pb) {
    _playback = pb;
    pb.position.addListener(_onPosition);
    pb.isPlaying.addListener(_onPlaying);
    pb.duration.addListener(_onDuration);
    pb.error.addListener(_onError);
    _onDuration();
    _onPosition();
    _onPlaying();
  }

  void _detach() {
    final pb = _playback;
    if (pb != null) {
      pb.position.removeListener(_onPosition);
      pb.isPlaying.removeListener(_onPlaying);
      pb.duration.removeListener(_onDuration);
      pb.error.removeListener(_onError);
    }
    _playback = null;
    _playing = false;
    _reportedPos = Duration.zero;
    _shownPos = Duration.zero;
    if (_ticker.isActive) _ticker.stop();
  }

  void _onPosition() {
    final pb = _playback;
    if (pb == null) return;
    _reportedPos = pb.position.value;
    _reportedAt = DateTime.now();
    if (!_dragging) setState(() => _shownPos = _reportedPos);
  }

  void _onPlaying() {
    final pb = _playback;
    if (pb == null) return;
    _playing = pb.isPlaying.value;
    _reportedAt = DateTime.now();
    if (_playing && !_ticker.isActive) _ticker.start();
    if (!_playing && _ticker.isActive) _ticker.stop();
    _rebuild();
  }

  void _onDuration() {
    final d = _playback?.duration.value;
    if (d != null && d > Duration.zero) {
      setState(() => _durationSec = d.inMilliseconds / 1000);
    }
  }

  void _onError() {
    final msg = _playback?.error.value;
    if (msg == null || !mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(msg)));
  }

  // Interpolates between backend position reports while playing
  void _onTick(Duration _) {
    if (!_playing || _dragging) return;
    final elapsed = DateTime.now().difference(_reportedAt);
    var pos = _reportedPos + elapsed;
    final total = _totalDuration;
    if (total != null && pos > total) pos = total;
    setState(() => _shownPos = pos);
  }

  Duration? get _totalDuration {
    final d = _durationSec;
    if (d == null || d <= 0) return null;
    return Duration(milliseconds: (d * 1000).round());
  }

  // --- actions ---

  bool get _isLoading => _service.loadingSha.value == _sha;

  Future<AudioPlayback?> _ensurePlayback() async {
    final existing = _playback;
    if (existing != null) return existing;
    final pb = await _service.acquire(widget.attachment);
    if (!mounted) return null;
    if (pb != null && pb.error.value != null) {
      _onError();
      return null;
    }
    return pb;
  }

  Future<void> _togglePlay() async {
    final pb = _playback;
    if (pb != null) {
      if (pb.isPlaying.value) {
        await pb.pause();
      } else {
        await pb.play();
      }
      return;
    }
    if (_isLoading) return;
    final loaded = await _ensurePlayback();
    await loaded?.play();
  }

  Future<void> _seekFraction(double fraction, {required bool thenPlay}) async {
    final pb = await _ensurePlayback();
    if (pb == null) return;
    final total = pb.duration.value ?? _totalDuration;
    if (total == null) return;
    await pb.seek(total * fraction.clamp(0.0, 1.0));
    if (thenPlay && !pb.isPlaying.value) await pb.play();
  }

  Future<void> _seekBy(Duration delta) async {
    final total = _totalDuration;
    if (total == null || total == Duration.zero) return;
    final target =
        (_shownPos + delta).inMilliseconds.clamp(0, total.inMilliseconds);
    await _seekFraction(target / total.inMilliseconds, thenPlay: false);
  }

  void _onDragStart(double fraction) {
    setState(() {
      _dragging = true;
      _dragFraction = fraction.clamp(0.0, 1.0);
    });
  }

  void _onDragUpdate(double fraction) {
    setState(() => _dragFraction = fraction.clamp(0.0, 1.0));
  }

  Future<void> _onDragEnd() async {
    final fraction = _dragFraction;
    setState(() => _dragging = false);
    await _seekFraction(fraction, thenPlay: false);
  }

  // --- formatting ---

  static String _fmt(Duration d) {
    final s = d.inSeconds;
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r < 10 ? '0' : ''}$r';
  }

  double get _progress {
    if (_dragging) return _dragFraction;
    final total = _totalDuration;
    if (total == null || total == Duration.zero) return 0;
    return (_shownPos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
  }

  String get _timeText {
    final total = _totalDuration;
    if (_dragging && total != null) return _fmt(total * _dragFraction);
    if (_playback != null) return _fmt(_shownPos);
    return total == null ? '–:––' : _fmt(total);
  }

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;
    final total = _totalDuration;
    final totalText = total == null ? 'unknown length' : _fmt(total);
    final current =
        _dragging && total != null ? total * _dragFraction : _shownPos;

    return ColoredBox(
      color: Color.lerp(mc.card, mc.cardDim, 0.6)!,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            _PlayButton(
              playing: _playing,
              loading: _isLoading,
              onTap: _togglePlay,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                slider: true,
                label: 'Playback position',
                value: '${_fmt(current)} of $totalText',
                onIncrease: () => _seekBy(const Duration(seconds: 5)),
                onDecrease: () => _seekBy(const Duration(seconds: -5)),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    double fraction(Offset local) =>
                        width <= 0 ? 0 : local.dx / width;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (d) => _seekFraction(fraction(d.localPosition),
                          thenPlay: true),
                      onHorizontalDragStart: (d) =>
                          _onDragStart(fraction(d.localPosition)),
                      onHorizontalDragUpdate: (d) =>
                          _onDragUpdate(fraction(d.localPosition)),
                      onHorizontalDragEnd: (_) => _onDragEnd(),
                      onHorizontalDragCancel: () =>
                          setState(() => _dragging = false),
                      child: SizedBox(
                        height: 44,
                        child: CustomPaint(
                          painter: _WaveformPainter(
                            peaks: _peaks,
                            progress: _progress,
                            playedColor: mc.primaryText,
                            unplayedColor: mc.faintText,
                            showKnob: _dragging,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 36),
              child: Text(
                _timeText,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 13,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontWeight: _dragging ? FontWeight.w600 : FontWeight.normal,
                  color: _dragging ? mc.primaryText : mc.secondaryText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final bool playing;
  final bool loading;
  final VoidCallback onTap;

  const _PlayButton({
    required this.playing,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: playing ? 'Pause' : 'Play',
      child: Material(
        color: const Color(0xFF333333),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 26,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  static const _barWidth = 3.0;
  static const _gap = 2.0;
  static const _flatHeight = 10.0;

  final List<double>? peaks;
  final double progress;
  final Color playedColor;
  final Color unplayedColor;
  final bool showKnob;

  const _WaveformPainter({
    required this.peaks,
    required this.progress,
    required this.playedColor,
    required this.unplayedColor,
    required this.showKnob,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final count =
        math.max(1, ((size.width + _gap) / (_barWidth + _gap)).floor());
    final bars = peaks == null ? null : resamplePeaks(peaks!, count);
    final maxHeight = size.height - 4;
    final midY = size.height / 2;
    final played = Paint()..color = playedColor;
    final unplayed = Paint()..color = unplayedColor;

    for (var i = 0; i < count; i++) {
      final peak = bars == null ? null : bars[i];
      final h = peak == null ? _flatHeight : math.max(3.0, peak * maxHeight);
      final x = i * (_barWidth + _gap);
      final paint = (i + 0.5) / count <= progress ? played : unplayed;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, midY - h / 2, _barWidth, h),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }

    final cx = (progress * size.width).clamp(1.0, size.width - 1.0);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - 1, 2, 2, size.height - 4),
        const Radius.circular(1),
      ),
      played,
    );
    if (showKnob) {
      canvas.drawCircle(Offset(cx, 2), 5, played);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.peaks != peaks ||
      old.progress != progress ||
      old.playedColor != playedColor ||
      old.unplayedColor != unplayedColor ||
      old.showKnob != showKnob;
}
