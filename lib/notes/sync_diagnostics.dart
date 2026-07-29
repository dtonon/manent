// In-memory trail of what happened during a note's sync attempts, shown in the
// note raw data modal so a production build can report a cause.
class SyncDiagnostics {
  SyncDiagnostics._();
  static final instance = SyncDiagnostics._();

  static const _maxEntriesPerNote = 30;
  static const _maxNotes = 100;
  static const _maxDetailChars = 500;

  final _log = <String, List<String>>{};

  void record(String noteId, String message) {
    final entries = _log.putIfAbsent(noteId, () => <String>[]);
    entries.add('${DateTime.now().toIso8601String()}  $message');
    if (entries.length > _maxEntriesPerNote) entries.removeAt(0);
    if (_log.length > _maxNotes) _log.remove(_log.keys.first);
  }

  List<String> forNote(String noteId) =>
      List.unmodifiable(_log[noteId] ?? const <String>[]);

  void clear() => _log.clear();

  // Collapses whitespace and caps length so a relay or HTTP body stays readable
  static String detail(Object? value) {
    final s = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.length <= _maxDetailChars) return s;
    return '${s.substring(0, _maxDetailChars)}… (${s.length} chars)';
  }
}
