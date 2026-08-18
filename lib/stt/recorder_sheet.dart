import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../theme.dart';

Future<({Uint8List bytes, String name})?> showRecorderSheet(
    BuildContext context) {
  return showModalBottomSheet<({Uint8List bytes, String name})>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => const _RecorderSheet(),
  );
}

class _RecorderSheet extends StatefulWidget {
  const _RecorderSheet();

  @override
  State<_RecorderSheet> createState() => _RecorderSheetState();
}

class _RecorderSheetState extends State<_RecorderSheet> {
  final _recorder = AudioRecorder();
  Timer? _ticker;
  StreamSubscription<Amplitude>? _ampSub;
  String? _path;
  String? _error;
  bool _recording = false;
  bool _stopping = false;
  int _elapsedSeconds = 0;
  double _level = 0;

  @override
  void initState() {
    super.initState();
    _start();
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
      _path = p.join(
          dir.path, 'rec-${DateTime.now().millisecondsSinceEpoch}.wav');
      // 16 kHz mono WAV is what whisper.cpp expects; no transcoding needed
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: _path!,
      );
      _ampSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 200))
          .listen((a) {
        // Amplitude is dBFS, roughly -50..0
        final v = ((a.current + 50) / 50).clamp(0.0, 1.0);
        if (mounted) setState(() => _level = v);
      }, onError: (_) {});
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsedSeconds++);
      });
      if (mounted) setState(() => _recording = true);
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

  Future<void> _stop() async {
    if (_stopping || !_recording) return;
    setState(() => _stopping = true);
    _ticker?.cancel();
    await _ampSub?.cancel();
    try {
      final path = await _recorder.stop();
      if (path == null) throw Exception('no file produced');
      final file = File(path);
      final bytes = await file.readAsBytes();
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
      if (mounted) {
        setState(() {
          _stopping = false;
          _recording = false;
          _error = 'Recording failed: $e';
        });
      }
    }
  }

  Future<void> _cancel() async {
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
    _ticker?.cancel();
    _ampSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  String get _elapsedLabel {
    final m = (_elapsedSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;

    if (_error != null) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_error!, style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.fiber_manual_record,
                    size: 16,
                    color: _recording ? Colors.red : mc.iconMuted),
                const SizedBox(width: 8),
                Text(
                  _elapsedLabel,
                  style: const TextStyle(
                      fontSize: 16, fontFeatures: [FontFeature.tabularFigures()]),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Semantics(
                    label: 'Microphone level',
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        color: mc.cardDim,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: _level,
                        child: Container(
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Semantics(
                  label: 'Discard recording',
                  button: true,
                  child: TextButton(
                    onPressed: _stopping ? null : _cancel,
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Semantics(
                  label: 'Stop and transcribe',
                  button: true,
                  child: ElevatedButton.icon(
                    onPressed: _recording && !_stopping ? _stop : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.white,
                    ),
                    icon: _stopping
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Icon(Icons.stop),
                    label: const Text('Done'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
