import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    NoteCache.instance.notifier.addListener(_onNotesChanged);
    // Scroll to bottom on first load if notes are already available
    if (NoteCache.instance.notifier.value.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  void _onNotesChanged() => _scrollToBottom();

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
                  fontFamily: 'monospace'),
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
                      fontFamily: 'monospace',
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: background,
      appBar: manentAppBar(
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
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
      body: Column(
        children: [
          Expanded(
            child: ValueListenableBuilder<List<DecryptedNote>>(
              valueListenable: NoteCache.instance.notifier,
              builder: (context, notes, _) {
                if (notes.isEmpty) {
                  return const Center(
                    child: Text(
                      'No notes yet',
                      style: TextStyle(color: Colors.grey, fontSize: 14),
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
      items.add(note.error != null
          ? _buildErrorMessage(note)
          : _buildTextMessage(note.text, _formatTime(note.createdAt)));
    }

    return items;
  }

  String _formatDate(DateTime dt) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${dt.day} ${months[dt.month - 1]}';
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  Widget _buildErrorMessage(DecryptedNote note) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
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
            note.error!,
            style: const TextStyle(fontSize: 14, height: 1.3, color: Colors.black87),
          ),
          if (note.nostrId != null)
            Text(
              'Event ID: ${note.nostrId}',
              style: const TextStyle(fontSize: 14, height: 1.3, color: Colors.black87),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              _formatTime(note.createdAt),
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextMessage(String text, String time) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              children: _buildTextSpans(
                text,
                const TextStyle(
                  fontSize: 14,
                  height: 1.3,
                  color: Colors.black87,
                ),
              ),
            ),
          ),
          const SizedBox(height: 0),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              time,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[400],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static final _urlRegex = RegExp(
    r'https?://[^\s]+|[a-zA-Z0-9][a-zA-Z0-9\-]*\.[a-zA-Z]{2,}(?:/[^\s]*)?',
    caseSensitive: false,
  );

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
    final maxHeight = MediaQuery.of(context).size.height * 0.5;
    return ConstrainedBox(
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
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
                  hintStyle: TextStyle(
                    color: Colors.grey,
                    fontSize: 14,
                  ),
                ),
                style: const TextStyle(fontSize: 14),
              ),
            ),
            const SizedBox(width: 12),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _textController,
              builder: (context, value, _) {
                final hasText = value.text.trim().isNotEmpty;
                if (hasText) {
                  return Semantics(
                    label: 'Send note',
                    button: true,
                    child: GestureDetector(
                      onTap: _sending ? null : _sendNote,
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
                  );
                }
                return Row(
                  children: [
                    Icon(Icons.attach_file, color: Colors.grey[700]),
                    const SizedBox(width: 16),
                    Icon(Icons.mic, color: Colors.grey[700]),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    NoteCache.instance.notifier.removeListener(_onNotesChanged);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}
