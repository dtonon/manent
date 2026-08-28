import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../audio/speech_audio.dart';
import '../notes/note_attachment.dart';
import 'recorder_screen.dart';
import 'stt_model_manager.dart';
import 'stt_service.dart';
import 'stt_settings_sheet.dart';

const sttAvailable = true;

// WAV, mp3 and Ogg Vorbis: anything toSpeechWav can turn into 16 kHz mono
bool canTranscribe(NoteAttachment attachment) =>
    isSpeechConvertible(attachment.mimeType, attachment.filename);

// Ensures a model exists (offering the settings sheet), then records
Future<({Uint8List bytes, String name})?> recordVoiceNote(
  BuildContext context,
) async {
  final manager = SttModelManager.instance;
  await manager.init();
  if (!context.mounted) return null;
  if (!manager.hasDownloadedModel) {
    await showSttSettingsSheet(context, explainFirstUse: true);
    if (!manager.hasDownloadedModel || !context.mounted) return null;
  }
  return showRecorderScreen(context);
}

Future<void> transcribeNote(BuildContext context, String noteId) async {
  final manager = SttModelManager.instance;
  await manager.init();
  if (!context.mounted) return;
  if (!manager.hasDownloadedModel) {
    await showSttSettingsSheet(context, explainFirstUse: true);
    if (!manager.hasDownloadedModel) return;
  }
  final messenger = context.mounted ? ScaffoldMessenger.maybeOf(context) : null;
  final error = await SttService.instance.transcribeNote(noteId);
  if (error != null) {
    messenger?.showSnackBar(SnackBar(content: Text(error)));
  }
}

Future<void> abortTranscription(String noteId) =>
    SttService.instance.abort(noteId);

Future<void> openSttSettings(BuildContext context) =>
    showSttSettingsSheet(context);
