import '../notes/note.dart';
import 'note_tags.dart';

// Facets derived from data we already store — no write-path changes needed.
enum NoteKindFilter { all, text, images, videos, files, sensitive }

extension NoteKindFilterExt on NoteKindFilter {
  String get label => switch (this) {
        NoteKindFilter.all => 'All',
        NoteKindFilter.text => 'Text',
        NoteKindFilter.images => 'Images',
        NoteKindFilter.videos => 'Videos',
        NoteKindFilter.files => 'Files',
        NoteKindFilter.sensitive => 'Sensitive',
      };

  bool matches(DecryptedNote note) {
    if (this == NoteKindFilter.all) return true;
    // Cuts across the media kinds rather than being one of them
    if (this == NoteKindFilter.sensitive) return note.sensitive;
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
  final Set<String> tags;

  const NoteFilter({
    this.query = '',
    this.kind = NoteKindFilter.all,
    this.tags = const {},
  });

  bool get isActive =>
      query.trim().isNotEmpty || kind != NoteKindFilter.all || tags.isNotEmpty;

  // A query of "#wo" narrows to tags starting with "wo" rather than searching
  // note text — it is how you reach a tag from the keyboard.
  String? get tagPrefix {
    final q = query.trim();
    return q.startsWith('#') ? q.substring(1).toLowerCase() : null;
  }

  NoteFilter copyWith({
    String? query,
    NoteKindFilter? kind,
    Set<String>? tags,
  }) =>
      NoteFilter(
        query: query ?? this.query,
        kind: kind ?? this.kind,
        tags: tags ?? this.tags,
      );

  @override
  bool operator ==(Object other) =>
      other is NoteFilter &&
      other.query == query &&
      other.kind == kind &&
      other.tags.length == tags.length &&
      other.tags.containsAll(tags);

  @override
  int get hashCode => Object.hash(query, kind, Object.hashAllUnordered(tags));
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

// The text half of the filter: either a tag prefix or a plain substring
bool _matchesQuery(DecryptedNote note, NoteFilter filter) {
  final prefix = filter.tagPrefix;
  if (prefix != null) {
    if (prefix.isEmpty) return true;
    return tagsOf(note).any((t) => t.startsWith(prefix));
  }
  return noteMatchesQuery(note, filter.query.trim().toLowerCase());
}

// Selected tags are AND'd with each other and with the other facets, so each
// tag added narrows the result further
bool _matchesTags(DecryptedNote note, NoteFilter filter) {
  if (filter.tags.isEmpty) return true;
  final noteTags = tagsOf(note);
  return filter.tags.every(noteTags.contains);
}

List<DecryptedNote> filterNotes(List<DecryptedNote> notes, NoteFilter filter) {
  if (!filter.isActive) return notes;
  return notes
      .where((n) =>
          filter.kind.matches(n) &&
          _matchesQuery(n, filter) &&
          _matchesTags(n, filter))
      .toList();
}

// Counts respect the active query and tags, so each number is what switching
// to that facet would actually show.
Map<NoteKindFilter, int> kindCounts(
    List<DecryptedNote> notes, NoteFilter filter) {
  final matching =
      notes.where((n) => _matchesQuery(n, filter) && _matchesTags(n, filter));
  final counts = {for (final k in NoteKindFilter.values) k: 0};
  for (final note in matching) {
    for (final k in NoteKindFilter.values) {
      if (k.matches(note)) counts[k] = counts[k]! + 1;
    }
  }
  return counts;
}

// Under AND a tag's count is what you would get by adding it to the current
// selection, so counts respect every active facet — tags that would leave
// nothing drop out of the list instead of offering a dead end.
List<DecryptedNote> notesForTagCounts(
        List<DecryptedNote> notes, NoteFilter filter) =>
    filterNotes(notes, filter);
