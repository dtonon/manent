import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

import '../audio/speech_audio.dart';
import '../notes/note_cache.dart';
import 'stt_model_manager.dart';
import 'stt_prompt.dart';
import 'stt_state.dart';

class SttService {
  SttService._();
  static final instance = SttService._();

  Future<void> _queue = Future.value();
  final _aborted = <String>{};
  String? _current;

  // On big.LITTLE phones extra threads land on the slow little cores and
  // drag the fast ones down; 4 covers the big/mid clusters
  static int get _threads => Platform.isAndroid || Platform.isIOS
      ? 4
      : max(2, min(6, Platform.numberOfProcessors - 2));

  // The arm64 build targets armv8.2+dotprod (see android/whisper_arch.cmake);
  // older CPUs would hit illegal instructions mid-inference, so refuse early
  static bool? _cpuSupported;
  static bool get _androidCpuOk {
    if (!Platform.isAndroid) return true;
    return _cpuSupported ??= () {
      try {
        return File('/proc/cpuinfo').readAsStringSync().contains('asimddp');
      } catch (_) {
        return true;
      }
    }();
  }

  // Serializes transcriptions; resolves to an error message or null
  Future<String?> transcribeNote(String noteId) {
    if (SttState.transcribing.value.contains(noteId)) {
      return Future.value(null);
    }
    SttState.add(noteId);
    final run = _queue.then((_) => _run(noteId));
    _queue = run.then((_) {}, onError: (_) {});
    return run.whenComplete(() => SttState.remove(noteId));
  }

  // The enum passed to Whisper() is irrelevant: transcribe() uses the explicit
  // modelPath and abort() flips a global native flag
  static Whisper get _whisper => const Whisper(model: WhisperModel.base);

  Future<void> abort(String noteId) async {
    _aborted.add(noteId);
    if (_current != noteId) return;
    try {
      await _whisper.abort();
    } catch (_) {}
  }

  Future<String?> _run(String noteId) async {
    if (_aborted.remove(noteId)) return null;

    final note = NoteCache.instance.byId(noteId);
    final attachment = note?.attachment;
    if (note == null || attachment == null) return 'Note not found.';

    if (!_androidCpuOk) {
      return 'Transcription is not supported on this device '
          '(the CPU lacks the required instructions).';
    }

    final manager = SttModelManager.instance;
    await manager.init();
    final model = manager.activeModel.value;
    if (model == null) return 'No transcription model downloaded.';
    final modelPath = await manager.pathFor(model);

    final bytes = await NoteCache.instance.getFileBytes(attachment);
    if (bytes == null) return 'Could not load the audio file.';
    if (_aborted.remove(noteId)) return null;

    // Whisper wants 16 kHz mono; other formats and rates are converted
    final speech = await toSpeechWav(bytes);
    if (speech == null) return 'This audio format cannot be transcribed.';
    if (_aborted.remove(noteId)) return null;

    // Plaintext WAV exists on disk only while whisper reads it
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'manent_stt'));
    await dir.create(recursive: true);
    final wav = File(p.join(dir.path, 'stt-${attachment.sha256}.wav'));
    await wav.writeAsBytes(speech);

    _current = noteId;
    try {
      final response = await _whisper.transcribe(
        transcribeRequest: TranscribeRequest(
          audio: wav.path,
          language: manager.language.value,
          threads: _threads,
          prompt: buildSttPrompt(NoteCache.instance.notifier.value),
        ),
        modelPath: modelPath,
      );
      if (_aborted.remove(noteId)) return null;
      final text = response.text.trim();
      if (text.isEmpty) return 'No speech detected.';
      await NoteCache.instance.setTranscript(noteId, text);
      return null;
    } catch (e) {
      if (_aborted.remove(noteId)) return null;
      return 'Transcription failed: $e';
    } finally {
      _current = null;
      try {
        await wav.delete();
      } catch (_) {}
    }
  }
}
