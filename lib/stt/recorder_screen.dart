import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../audio/wav_decoder.dart';
import '../theme.dart';

typedef Recording = ({Uint8List bytes, String name});

Future<Recording?> showRecorderScreen(BuildContext context) {
  return Navigator.of(context).push<Recording>(
    PageRouteBuilder<Recording>(
      pageBuilder: (_, __, ___) => const _RecorderScreen(),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 150),
    ),
  );
}

class _RecorderScreen extends StatefulWidget {
  const _RecorderScreen();

  @override
  State<_RecorderScreen> createState() => _RecorderScreenState();
}

class _RecorderScreenState extends State<_RecorderScreen>
    with WidgetsBindingObserver {
  final _recorder = AudioRecorder();
  Timer? _ticker;
  StreamSubscription<Amplitude>? _ampSub;
  String? _path;
  String? _error;
  bool _recording = false;
  bool _stopping = false;
  bool _paused = false;
  bool _confirming = false;
  int _elapsedSeconds = 0;
  double _level = 0;
  double? _peakDb;
  double? _lastRawDb;
  DateTime? _lastChange;
  double _sampleIntervalMs = 50;

  // Below this a mis-tap on the mic button should be cheap to back out of
  static const _discardConfirmAfter = 3;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  // Backgrounding mutes the mic while the file keeps growing, so save what
  // was captured instead of recording silence
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused) return;
    // Close the discard dialog so the pop below leaves the recorder route
    if (_confirming) Navigator.pop(context);
    // A paused recording captures nothing, so there is nothing to protect
    if (_recording && !_paused) _stop();
  }

  Future<void> _start() async {
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) {
          setState(() => _error = 'Microphone permission denied.');
        }
        return;
      }
      final tmp = await getTemporaryDirectory();
      final dir = Directory(p.join(tmp.path, 'manent_stt'));
      await dir.create(recursive: true);
      // Sweep plaintext audio left behind by a previous crash
      for (final f in dir.listSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
      _path =
          p.join(dir.path, 'rec-${DateTime.now().millisecondsSinceEpoch}.wav');
      await _startRecorder(_path!);
      // Auto-lock would mute the mic mid-recording; a wakelock failure must
      // never affect the recording itself
      unawaited(WakelockPlus.enable().catchError((_) {}));
      _ampSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 50))
          .listen((a) {
        if (_paused) return;
        _trackSampleInterval(a.current);
        if (mounted) setState(() => _level = _normalize(a.current));
      }, onError: (_) {});
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && !_paused) setState(() => _elapsedSeconds++);
      });
      if (mounted) setState(() => _recording = true);
      // The app may have gone to the background while start was still running
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) {
        _stop();
      }
    } catch (e) {
      final hint = !kIsWeb && Platform.isLinux
          ? ' On Linux, recording requires parecord (pulseaudio-utils) '
              'and ffmpeg.'
          : '';
      if (mounted) {
        setState(() => _error = 'Could not start recording: $e$hint');
      }
    }
  }

  // Phone mics report speech ~20 dB hotter than laptop mics (measured: peaks
  // around -15 dBFS vs -35, room noise near -50 vs -60)
  static final bool _isPhone =
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  static final double _floorDb = _isPhone ? -50 : -58;
  static final double _minPeakDb = _isPhone ? -22 : -33;

  // Fixed silence floor; the top of the scale starts at a typical speech peak
  // and only grows when louder peaks arrive, decaying ~1 dB/s back toward it
  double _normalize(double db) {
    db = db.clamp(-60.0, 0.0);
    final peak = _peakDb ?? _minPeakDb;
    _peakDb = db > peak ? db : (peak - 0.05).clamp(_minPeakDb, 0.0);
    return ((db - _floorDb) / (_peakDb! - _floorDb)).clamp(0.0, 1.0);
  }

  // Android recomputes the level only every ~250 ms and repeats it between
  // polls; tracking how often it actually changes lets the easing span the gap
  void _trackSampleInterval(double db) {
    final now = DateTime.now();
    if (db == _lastRawDb) return;
    if (_lastChange != null) {
      final dt = now.difference(_lastChange!).inMilliseconds.toDouble();
      _sampleIntervalMs =
          (_sampleIntervalMs * 0.7 + dt * 0.3).clamp(50.0, 400.0);
    }
    _lastRawDb = db;
    _lastChange = now;
  }

  // Android meters one value per read block, and the plugin sizes the block at
  // twice the device minimum (~250 ms on some phones). Smaller blocks refresh
  // the level faster but are rejected below the minimum, which Dart cannot
  // query, so probe from small to default and remember what worked
  static const _androidBlockLadder = [3200, 4800];
  static bool _androidProbed = false;
  static int? _androidBlockSize;

  Future<void> _startRecorder(String path) async {
    // 16 kHz mono WAV is what whisper.cpp expects; no transcoding needed
    RecordConfig config([int? blockSize]) => RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          streamBufferSize: blockSize,
        );

    if (kIsWeb || !Platform.isAndroid) {
      await _recorder.start(config(), path: path);
      return;
    }
    final sizes = _androidProbed
        ? [_androidBlockSize, null]
        : [..._androidBlockLadder, null];
    for (final size in sizes) {
      await _recorder.start(config(size), path: path);
      // A rejected block size fails inside the record thread before start
      // returns, leaving the recorder stopped
      if (size == null || await _recorder.isRecording()) {
        _androidProbed = true;
        _androidBlockSize = size;
        return;
      }
    }
  }

  Future<void> _togglePause() async {
    if (!_recording || _stopping || _confirming) return;
    try {
      if (_paused) {
        await _recorder.resume();
      } else {
        await _recorder.pause();
      }
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _paused = !_paused;
      if (_paused) _level = 0;
    });
  }

  Future<void> _stop() async {
    if (_stopping || !_recording) return;
    setState(() => _stopping = true);
    _ticker?.cancel();
    await _ampSub?.cancel();
    try {
      // A stopped parecord ignores the kill until it is continued
      if (_paused) await _recorder.resume();
      final path = await _recorder.stop();
      if (path == null) throw Exception('no file produced');
      final file = File(path);
      // Raw mic input is quiet; bring the peak up to a normal level
      final bytes = normalizeWavInPlace(await file.readAsBytes());
      try {
        await file.delete();
      } catch (_) {}
      if (!mounted) return;
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final name = 'voice-${now.year}${two(now.month)}${two(now.day)}'
          '-${two(now.hour)}${two(now.minute)}${two(now.second)}.wav';
      Navigator.pop(context, (bytes: bytes, name: name));
    } catch (e) {
      // The screen stays open on the error, so dispose will not release it
      _releaseWakelock();
      if (mounted) {
        setState(() {
          _stopping = false;
          _recording = false;
          _error = 'Recording failed: $e';
        });
      }
    }
  }

  // The recording keeps running underneath, so Keep loses nothing
  Future<bool> _confirmDiscard() async {
    _confirming = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
              Navigator.pop(ctx, true),
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): () =>
              Navigator.pop(ctx, true),
        },
        child: Focus(
          autofocus: true,
          child: AlertDialog(
            title: const Text('Discard recording?'),
            content: const Text('The audio recorded so far will be lost.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep recording'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: TextButton.styleFrom(foregroundColor: accent),
                child: const Text('Discard'),
              ),
            ],
          ),
        ),
      ),
    );
    _confirming = false;
    return confirmed == true;
  }

  Future<void> _cancel() async {
    if (_stopping || _confirming) return;
    if (_recording && _elapsedSeconds >= _discardConfirmAfter) {
      if (!await _confirmDiscard() || _stopping || !mounted) return;
    }
    _ticker?.cancel();
    await _ampSub?.cancel();
    try {
      await _recorder.stop();
    } catch (_) {}
    if (_path != null) {
      try {
        await File(_path!).delete();
      } catch (_) {}
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _ampSub?.cancel();
    _releaseWakelock();
    _recorder.dispose();
    super.dispose();
  }

  void _releaseWakelock() {
    unawaited(WakelockPlus.disable().catchError((_) {}));
  }

  String get _elapsedLabel {
    final m = (_elapsedSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        const SingleActivator(LogicalKeyboardKey.enter): _stop,
        const SingleActivator(LogicalKeyboardKey.space): _togglePause,
      },
      child: Focus(
        autofocus: true,
        child: PopScope(
          canPop: false,
          // System back discards, so the temp file is always cleaned up
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _cancel();
          },
          child: Scaffold(
            backgroundColor: mc.surface,
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: _error != null ? _buildError(mc) : _buildRecorder(mc),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildError(ManentColors mc) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic_off, size: 48, color: mc.iconMuted),
            const SizedBox(height: 16),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: mc.primaryText),
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecorder(ManentColors mc) {
    return Column(
      children: [
        const Spacer(flex: 3),
        _LevelCircle(
          level: _recording ? _level : 0,
          smoothingMs: _sampleIntervalMs,
          busy: _stopping,
        ),
        const SizedBox(height: 40),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _paused
                  ? Icons.radio_button_unchecked
                  : Icons.fiber_manual_record,
              size: 14,
              color: _recording && !_paused ? accent : mc.iconMuted,
            ),
            const SizedBox(width: 10),
            ExcludeSemantics(
              child: Text(
                _elapsedLabel,
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w300,
                  color: mc.primaryText,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        SizedBox(
          height: 24,
          child: _paused
              ? Semantics(
                  liveRegion: true,
                  child: Text(
                    'Paused',
                    style: TextStyle(fontSize: 14, color: mc.secondaryText),
                  ),
                )
              : null,
        ),
        const Spacer(flex: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _RoundAction(
              label: 'Cancel',
              semanticsLabel: 'Discard recording',
              icon: Icons.close,
              background: mc.cardDim,
              foreground: mc.primaryText,
              onPressed: _stopping ? null : _cancel,
            ),
            const SizedBox(width: 40),
            _RoundAction(
              label: _paused ? 'Resume' : 'Pause',
              semanticsLabel: _paused ? 'Resume recording' : 'Pause recording',
              icon: _paused ? Icons.fiber_manual_record : Icons.pause,
              background: mc.strongButtonBg,
              foreground: mc.strongButtonFg,
              onPressed: _recording && !_stopping ? _togglePause : null,
            ),
            const SizedBox(width: 40),
            _RoundAction(
              label: 'Done',
              semanticsLabel: 'Stop and transcribe',
              icon: Icons.check,
              background: accent,
              foreground: Colors.white,
              busy: _stopping,
              onPressed: _recording && !_stopping ? _stop : null,
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _LevelCircle extends StatefulWidget {
  final double level;
  final double smoothingMs;
  final bool busy;

  const _LevelCircle({
    required this.level,
    required this.smoothingMs,
    required this.busy,
  });

  @override
  State<_LevelCircle> createState() => _LevelCircleState();
}

class _LevelCircleState extends State<_LevelCircle>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration? _lastElapsed;
  final _shown = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void didUpdateWidget(_LevelCircle old) {
    super.didUpdateWidget(old);
    if (widget.level != _shown.value && !_ticker.isActive) {
      _lastElapsed = null;
      _ticker.start();
    }
  }

  // Exponential easing whose time constant follows the sample cadence, so the
  // motion spans the gap until the next sample instead of snapping and holding
  void _onTick(Duration elapsed) {
    final frameMs = _lastElapsed == null
        ? 16.0
        : (elapsed - _lastElapsed!).inMicroseconds / 1000;
    _lastElapsed = elapsed;
    final target = widget.level;
    final cur = _shown.value;
    final diff = target - cur;
    if (diff.abs() < 0.002) {
      _shown.value = target;
      _ticker.stop();
      return;
    }
    final tau = widget.smoothingMs * (diff > 0 ? 0.25 : 0.45);
    final alpha = 1 - math.exp(-frameMs / tau);
    // Small changes move gently so steady speech does not jitter; large ones
    // keep full speed
    final gain = (diff.abs() / 0.25).clamp(0.3, 1.0);
    _shown.value = cur + diff * alpha * gain;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    const base = 120.0;

    return Semantics(
      label: 'Microphone level',
      value: '${(widget.level * 100).round()} percent',
      child: SizedBox(
        width: base * 2,
        height: base * 2,
        child: ValueListenableBuilder<double>(
          valueListenable: _shown,
          builder: (context, shown, child) {
            final v = reduceMotion ? 0.0 : shown;
            return Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: base + base * 0.9 * v,
                  height: base + base * 0.9 * v,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent.withValues(alpha: 0.12 + 0.12 * v),
                  ),
                ),
                Container(
                  width: base + base * 0.25 * v,
                  height: base + base * 0.25 * v,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent,
                  ),
                  child: child,
                ),
              ],
            );
          },
          child: widget.busy
              ? const Padding(
                  padding: EdgeInsets.all(40),
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : const Icon(Icons.mic, size: 52, color: Colors.white),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  final String label;
  final String semanticsLabel;
  final IconData icon;
  final Color background;
  final Color foreground;
  final bool busy;
  final VoidCallback? onPressed;

  const _RoundAction({
    required this.label,
    required this.semanticsLabel,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.onPressed,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;
    final enabled = onPressed != null;

    return Semantics(
      label: semanticsLabel,
      button: true,
      enabled: enabled,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: enabled ? background : background.withValues(alpha: 0.5),
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              child: SizedBox(
                width: 72,
                height: 72,
                child: Center(
                  child: busy
                      ? SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(foreground),
                          ),
                        )
                      : Icon(icon, size: 32, color: foreground),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          ExcludeSemantics(
            child: Text(
              label,
              style: TextStyle(fontSize: 14, color: mc.secondaryText),
            ),
          ),
        ],
      ),
    );
  }
}
