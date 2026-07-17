import 'package:flutter/material.dart';

import '../notes/note.dart';
import '../theme.dart';
import 'note_filter.dart';
import 'note_search.dart';
import 'note_tags.dart';

const searchPanelWidth = 280.0;

// Shared text field. Same controller/focus in both layouts so the query
// survives a window resize that swaps one presentation for the other.
class _QueryField extends StatelessWidget {
  final bool showIcon;
  const _QueryField({this.showIcon = false});

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;
    final search = NoteSearch.instance;
    return ValueListenableBuilder<NoteFilter>(
      valueListenable: search.filter,
      builder: (context, filter, _) {
        return Container(
          decoration: BoxDecoration(
            color: mc.cardDim,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (showIcon) ...[
                Icon(Icons.search, size: 18, color: mc.iconMuted),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: TextField(
                  controller: search.queryController,
                  focusNode: search.queryFocus,
                  onChanged: search.setQuery,
                  textInputAction: TextInputAction.search,
                  style: TextStyle(fontSize: 14, color: mc.primaryText),
                  decoration: InputDecoration(
                    hintText: 'keyword...',
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    hintStyle: TextStyle(color: mc.hintText, fontSize: 14),
                  ),
                ),
              ),
              if (filter.query.isNotEmpty)
                Semantics(
                  label: 'Clear search',
                  button: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: search.clearQuery,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(Icons.close, size: 18, color: mc.iconMuted),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// Tags offered right now: all of them, or — while the query is `#…` — only
// those matching what has been typed, so the chips narrow as you type.
List<({String tag, int count})> _visibleTags(
    List<DecryptedNote> allNotes, NoteFilter filter) {
  final counts = tagCounts(notesForTagCounts(allNotes, filter));
  // A selected tag stays listed even when the prefix no longer matches it
  for (final t in filter.tags) {
    counts.putIfAbsent(t, () => 0);
  }
  final prefix = filter.tagPrefix;
  final names = sortedTags(counts)
      .where((t) => prefix == null || prefix.isEmpty || t.startsWith(prefix));
  return [for (final t in names) (tag: t, count: counts[t] ?? 0)];
}

class _Chip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final String semanticLabel;

  const _Chip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    required this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;
    return Semantics(
      label: semanticLabel,
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? mc.selectedFill : mc.cardDim,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            '$label  $count',
            style: TextStyle(
              fontSize: 13,
              color: selected ? Colors.white : mc.secondaryText,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

// Compact facets for the inline layout: kinds, then tags, in one scrolling
// row — a second row would not survive the keyboard on a small phone.
class _FacetChips extends StatelessWidget {
  final Map<NoteKindFilter, int> counts;
  final NoteFilter filter;
  final List<({String tag, int count})> tags;

  const _FacetChips({
    required this.counts,
    required this.filter,
    required this.tags,
  });

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;
    final search = NoteSearch.instance;
    // While typing `#…` the row is a tag picker, so the kinds step aside
    final showKinds = filter.tagPrefix == null;
    final kinds = NoteKindFilter.values
        .where((k) =>
            k == NoteKindFilter.all || k == filter.kind || (counts[k] ?? 0) > 0)
        .toList();
    // Selected tags lead, so an active filter stays reachable without
    // scrolling back through the row
    final orderedTags = [
      ...tags.where((t) => filter.tags.contains(t.tag)),
      ...tags.where((t) => !filter.tags.contains(t.tag)),
    ];

    final children = <Widget>[
      if (showKinds) ...[
        for (final kind in kinds)
          _Chip(
            label: kind.label,
            count: counts[kind] ?? 0,
            selected: kind == filter.kind,
            onTap: () => search.setKind(kind),
            semanticLabel: '${kind.label}, ${counts[kind] ?? 0} notes',
          ),
        if (orderedTags.isNotEmpty)
          Container(
            width: 1,
            height: 18,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: mc.border,
          ),
      ],
      for (final t in orderedTags)
        _Chip(
          label: '#${t.tag}',
          count: t.count,
          selected: filter.tags.contains(t.tag),
          onTap: () => search.toggleTag(t.tag),
          semanticLabel: 'Tag ${t.tag}, ${t.count} notes',
        ),
    ];

    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: children.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) => children[i],
      ),
    );
  }
}

// Vertical facet list for the side panel — room for counts and full labels
class _KindRows extends StatelessWidget {
  final Map<NoteKindFilter, int> counts;
  final NoteKindFilter selected;
  const _KindRows({required this.counts, required this.selected});

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final kind in NoteKindFilter.values)
          Semantics(
            label: '${kind.label}, ${counts[kind] ?? 0} notes',
            button: true,
            selected: kind == selected,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => NoteSearch.instance.setKind(kind),
              child: Container(
                margin: const EdgeInsets.only(bottom: 2),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color:
                      kind == selected ? mc.selectedFill : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        kind.label,
                        style: TextStyle(
                          fontSize: 14,
                          color:
                              kind == selected ? Colors.white : mc.primaryText,
                          fontWeight: kind == selected
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                    Text(
                      '${counts[kind] ?? 0}',
                      style: TextStyle(
                        fontSize: 13,
                        color: kind == selected ? Colors.white70 : mc.faintText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// Vertical tag list for the side panel — multi-select, OR'd together
class _TagRows extends StatelessWidget {
  final List<({String tag, int count})> tags;
  final Set<String> selected;
  const _TagRows({required this.tags, required this.selected});

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final t in tags)
          Semantics(
            label: 'Tag ${t.tag}, ${t.count} notes',
            button: true,
            selected: selected.contains(t.tag),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => NoteSearch.instance.toggleTag(t.tag),
              child: Container(
                margin: const EdgeInsets.only(bottom: 2),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: selected.contains(t.tag)
                      ? mc.selectedFill
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '#${t.tag}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: selected.contains(t.tag)
                              ? Colors.white
                              : mc.primaryText,
                          fontWeight: selected.contains(t.tag)
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                    Text(
                      '${t.count}',
                      style: TextStyle(
                        fontSize: 13,
                        color: selected.contains(t.tag)
                            ? Colors.white70
                            : mc.faintText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// Mobile / narrow layout: sits in the composer's slot, so only one text field
// is ever focusable at a time.
class InlineSearchBar extends StatelessWidget {
  final List<DecryptedNote> allNotes;
  const InlineSearchBar({super.key, required this.allNotes});

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;
    return ValueListenableBuilder<NoteFilter>(
      valueListenable: NoteSearch.instance.filter,
      builder: (context, filter, _) {
        final counts = kindCounts(allNotes, filter);
        final tags = _visibleTags(allNotes, filter);
        return Container(
          decoration: BoxDecoration(
            color: mc.card,
            boxShadow: [
              BoxShadow(
                color: mc.shadow,
                offset: const Offset(0, -1),
                blurRadius: 4,
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FacetChips(counts: counts, filter: filter, tags: tags),
              const SizedBox(height: 10),
              const _QueryField(showIcon: true),
            ],
          ),
        );
      },
    );
  }
}

// Desktop layout: a real panel beside the list, taking the window's spare
// horizontal space rather than the list's height.
class SearchSidePanel extends StatelessWidget {
  final List<DecryptedNote> allNotes;
  final double width;
  const SearchSidePanel({
    super.key,
    required this.allNotes,
    this.width = searchPanelWidth,
  });

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;
    return ValueListenableBuilder<NoteFilter>(
      valueListenable: NoteSearch.instance.filter,
      builder: (context, filter, _) {
        final counts = kindCounts(allNotes, filter);
        final tags = _visibleTags(allNotes, filter);
        return Container(
          width: width,
          decoration: BoxDecoration(
            color: mc.card,
            border: Border(left: BorderSide(color: mc.border)),
          ),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Search',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: mc.primaryText,
                      ),
                    ),
                  ),
                  Semantics(
                    label: 'Close search',
                    button: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: NoteSearch.instance.close,
                      child: Icon(Icons.close, size: 18, color: mc.iconMuted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const _QueryField(showIcon: true),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Show',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: mc.primaryText,
                      ),
                    ),
                  ),
                  if (filter.kind != NoteKindFilter.all)
                    Semantics(
                      label: 'Clear kind filter',
                      button: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () =>
                            NoteSearch.instance.setKind(NoteKindFilter.all),
                        child: Icon(Icons.close, size: 18, color: mc.iconMuted),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              _KindRows(counts: counts, selected: filter.kind),
              if (tags.isNotEmpty) ...[
                const SizedBox(height: 20),
                Divider(height: 1, thickness: 1, color: mc.border),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Tags',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: mc.primaryText,
                        ),
                      ),
                    ),
                    // Only worth saying once the OR actually applies
                    if (filter.tags.length > 1)
                      Text(
                        'any of',
                        style: TextStyle(fontSize: 11, color: mc.faintText),
                      ),
                    if (filter.tags.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Semantics(
                        label: 'Clear tag filter',
                        button: true,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: NoteSearch.instance.clearTags,
                          child:
                              Icon(Icons.close, size: 18, color: mc.iconMuted),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                _TagRows(tags: tags, selected: filter.tags),
              ],
            ],
          ),
        );
      },
    );
  }
}
