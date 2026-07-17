import 'package:flutter/widgets.dart';

import 'note_filter.dart';

// Single source of truth for search state. The inline bar (mobile) and the side
// panel (desktop) are two presentations of this one object; main.dart also
// listens to `open` to widen the web layout constraint.
class NoteSearch {
  NoteSearch._() {
    // Any change to the filter is a deliberate move by the user, so the
    // just-added exemption has served its purpose by then.
    filter.addListener(() => justAdded.value = null);
  }
  static final instance = NoteSearch._();

  final open = ValueNotifier<bool>(false);
  final filter = ValueNotifier<NoteFilter>(const NoteFilter());

  // A note added while a filter was active that the filter would otherwise
  // hide. Kept visible so sending never looks like it did nothing.
  final justAdded = ValueNotifier<String?>(null);

  // App-lifetime, never disposed — the screen is rebuilt on login/logout
  final queryController = TextEditingController();
  final queryFocus = FocusNode();

  void setQuery(String value) =>
      filter.value = filter.value.copyWith(query: value);

  void setKind(NoteKindFilter kind) =>
      filter.value = filter.value.copyWith(kind: kind);

  // Selecting a tag consumes any `#…` the user typed to reach it
  void toggleTag(String tag) {
    final next = {...filter.value.tags};
    if (!next.remove(tag)) next.add(tag);
    final clearsPrefix = filter.value.tagPrefix != null;
    if (clearsPrefix) queryController.clear();
    filter.value = filter.value.copyWith(
      tags: next,
      query: clearsPrefix ? '' : null,
    );
  }

  void clearTags() => filter.value = filter.value.copyWith(tags: const {});

  // Tapping a tag inside a note jumps straight to that filter
  void openWithTag(String tag) {
    queryController.clear();
    filter.value = NoteFilter(tags: {tag});
    open.value = true;
  }

  void toggle() => open.value ? close() : openSearch();

  void openSearch() {
    open.value = true;
    queryFocus.requestFocus();
  }

  void close() {
    open.value = false;
    justAdded.value = null;
    reset();
  }

  // Tags the composer will apply to a new note, so it stays visible under the
  // filter it was written in. Only tags can be inherited — a text query or a
  // kind filter can't be satisfied by construction.
  Set<String> get inheritedTags => filter.value.tags;

  void clearQuery() {
    queryController.clear();
    setQuery('');
  }

  void reset() {
    queryController.clear();
    filter.value = const NoteFilter();
    queryFocus.unfocus();
  }
}
