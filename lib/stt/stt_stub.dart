import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../notes/note_attachment.dart';

const sttAvailable = false;

bool canTranscribe(NoteAttachment attachment) => false;

Future<({Uint8List bytes, String name})?> recordVoiceNote(
        BuildContext context) async =>
    null;

Future<void> transcribeNote(BuildContext context, String noteId) async {}

Future<void> abortTranscription(String noteId) async {}

Future<void> openSttSettings(BuildContext context) async {}
