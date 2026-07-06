import 'package:flutter/widgets.dart';

import 'note_filter.dart';

// Single source of truth for search state. The inline bar (mobile) and the side
// panel (desktop) are two presentations of this one object; main.dart also
// listens to `open` to widen the web layout constraint.
class NoteSearch {
  NoteSearch._();
  static final instance = NoteSearch._();

  final open = ValueNotifier<bool>(false);
  final filter = ValueNotifier<NoteFilter>(const NoteFilter());

  // App-lifetime, never disposed — the screen is rebuilt on login/logout
  final queryController = TextEditingController();
  final queryFocus = FocusNode();

  void setQuery(String value) =>
      filter.value = filter.value.copyWith(query: value);

  void setKind(NoteKindFilter kind) =>
      filter.value = filter.value.copyWith(kind: kind);

  void toggle() => open.value ? close() : openSearch();

  void openSearch() {
    open.value = true;
    queryFocus.requestFocus();
  }

  void close() {
    open.value = false;
    reset();
  }

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
