class DecryptedNote {
  final String id;
  final String? nostrId;
  final String text;
  final String? error;
  final DateTime createdAt;
  final bool syncedToRelay;

  const DecryptedNote({
    required this.id,
    this.nostrId,
    required this.text,
    this.error,
    required this.createdAt,
    required this.syncedToRelay,
  });
}
