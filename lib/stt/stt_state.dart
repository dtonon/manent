import 'package:flutter/foundation.dart';

// Note ids queued or running transcription; pure Dart so web builds can use it
class SttState {
  static final transcribing = ValueNotifier<Set<String>>(const {});

  static void add(String id) =>
      transcribing.value = {...transcribing.value, id};

  static void remove(String id) =>
      transcribing.value = {...transcribing.value}..remove(id);
}
