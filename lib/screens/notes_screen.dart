import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:ndk/ndk.dart';

import '../auth/auth_state.dart';
import '../notes/note.dart';
import '../notes/note_cache.dart';
import '../theme.dart';
import '../widgets/manent_app_bar.dart';

class NotesScreen extends StatefulWidget {
  final AuthUser user;
  final Future<void> Function() onLogout;

  const NotesScreen({super.key, required this.user, required this.onLogout});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _sending = false;
  int _noteCount = 0;

  @override
  void initState() {
    super.initState();
    NoteCache.instance.notifier.addListener(_onNotesChanged);
    _noteCount = NoteCache.instance.notifier.value.length;
    if (_noteCount > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  void _onNotesChanged() {
    final notes = NoteCache.instance.notifier.value;
    if (notes.length > _noteCount) _scrollToBottom();
    _noteCount = notes.length;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendNote() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _textController.clear();
    await NoteCache.instance.add(text);
    if (mounted) setState(() => _sending = false);
  }

  void _showProfileSheet() {
    final npub = Nip19.encodePubKey(widget.user.pubkey);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          16,
          24,
          MediaQuery.of(ctx).viewInsets.bottom + 32,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 24),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            CircleAvatar(
              radius: 48,
              backgroundImage: widget.user.avatarUrl != null
                  ? NetworkImage(widget.user.avatarUrl!)
                  : null,
              backgroundColor: accent,
              child: widget.user.avatarUrl == null
                  ? Text(
                      widget.user.name.isNotEmpty
                          ? widget.user.name[0].toUpperCase()
                          : '?',
                      style: const TextStyle(color: Colors.white, fontSize: 32),
                    )
                  : null,
            ),
            const SizedBox(height: 16),
            Text(
              widget.user.name,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              '${npub.substring(0, 8)}...${npub.substring(npub.length - 8)}',
              style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[500],
              ),
              textAlign: TextAlign.center,
            ),
            if (widget.user.writeRelays.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                'Write relays',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[600],
                ),
              ),
              const SizedBox(height: 8),
              ...widget.user.writeRelays.map(
                (url) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    url,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[700],
                    ),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await widget.onLogout();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
                child: const Text('Log out', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  AppBar _buildSelectionAppBar() {
    return AppBar(
      backgroundColor: accent,
      elevation: 0,
      automaticallyImplyLeading: false,
      centerTitle: true,
      title: const Text(
        'Selection mode',
        style: TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w500,
        ),
      ),
      actions: [
        Semantics(
          label: 'Exit selection mode',
          button: true,
          child: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => _NoteCardState._selectionModeId.value = null,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: _NoteCardState._selectionModeId,
      builder: (context, selectionId, _) {
        final inSelection = selectionId != null;
        return PopScope(
          canPop: !inSelection,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _NoteCardState._selectionModeId.value = null;
          },
          child: Scaffold(
            backgroundColor: background,
            appBar: inSelection
                ? _buildSelectionAppBar()
                : manentAppBar(
                    actions: [
                      Padding(
                        padding: const EdgeInsets.only(right: 20),
                        child: Semantics(
                          label: 'Profile: ${widget.user.name}',
                          button: true,
                          child: GestureDetector(
                            onTap: _showProfileSheet,
                            child: CircleAvatar(
                              radius: 18,
                              backgroundImage: widget.user.avatarUrl != null
                                  ? NetworkImage(widget.user.avatarUrl!)
                                  : null,
                              backgroundColor: accent,
                              child: widget.user.avatarUrl == null
                                  ? Text(
                                      widget.user.name.isNotEmpty
                                          ? widget.user.name[0].toUpperCase()
                                          : '?',
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 14),
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
            body: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: inSelection
                  ? () => _NoteCardState._selectionModeId.value = null
                  : null,
              child: Column(
                children: [
                  Expanded(
                    child: ValueListenableBuilder<List<DecryptedNote>>(
                      valueListenable: NoteCache.instance.notifier,
                      builder: (context, notes, _) {
                        if (notes.isEmpty) {
                          return const Center(
                            child: Text(
                              'No notes yet',
                              style:
                                  TextStyle(color: Colors.grey, fontSize: 14),
                            ),
                          );
                        }
                        return ListView(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(16),
                          children: _buildNoteItems(notes),
                        );
                      },
                    ),
                  ),
                  _buildInputBar(context),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildNoteItems(List<DecryptedNote> notes) {
    final items = <Widget>[];
    DateTime? lastDate;

    for (final note in notes) {
      final noteDate = DateUtils.dateOnly(note.createdAt);
      if (lastDate == null || noteDate != lastDate) {
        if (items.isNotEmpty) items.add(const SizedBox(height: 12));
        items.add(_buildDateSeparator(_formatDate(note.createdAt)));
        lastDate = noteDate;
      }
      items.add(const SizedBox(height: 12));
      items.add(_NoteCard(note: note));
    }

    return items;
  }

  String _formatDate(DateTime dt) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${dt.day} ${months[dt.month - 1]}';
  }

  Widget _buildDateSeparator(String date) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        date,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildInputBar(BuildContext context) {
    final isMobile = defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;
    final bottomInset =
        isMobile ? MediaQuery.of(context).padding.bottom : 0.0;
    final maxHeight = MediaQuery.of(context).size.height * 0.5;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
      ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              offset: const Offset(0, -1),
              blurRadius: 4,
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Memo...',
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  hintStyle: TextStyle(
                    color: Colors.grey,
                    fontSize: 14,
                  ),
                ),
                style: const TextStyle(fontSize: 14, height: 1.3),
              ),
            ),
            const SizedBox(width: 12),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _textController,
              builder: (context, value, _) {
                final hasText = value.text.trim().isNotEmpty;
                return Opacity(
                  opacity: hasText ? 1.0 : 0.0,
                  child: IgnorePointer(
                    ignoring: !hasText || _sending,
                    child: Semantics(
                      label: 'Send note',
                      button: true,
                      child: GestureDetector(
                        onTap: _sendNote,
                        child: _sending
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor:
                                      AlwaysStoppedAnimation<Color>(accent),
                                ),
                              )
                            : const Icon(Icons.send, color: accent),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
      ),
      if (bottomInset > 0)
        Container(
          height: bottomInset,
          color: const Color(0xFFEEEEEE),
        ),
    ]);
  }

  @override
  void dispose() {
    _NoteCardState._selectionModeId.value = null;
    NoteCache.instance.notifier.removeListener(_onNotesChanged);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

class _NoteCard extends StatefulWidget {
  final DecryptedNote note;

  const _NoteCard({required this.note});

  @override
  State<_NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends State<_NoteCard> {
  static final _activeMenuId = ValueNotifier<String?>(null);
  static final _selectionModeId = ValueNotifier<String?>(null);

  String? _desktopSelectedContent;

  bool _retrying = false;
  Offset _tapPosition = Offset.zero;

  static final _urlRegex = RegExp(
    r'https?://[^\s]+|[a-zA-Z0-9][a-zA-Z0-9\-]*\.[a-zA-Z]{2,}(?:/[^\s]*)?',
    caseSensitive: false,
  );

  static bool get _isDesktopOrWeb =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  Widget _buildSyncIcon() {
    switch (widget.note.syncStatus) {
      case SyncStatus.synced:
        return Semantics(
          label: 'Synced to relay',
          child: Icon(Icons.check, size: 14, color: Colors.grey[400]),
        );
      case SyncStatus.failed:
        return Semantics(
          label: 'Sync failed',
          child: const Icon(Icons.sync_problem, size: 14, color: accent),
        );
      case SyncStatus.pending:
        return Semantics(
          label: 'Sync pending',
          child: Icon(Icons.access_time, size: 14, color: Colors.grey[400]),
        );
    }
  }

  Future<void> _retry() async {
    setState(() => _retrying = true);
    final success = await NoteCache.instance.retryDecrypt(widget.note.id);
    if (mounted && !success) setState(() => _retrying = false);
  }

  Future<void> _showContextMenu() async {
    _activeMenuId.value = widget.note.id;

    // Capture selection now — it may clear once the overlay appears
    final selectedText =
        _isDesktopOrWeb ? _desktopSelectedContent : null;
    final hasSelection = selectedText != null && selectedText.isNotEmpty;

    final completer = Completer<String?>();
    OverlayEntry? entry;

    void dismiss([String? value]) {
      entry?.remove();
      entry = null;
      completer.complete(value);
    }

    entry = OverlayEntry(
      builder: (_) => _NoteMenuOverlay(
        tapPosition: _tapPosition,
        onSelect: dismiss,
        showRetry: widget.note.error != null,
        showRetrySync: widget.note.syncStatus == SyncStatus.failed ||
            (widget.note.syncStatus == SyncStatus.pending &&
                widget.note.nostrId == null),
        showSelectText: !_isDesktopOrWeb,
        copyLabel: hasSelection ? 'Copy selected text' : 'Copy text',
      ),
    );

    Overlay.of(context).insert(entry!);
    final result = await completer.future;

    _activeMenuId.value = null;

    if (result == 'retry_sync') {
      NoteCache.instance.retrySync(widget.note.id);
    } else if (result == 'copy') {
      final textToCopy = hasSelection ? selectedText : widget.note.text;
      await Clipboard.setData(ClipboardData(text: textToCopy));
    } else if (result == 'select_text') {
      _selectionModeId.value = widget.note.id;
    } else if (result == 'retry') {
      _retry();
    } else if (result == 'delete') {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete note'),
          content: const Text('Are you sure you want to delete this message?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await NoteCache.instance
            .delete(widget.note.id, nostrId: widget.note.nostrId);
      }
    }
  }

  List<InlineSpan> _buildTextSpans(String text, TextStyle baseStyle) {
    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in _urlRegex.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(
            text: text.substring(lastEnd, match.start), style: baseStyle));
      }

      String url = match.group(0)!.replaceAll(RegExp(r'[.,!?;:)]+$'), '');
      final fullUrl = url.startsWith('http') ? url : 'https://$url';

      spans.add(TextSpan(
        text: url,
        style: baseStyle.copyWith(
          color: accent,
          decoration: TextDecoration.underline,
          decorationColor: accent,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () =>
              launchUrl(Uri.parse(fullUrl), mode: LaunchMode.platformDefault),
      ));
      lastEnd = match.start + url.length;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd), style: baseStyle));
    }

    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final core = ListenableBuilder(
      listenable: Listenable.merge([_activeMenuId, _selectionModeId]),
      builder: (context, _) {
        final menuId = _activeMenuId.value;
        final selectionId = _selectionModeId.value;
        final isActiveSelection = selectionId == widget.note.id;
        final inAnyMode = menuId != null || selectionId != null;

        final color =
            (!inAnyMode || menuId == widget.note.id || isActiveSelection)
                ? Colors.white
                : const Color(0xFFEEEEEE);

        void Function(TapDownDetails)? onTapDown;
        void Function()? onTap;
        void Function(TapDownDetails)? onSecondaryTapDown;

        if (isActiveSelection) {
          // All null — SelectableText handles everything
        } else if (selectionId != null) {
          // Non-active card: tap exits selection mode
          if (!_isDesktopOrWeb) onTap = () => _selectionModeId.value = null;
        } else {
          // Normal mode
          if (!_isDesktopOrWeb) {
            onTapDown = (d) => _tapPosition = d.globalPosition;
            onTap = _showContextMenu;
          }
          if (_isDesktopOrWeb) {
            onSecondaryTapDown = (d) {
              _tapPosition = d.globalPosition;
              _showContextMenu();
            };
          }
        }

        return GestureDetector(
          behavior: isActiveSelection
              ? HitTestBehavior.translucent
              : HitTestBehavior.opaque,
          onTapDown: onTapDown,
          onTap: onTap,
          onSecondaryTapDown: onSecondaryTapDown,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
            ),
            child:
                _retrying ? _buildSpinner() : _buildContent(isActiveSelection),
          ),
        );
      },
    );

    return core;
  }

  Widget _buildSpinner() {
    return const SizedBox(
      height: 40,
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(accent),
          ),
        ),
      ),
    );
  }

  Widget _buildContent([bool inSelectionMode = false]) {
    if (widget.note.error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Error:',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: accent,
            ),
          ),
          Text(
            widget.note.error!,
            style: const TextStyle(
                fontSize: 14, height: 1.3, color: Colors.black87),
          ),
          if (widget.note.nostrId != null)
            Text(
              'Event ID: ${widget.note.nostrId}',
              style: const TextStyle(
                  fontSize: 14, height: 1.3, color: Colors.black87),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatTime(widget.note.createdAt),
                  style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                ),
                const SizedBox(width: 4),
                _buildSyncIcon(),
              ],
            ),
          ),
        ],
      );
    }

    final textSpan = TextSpan(
      children: _buildTextSpans(
        widget.note.text,
        const TextStyle(fontSize: 14, height: 1.3, color: Colors.black87),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isDesktopOrWeb)
          DefaultSelectionStyle(
            selectionColor: textSelectionColor,
            child: SelectableText.rich(
              textSpan,
              onSelectionChanged: (sel, _) {
                if (!sel.isCollapsed && sel.isValid) {
                  final raw = widget.note.text
                      .substring(sel.start, sel.end)
                      .trim();
                  _desktopSelectedContent = raw.isEmpty ? null : raw;
                } else {
                  _desktopSelectedContent = null;
                }
              },
              // Suppress built-in menu so the right-click overlay still works
              contextMenuBuilder: (_, __) => const SizedBox.shrink(),
            ),
          )
        else if (inSelectionMode)
          // Default context menu — shows the native OS toolbar (copy, select all…)
          DefaultSelectionStyle(
            selectionColor: textSelectionColor,
            child: SelectableText.rich(textSpan),
          )
        else
          Text.rich(textSpan),
        Align(
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildSyncIcon(),
              const SizedBox(width: 4),
              Text(
                _formatTime(widget.note.createdAt),
                style: TextStyle(fontSize: 12, color: Colors.grey[400]),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NoteMenuOverlay extends StatelessWidget {
  final Offset tapPosition;
  final void Function([String?]) onSelect;
  final bool showRetry;
  final bool showRetrySync;
  final bool showSelectText;
  final String copyLabel;

  const _NoteMenuOverlay({
    required this.tapPosition,
    required this.onSelect,
    required this.showRetry,
    this.showRetrySync = false,
    this.showSelectText = false,
    this.copyLabel = 'Copy text',
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onSelect(null),
            onSecondaryTap: () => onSelect(null),
          ),
        ),
        CustomSingleChildLayout(
          delegate: _MenuPositionDelegate(tapPosition,
              isDesktopOrWeb: _NoteCardState._isDesktopOrWeb),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE0E0E0)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 24,
                  spreadRadius: 0,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Material(
                color: Colors.transparent,
                child: IntrinsicWidth(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (showRetrySync) ...[
                        InkWell(
                          onTap: () => onSelect('retry_sync'),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            child: Text(
                              'Retry sync',
                              style:
                                  TextStyle(fontSize: 14, color: Colors.black87),
                            ),
                          ),
                        ),
                        const Divider(height: 1, color: Color(0xFFE0E0E0)),
                      ],
                      InkWell(
                        onTap: () => onSelect('copy'),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          child: Text(
                            copyLabel,
                            style:
                                const TextStyle(fontSize: 14, color: Colors.black87),
                          ),
                        ),
                      ),
                      if (showSelectText) ...[
                        const Divider(height: 1, color: Color(0xFFE0E0E0)),
                        InkWell(
                          onTap: () => onSelect('select_text'),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            child: Text(
                              'Select text',
                              style: TextStyle(
                                  fontSize: 14, color: Colors.black87),
                            ),
                          ),
                        ),
                      ],
                      if (showRetry) ...[
                        const Divider(height: 1, color: Color(0xFFE0E0E0)),
                        InkWell(
                          onTap: () => onSelect('retry'),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            child: Text(
                              'Try to decrypt again',
                              style: TextStyle(
                                  fontSize: 14, color: Colors.black87),
                            ),
                          ),
                        ),
                      ],
                      const Divider(height: 1, color: Color(0xFFE0E0E0)),
                      InkWell(
                        onTap: () => onSelect('delete'),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          child: Text(
                            'Delete',
                            style: TextStyle(fontSize: 14, color: Colors.red),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MenuPositionDelegate extends SingleChildLayoutDelegate {
  final Offset tapPosition;
  final bool isDesktopOrWeb;

  const _MenuPositionDelegate(this.tapPosition, {required this.isDesktopOrWeb});

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(minWidth: 200, maxWidth: constraints.maxWidth - 32);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double x;
    if (isDesktopOrWeb) {
      // Follow the cursor, clamped to screen edges
      x = tapPosition.dx.clamp(8.0, size.width - childSize.width - 8.0);
    } else {
      // Pin to the opposite edge so the finger never covers the menu
      if (tapPosition.dx > size.width / 2) {
        x = 26.0;
      } else {
        x = size.width - childSize.width - 26.0;
      }
    }
    return Offset(x, tapPosition.dy + 4);
  }

  @override
  bool shouldRelayout(_MenuPositionDelegate old) =>
      old.tapPosition != tapPosition || old.isDesktopOrWeb != isDesktopOrWeb;
}
