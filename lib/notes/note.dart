import 'note_attachment.dart';

enum NoteKind {
  text,
  file;

  int get eventKind => switch (this) {
        text => 33301,
        file => 33302,
      };

  static NoteKind fromEventKind(int k) =>
      k == 33302 ? file : text;
}

enum SyncStatus {
  pending,
  synced,
  failed;

  static SyncStatus fromInt(int v) => switch (v) {
        1 => synced,
        2 => failed,
        _ => pending,
      };

  int get value => switch (this) {
        pending => 0,
        synced => 1,
        failed => 2,
      };
}

class DecryptedNote {
  final String id;
  final String? nostrId;
  final String text;
  final String? error;
  final DateTime createdAt;
  final DateTime? editedAt;
  final SyncStatus syncStatus;
  final NoteKind kind;
  final NoteAttachment? attachment;

  const DecryptedNote({
    required this.id,
    this.nostrId,
    required this.text,
    this.error,
    required this.createdAt,
    this.editedAt,
    required this.syncStatus,
    this.kind = NoteKind.text,
    this.attachment,
  });
}
