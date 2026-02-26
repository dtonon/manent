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

  const DecryptedNote({
    required this.id,
    this.nostrId,
    required this.text,
    this.error,
    required this.createdAt,
    this.editedAt,
    required this.syncStatus,
  });
}
