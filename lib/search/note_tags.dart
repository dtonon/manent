import '../notes/note.dart';

// A tag is `#` + a letter + word characters, and must start at a boundary.
// Requiring a leading letter keeps `#42` (issue numbers) out; the boundary
// keeps `page#section` out. URLs are matched before tags when rendering, so a
// fragment never reaches this.
final _tagPattern = RegExp(
  r'''(^|[\s(\[{"'])#(\p{L}[\p{L}\p{N}_-]*)''',
  unicode: true,
  multiLine: true,
);

// Tags live in the note body, or in the caption for file notes
String tagSourceOf(DecryptedNote note) =>
    note.kind == NoteKind.file ? (note.attachment?.caption ?? '') : note.text;

// Parsing runs on every keystroke while filtering, so memoise by source text.
// Notes are immutable, so a given string always yields the same tags.
final _cache = <String, Set<String>>{};
const _cacheLimit = 5000;

Set<String> extractTags(String text) {
  if (text.isEmpty) return const {};
  final hit = _cache[text];
  if (hit != null) return hit;
  final tags = <String>{};
  for (final m in _tagPattern.allMatches(text)) {
    tags.add(m.group(2)!.toLowerCase());
  }
  final result = tags.isEmpty ? const <String>{} : tags;
  if (_cache.length >= _cacheLimit) _cache.clear();
  _cache[text] = result;
  return result;
}

Set<String> tagsOf(DecryptedNote note) => extractTags(tagSourceOf(note));

// Every match of `#tag` in a string, with offsets, for span rendering
Iterable<({int start, int end, String tag})> tagMatches(String text) sync* {
  for (final m in _tagPattern.allMatches(text)) {
    final lead = m.group(1)!.length;
    yield (
      start: m.start + lead,
      end: m.end,
      tag: m.group(2)!.toLowerCase(),
    );
  }
}

// Counts over the notes that already match the other facets, so each number is
// what adding that tag to the selection would contribute.
Map<String, int> tagCounts(List<DecryptedNote> notes) {
  final counts = <String, int>{};
  for (final note in notes) {
    for (final tag in tagsOf(note)) {
      counts[tag] = (counts[tag] ?? 0) + 1;
    }
  }
  return counts;
}

// Offered when composing so pressing `#` always shows something, even before
// the user has tagged anything. They carry no count until actually used.
const defaultTags = ['todo', 'important', 'nostr'];

// Composer suggestions: the user's own tags first (by frequency), then any
// unused defaults. Search does not use these — offering a tag that matches no
// note would be a dead end there.
List<String> suggestTags(
  List<DecryptedNote> notes,
  String prefix, {
  int limit = 5,
}) {
  final counts = tagCounts(notes);
  for (final t in defaultTags) {
    counts.putIfAbsent(t, () => 0);
  }
  return sortedTags(counts)
      .where((t) => t.startsWith(prefix))
      .take(limit)
      .toList();
}

// Most used first, then alphabetical so the order is stable between rebuilds.
// `byCount: false` is plain alphabetical — worth it where the whole list is on
// screen at once, since counts shift as tags are selected and a frequency sort
// would reshuffle the list under the pointer.
List<String> sortedTags(Map<String, int> counts, {bool byCount = true}) {
  final tags = counts.keys.toList();
  tags.sort((a, b) {
    if (!byCount) return a.compareTo(b);
    final delta = counts[b]!.compareTo(counts[a]!);
    return delta != 0 ? delta : a.compareTo(b);
  });
  return tags;
}
