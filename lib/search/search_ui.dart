import 'package:flutter/material.dart';

import '../notes/note.dart';
import '../theme.dart';
import 'note_filter.dart';
import 'note_search.dart';

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

// Compact facet row for the inline layout
class _KindChips extends StatelessWidget {
  final Map<NoteKindFilter, int> counts;
  final NoteKindFilter selected;
  const _KindChips({required this.counts, required this.selected});

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: NoteKindFilter.values.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final kind = NoteKindFilter.values[i];
          final count = counts[kind] ?? 0;
          final isSelected = kind == selected;
          // Hide empty facets unless they are the current selection
          if (count == 0 && !isSelected && kind != NoteKindFilter.all) {
            return const SizedBox.shrink();
          }
          return Semantics(
            label: '${kind.label}, $count notes',
            button: true,
            selected: isSelected,
            child: GestureDetector(
              onTap: () => NoteSearch.instance.setKind(kind),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected ? mc.selectedFill : mc.cardDim,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '${kind.label}  $count',
                  style: TextStyle(
                    fontSize: 13,
                    color: isSelected ? Colors.white : mc.secondaryText,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ),
          );
        },
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
        final counts = kindCounts(allNotes, filter.query);
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
              _KindChips(counts: counts, selected: filter.kind),
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
        final counts = kindCounts(allNotes, filter.query);
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
              Text(
                'Show',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: mc.secondaryText,
                ),
              ),
              const SizedBox(height: 8),
              _KindRows(counts: counts, selected: filter.kind),
            ],
          ),
        );
      },
    );
  }
}
