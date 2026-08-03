// In-memory trail of what happened during a note's sync attempts, shown in the
// note raw data modal so a production build can report a cause.
class SyncDiagnostics {
  SyncDiagnostics._();
  static final instance = SyncDiagnostics._();

  static const _maxEntriesPerNote = 30;
  static const _maxNotes = 100;
  static const _maxDetailChars = 500;
  static const _maxNdkEntries = 50;

  final _log = <String, List<String>>{};
  final _ndkTrail = <String>[];

  void record(String noteId, String message) {
    final entries = _log.putIfAbsent(noteId, () => <String>[]);
    entries.add('${DateTime.now().toIso8601String()}  $message');
    if (entries.length > _maxEntriesPerNote) entries.removeAt(0);
    if (_log.length > _maxNotes) _log.remove(_log.keys.first);
  }

  List<String> forNote(String noteId) =>
      List.unmodifiable(_log[noteId] ?? const <String>[]);

  // Global trail of NDK warnings/errors, not tied to a single note
  void recordNdk(String message) {
    _ndkTrail.add('${DateTime.now().toIso8601String()}  $message');
    if (_ndkTrail.length > _maxNdkEntries) _ndkTrail.removeAt(0);
  }

  List<String> get ndkTrail => List.unmodifiable(_ndkTrail);

  // Network self-test results; separate from the ndk trail so connect-error
  // floods cannot evict them
  final _selfTest = <String>[];

  void recordSelfTest(String message) {
    _selfTest.add('${DateTime.now().toIso8601String()}  $message');
  }

  void clearSelfTest() => _selfTest.clear();

  List<String> get selfTest => List.unmodifiable(_selfTest);

  void clear() {
    _log.clear();
    _ndkTrail.clear();
  }

  // Collapses whitespace and caps length so a relay or HTTP body stays readable
  static String detail(Object? value) {
    final s = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.length <= _maxDetailChars) return s;
    return '${s.substring(0, _maxDetailChars)}… (${s.length} chars)';
  }
}
