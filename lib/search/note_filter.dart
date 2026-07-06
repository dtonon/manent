import '../notes/note.dart';

// Facets derived from data we already store — no write-path changes needed.
enum NoteKindFilter { all, text, images, videos, files }

extension NoteKindFilterExt on NoteKindFilter {
  String get label => switch (this) {
        NoteKindFilter.all => 'All',
        NoteKindFilter.text => 'Text',
        NoteKindFilter.images => 'Images',
        NoteKindFilter.videos => 'Videos',
        NoteKindFilter.files => 'Files',
      };

  bool matches(DecryptedNote note) {
    if (this == NoteKindFilter.all) return true;
    final a = note.attachment;
    if (note.kind == NoteKind.text || a == null) {
      return this == NoteKindFilter.text;
    }
    return switch (this) {
      NoteKindFilter.images => a.isImage,
      NoteKindFilter.videos => a.isVideo,
      NoteKindFilter.files => !a.isImage && !a.isVideo,
      _ => false,
    };
  }
}

class NoteFilter {
  final String query;
  final NoteKindFilter kind;

  const NoteFilter({this.query = '', this.kind = NoteKindFilter.all});

  bool get isActive => query.trim().isNotEmpty || kind != NoteKindFilter.all;

  NoteFilter copyWith({String? query, NoteKindFilter? kind}) =>
      NoteFilter(query: query ?? this.query, kind: kind ?? this.kind);

  @override
  bool operator ==(Object other) =>
      other is NoteFilter && other.query == query && other.kind == kind;

  @override
  int get hashCode => Object.hash(query, kind);
}

// Text notes match on their body; file notes carry their text in the
// attachment caption, plus the filename is worth matching too.
bool noteMatchesQuery(DecryptedNote note, String needle) {
  if (needle.isEmpty) return true;
  if (note.text.toLowerCase().contains(needle)) return true;
  final a = note.attachment;
  if (a == null) return false;
  return (a.caption?.toLowerCase().contains(needle) ?? false) ||
      a.filename.toLowerCase().contains(needle);
}

List<DecryptedNote> filterNotes(List<DecryptedNote> notes, NoteFilter filter) {
  if (!filter.isActive) return notes;
  final needle = filter.query.trim().toLowerCase();
  return notes
      .where((n) => filter.kind.matches(n) && noteMatchesQuery(n, needle))
      .toList();
}

// Counts respect the active query, so each number is what switching to that
// facet would actually show.
Map<NoteKindFilter, int> kindCounts(List<DecryptedNote> notes, String query) {
  final needle = query.trim().toLowerCase();
  final matching =
      needle.isEmpty ? notes : notes.where((n) => noteMatchesQuery(n, needle));
  final counts = {for (final k in NoteKindFilter.values) k: 0};
  for (final note in matching) {
    for (final k in NoteKindFilter.values) {
      if (k.matches(note)) counts[k] = counts[k]! + 1;
    }
  }
  return counts;
}
