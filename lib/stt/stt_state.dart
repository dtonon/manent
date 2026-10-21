import 'package:flutter/foundation.dart';

// Note ids queued or running transcription; pure Dart so web builds can use it
class SttState {
  static final transcribing = ValueNotifier<Set<String>>(const {});

  // Note id inside whisper right now and when it got there; the other ids in
  // [transcribing] are queued behind it
  static final running = ValueNotifier<String?>(null);
  static DateTime? runningSince;

  static void setRunning(String? id) {
    runningSince = id == null ? null : DateTime.now();
    running.value = id;
  }

  static void add(String id) =>
      transcribing.value = {...transcribing.value, id};

  static void remove(String id) =>
      transcribing.value = {...transcribing.value}..remove(id);
}
