import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thumbhash/thumbhash.dart' hide Image;
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/web_download.dart';
import '../utils/web_image_resize.dart';

import 'package:ndk/ndk.dart';

import '../auth/auth_state.dart';
import '../auth/relay_constants.dart';
import '../notes/note.dart';
import '../notes/note_attachment.dart';
import '../notes/note_cache.dart';
import '../theme.dart';
import '../widgets/manent_app_bar.dart';

enum ImageResizePreset { small, medium, large, original }

extension _ImageResizePresetExt on ImageResizePreset {
  String get label => switch (this) {
        ImageResizePreset.small => 'Small',
        ImageResizePreset.medium => 'Medium',
        ImageResizePreset.large => 'Large',
        ImageResizePreset.original => 'Original',
      };
}

class NotesScreen extends StatefulWidget {
  final AuthUser user;
  final List<String> additionalRelays;
  final Future<void> Function(List<String>) onAdditionalRelaysChanged;
  final List<String> blossomServers;
  final Future<void> Function(List<String>) onBlossomServersChanged;
  final Future<void> Function() onLogout;

  const NotesScreen({
    super.key,
    required this.user,
    required this.additionalRelays,
    required this.onAdditionalRelaysChanged,
    required this.blossomServers,
    required this.onBlossomServersChanged,
    required this.onLogout,
  });

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();
  bool _sending = false;
  int _noteCount = 0;
  String? _editingNoteId;
  DecryptedNote? _editingNote;
  // Pending file selected by user, cleared after send
  ({Uint8List bytes, String name, String mimeType})? _pendingFile;
  // Original image bytes before any resize (null for non-image files)
  Uint8List? _originalImageBytes;
  ImageResizePreset _currentPreset = ImageResizePreset.original;
  // Encoded bytes per preset, computed in background after image pick
  Map<ImageResizePreset, Uint8List>? _presetBytes;

  @override
  void initState() {
    super.initState();
    NoteCache.instance.notifier.addListener(_onNotesChanged);
    NoteCache.instance.promptFallbackRelays
        .addListener(_onFallbackRelaysPrompt);
    if (NoteCache.instance.promptFallbackRelays.value) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _onFallbackRelaysPrompt());
    }
    _noteCount = NoteCache.instance.notifier.value.length;
    if (_noteCount > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
    _inputFocusNode.onKeyEvent = (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape &&
          _editingNoteId != null) {
        _cancelEdit();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux) {
      HardwareKeyboard.instance.addHandler(_onHardwareKey);
    }
    if (kIsWeb) BrowserContextMenu.disableContextMenu();
  }

  bool _onHardwareKey(KeyEvent event) {
    if (!mounted) return false;
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.arrowUp) return false;
    if (_textController.text.isNotEmpty || _editingNoteId != null) return false;
    _editLastNote();
    return true;
  }

  void _onNotesChanged() {
    final notes = NoteCache.instance.notifier.value;
    if (notes.length > _noteCount) _scrollToBottom();
    _noteCount = notes.length;
  }

  void _onFallbackRelaysPrompt() {
    if (!NoteCache.instance.promptFallbackRelays.value) return;
    NoteCache.instance.promptFallbackRelays.value = false;
    if (widget.additionalRelays.isNotEmpty) return;
    _showFallbackRelaysDialog();
  }

  Future<void> _showFallbackRelaysDialog() async {
    final shown = await AuthService.getFallbackPromptShown();
    if (shown || !mounted) return;
    await AuthService.setFallbackPromptShown();
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add fallback relays'),
        content: const Text(
          "Your relays don't appear to support Manent events (kind 33301), "
          'would you like to use nos.lol, nostr.mom and bitcoiner.social relays? '
          'They are only used locally (no NIP-65 update) and you can remove them anytime in the profile page.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No thanks'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add relays'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await widget.onAdditionalRelaysChanged(fallbackRelays);
    }
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
    if (_sending) return;
    final file = _pendingFile;
    if (file != null) {
      // Files ≥32KB require a Blossom server for upload
      if (file.bytes.length >= 32 * 1024 &&
          NoteCache.instance.blossomServers.isEmpty) {
        final added = await _showFallbackBlossomDialog();
        if (!added) return;
      }
      final comment = _textController.text.trim();
      setState(() {
        _sending = true;
        _pendingFile = null;
      });
      _textController.clear();
      await NoteCache.instance.addFile(
        file.bytes,
        file.name,
        comment: comment.isEmpty ? null : comment,
      );
      if (mounted) setState(() => _sending = false);
      return;
    }
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    _textController.clear();
    await NoteCache.instance.add(text);
    if (mounted) setState(() => _sending = false);
  }

  Future<bool> _showFallbackBlossomDialog() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('No Blossom servers'),
        content: const Text(
          'File uploads larger than 32KB require a Blossom server. '
          "Your account has none configured — would you like to use blossom.primal.net? "
          'You can see, and eventually remove it, in the profile page.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No thanks'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add server'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await widget.onBlossomServersChanged(['https://blossom.primal.net']);
      return true;
    }
    return false;
  }

  Future<void> _pickFile() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(withData: kIsWeb);
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().contains('zenity') || e.toString().contains('kdialog')
          ? 'Install zenity (GNOME) or kdialog (KDE) to pick files on Linux.'
          : 'Could not open file picker: $e';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final pf = result.files.first;
    Uint8List bytes;
    if (kIsWeb) {
      if (pf.bytes == null) return;
      bytes = pf.bytes!;
    } else {
      if (pf.path == null) return;
      bytes = await File(pf.path!).readAsBytes();
    }
    final mimeType = lookupMimeType(pf.name) ?? 'application/octet-stream';
    if (rasterImageMimeTypes.contains(mimeType)) {
      await _handleImagePicked(bytes, pf.name, mimeType);
    } else {
      setState(() {
        _pendingFile = (bytes: bytes, name: pf.name, mimeType: mimeType);
        _originalImageBytes = null;
        _presetBytes = null;
      });
    }
  }

  Future<void> _takePhoto() async {
    final xfile = await ImagePicker().pickImage(source: ImageSource.camera);
    if (xfile == null) return;
    final bytes = await xfile.readAsBytes();
    final mimeType = lookupMimeType(xfile.name) ?? 'image/jpeg';
    await _handleImagePicked(bytes, xfile.name, mimeType);
  }

  Future<void> _handleImagePicked(
      Uint8List bytes, String name, String mimeType) async {
    // Show the image immediately
    setState(() {
      _originalImageBytes = bytes;
      _presetBytes = null;
      _currentPreset = ImageResizePreset.original;
      _pendingFile = (bytes: bytes, name: name, mimeType: mimeType);
    });
    // Yield to let the UI update (preview + spinner) before heavy work
    await Future.delayed(Duration.zero);

    final savedPreset = await AuthService.getImageResizePreset();
    if (!mounted) return;

    final targetPreset = savedPreset == null
        ? ImageResizePreset.medium
        : ImageResizePreset.values.firstWhere(
            (p) => p.name == savedPreset,
            orElse: () => ImageResizePreset.original,
          );

    // Compute target preset first — clears the spinner as soon as possible
    final targetBytes = await _resizeOne(bytes, targetPreset);
    if (!mounted) return;
    setState(() {
      _currentPreset = targetPreset;
      _pendingFile = (bytes: targetBytes, name: name, mimeType: mimeType);
      _presetBytes = {targetPreset: targetBytes};
    });

    // Then compute remaining presets (needed only for the size modal)
    final allBytes = await _resizeAll(bytes);
    if (!mounted) return;
    setState(() => _presetBytes = allBytes);

    if (savedPreset == null) {
      final originalSize = allBytes[ImageResizePreset.original]!.length;
      final hasSmaller = ImageResizePreset.values.any((p) =>
          p != ImageResizePreset.original &&
          allBytes[p]!.length < originalSize);
      if (hasSmaller) await _showImageSizeModal();
    }
  }

  static Map<ImageResizePreset, Uint8List> _computeAllPresets(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return {for (final p in ImageResizePreset.values) p: bytes};
    }
    Uint8List resize(int maxDim) {
      final maxOrig =
          decoded.width > decoded.height ? decoded.width : decoded.height;
      if (maxOrig <= maxDim) return bytes;
      final scale = maxDim / maxOrig;
      final resized = img.copyResize(
        decoded,
        width: (decoded.width * scale).round(),
        height: (decoded.height * scale).round(),
      );
      return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
    }

    return {
      ImageResizePreset.small: resize(800),
      ImageResizePreset.medium: resize(1440),
      ImageResizePreset.large: resize(2500),
      ImageResizePreset.original: bytes,
    };
  }

  static Uint8List _computePreset((Uint8List, ImageResizePreset) args) {
    final (bytes, preset) = args;
    if (preset == ImageResizePreset.original) return bytes;
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final maxDim = switch (preset) {
      ImageResizePreset.small => 800,
      ImageResizePreset.medium => 1440,
      ImageResizePreset.large => 2500,
      ImageResizePreset.original => 0,
    };
    final maxOrig =
        decoded.width > decoded.height ? decoded.width : decoded.height;
    if (maxOrig <= maxDim) return bytes;
    final scale = maxDim / maxOrig;
    final resized = img.copyResize(
      decoded,
      width: (decoded.width * scale).round(),
      height: (decoded.height * scale).round(),
    );
    return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
  }

  // True on platforms with hardware-accelerated image compression
  bool get _useNativeResize =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  static int _presetMaxDim(ImageResizePreset preset) => switch (preset) {
        ImageResizePreset.small => 800,
        ImageResizePreset.medium => 1440,
        ImageResizePreset.large => 2500,
        ImageResizePreset.original => 0,
      };

  Future<Uint8List> _resizeOne(
      Uint8List bytes, ImageResizePreset preset) async {
    if (preset == ImageResizePreset.original) return bytes;
    final maxDim = _presetMaxDim(preset);
    if (kIsWeb) return resizeImageForWeb(bytes, maxDim);
    if (_useNativeResize) {
      return await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: maxDim,
        minHeight: maxDim,
        quality: 85,
      );
    }
    return compute(_computePreset, (bytes, preset));
  }

  Future<Map<ImageResizePreset, Uint8List>> _resizeAll(Uint8List bytes) async {
    if (kIsWeb) {
      final results = await Future.wait([
        resizeImageForWeb(bytes, 800),
        resizeImageForWeb(bytes, 1440),
        resizeImageForWeb(bytes, 2500),
      ]);
      return {
        ImageResizePreset.small: results[0],
        ImageResizePreset.medium: results[1],
        ImageResizePreset.large: results[2],
        ImageResizePreset.original: bytes,
      };
    }
    if (_useNativeResize) {
      // Native threads run in parallel on multi-core CPUs
      final results = await Future.wait([
        FlutterImageCompress.compressWithList(bytes,
            minWidth: 800, minHeight: 800, quality: 85),
        FlutterImageCompress.compressWithList(bytes,
            minWidth: 1440, minHeight: 1440, quality: 85),
        FlutterImageCompress.compressWithList(bytes,
            minWidth: 2500, minHeight: 2500, quality: 85),
      ]);
      return {
        ImageResizePreset.small: results[0],
        ImageResizePreset.medium: results[1],
        ImageResizePreset.large: results[2],
        ImageResizePreset.original: bytes,
      };
    }
    return compute(_computeAllPresets, bytes);
  }

  void _applyPreset(ImageResizePreset preset, {bool save = true}) {
    final all = _presetBytes;
    final file = _pendingFile;
    if (all == null || file == null) return;
    setState(() {
      _currentPreset = preset;
      _pendingFile =
          (bytes: all[preset]!, name: file.name, mimeType: file.mimeType);
    });
    if (save) AuthService.setImageResizePreset(preset.name);
  }

  Future<void> _showImageSizeModal() async {
    final original = _originalImageBytes;
    if (original == null || !mounted) return;
    final all = _presetBytes;
    if (all == null || all.length < ImageResizePreset.values.length) return;
    final sizes = all.map((k, v) => MapEntry(k, v.length));

    // Hide presets that are larger than or equal to the original file size
    final originalSize = sizes[ImageResizePreset.original]!;
    final visiblePresets = ImageResizePreset.values
        .where(
            (p) => p == ImageResizePreset.original || sizes[p]! < originalSize)
        .toList();

    var selected = visiblePresets.contains(_currentPreset)
        ? _currentPreset
        : visiblePresets.last;
    final confirmed = await showDialog<ImageResizePreset>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Dialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(ctx).size.height * 0.35,
                    ),
                    child: Container(
                      width: double.infinity,
                      color: const Color(0xFFEEEEEE),
                      child: Image.memory(
                        original,
                        fit: BoxFit.contain,
                        semanticLabel: 'Image preview',
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                ...() {
                  Widget presetTile(ImageResizePreset preset) {
                    final isSelected = selected == preset;
                    return Expanded(
                      child: Semantics(
                        label:
                            '${preset.label}, ${_formatFileSize(sizes[preset]!)}',
                        button: true,
                        selected: isSelected,
                        child: GestureDetector(
                          onTap: () => setDialogState(() => selected = preset),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSelected
                                    ? accent
                                    : const Color(0xFFE0E0E0),
                                width: isSelected ? 2 : 1,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Column(
                                children: [
                                  Text(
                                    preset.label,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500),
                                  ),
                                  Text(
                                    _formatFileSize(sizes[preset]!),
                                    style: TextStyle(
                                        fontSize: 12, color: Colors.grey[600]),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }

                  final rows = <Widget>[];
                  for (int i = 0; i < visiblePresets.length; i += 2) {
                    if (rows.isNotEmpty) rows.add(const SizedBox(height: 12));
                    rows.add(Row(children: [
                      presetTile(visiblePresets[i]),
                      const SizedBox(width: 12),
                      if (i + 1 < visiblePresets.length)
                        presetTile(visiblePresets[i + 1])
                      else
                        const Expanded(child: SizedBox()),
                    ]));
                  }
                  return rows;
                }(),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, selected),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      elevation: 0,
                    ),
                    child: const Text('OK', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed != null && mounted) {
      _applyPreset(confirmed);
    }
  }

  void _editLastNote() {
    final notes = NoteCache.instance.notifier.value;
    for (int i = notes.length - 1; i >= 0; i--) {
      if (notes[i].error == null) {
        _startEdit(notes[i]);
        return;
      }
    }
  }

  void _startEdit(DecryptedNote note) {
    setState(() {
      _editingNoteId = note.id;
      _editingNote = note;
    });
    final initialText = note.kind == NoteKind.file
        ? (note.attachment?.comment ?? '')
        : note.text;
    _textController.text = initialText;
    _textController.selection =
        TextSelection.collapsed(offset: initialText.length);
    // Defer so the overlay is fully removed before requesting focus (opens keyboard on mobile)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocusNode.requestFocus();
    });
  }

  void _cancelEdit() {
    setState(() {
      _editingNoteId = null;
      _editingNote = null;
    });
    _textController.clear();
    _inputFocusNode.unfocus();
  }

  Future<void> _confirmEdit() async {
    final text = _textController.text.trim();
    final id = _editingNoteId;
    final isFileNote = _editingNote?.kind == NoteKind.file;
    if ((!isFileNote && text.isEmpty) || id == null || _sending) return;
    setState(() {
      _editingNoteId = null;
      _editingNote = null;
      _sending = true;
    });
    _textController.clear();
    _inputFocusNode.unfocus();
    await NoteCache.instance.update(id, text);
    if (mounted) {
      setState(() => _sending = false);
      final notes = NoteCache.instance.notifier.value;
      if (notes.isNotEmpty && notes.last.id == id) _scrollToBottom();
    }
  }

  void _showProfileSheet() {
    final npub = Nip19.encodePubKey(widget.user.pubkey);
    var localAdditional = List<String>.from(widget.additionalRelays);
    // kind:10063 servers fetched from relay (read-only); snapshot at open time
    final kind10063Servers = NoteCache.instance.blossomServers
        .where((s) => !widget.blossomServers.contains(s))
        .toList();
    var localBlossom = List<String>.from(widget.blossomServers);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SingleChildScrollView(
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
                        style:
                            const TextStyle(color: Colors.white, fontSize: 32),
                      )
                    : null,
              ),
              const SizedBox(height: 16),
              Text(
                widget.user.name,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
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
              if (localAdditional.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'Additional write relays',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 8),
                ...localAdditional.map(
                  (url) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              url,
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey[700],
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Semantics(
                            label: 'Remove relay',
                            button: true,
                            child: GestureDetector(
                              onTap: () {
                                final updated = localAdditional.toList()
                                  ..remove(url);
                                setSheetState(() => localAdditional = updated);
                                widget.onAdditionalRelaysChanged(updated);
                              },
                              child: const Icon(Icons.close,
                                  size: 16, color: accent),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              if (kind10063Servers.isNotEmpty || localBlossom.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'Blossom servers',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 8),
                // kind:10063 servers are read-only (no X button)
                ...kind10063Servers.map(
                  (url) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      url,
                      style: TextStyle(fontSize: 14, color: Colors.grey[700]),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                // User-saved fallback servers are removable
                ...localBlossom.map(
                  (url) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              url,
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey[700],
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Semantics(
                            label: 'Remove Blossom server',
                            button: true,
                            child: GestureDetector(
                              onTap: () {
                                final updated = localBlossom.toList()
                                  ..remove(url);
                                setSheetState(() => localBlossom = updated);
                                widget.onBlossomServersChanged(updated);
                              },
                              child: const Icon(Icons.close,
                                  size: 16, color: accent),
                            ),
                          ),
                        ],
                      ),
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
      ),
    );
  }

  Future<String> _readVersion() async {
    final yaml = await rootBundle.loadString('pubspec.yaml');
    final match =
        RegExp(r'^version:\s+(\S+)', multiLine: true).firstMatch(yaml);
    return match?.group(1) ?? '';
  }

  void _showAbout() async {
    final version = await _readVersion();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Manent',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'A private, encrypted space for your notes and files — built on Nostr',
              style: TextStyle(height: 1.3),
            ),
            const SizedBox(height: 4),
            if (version.isNotEmpty)
              Text('v.$version', style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => launchUrl(
                Uri.parse('https://njump.me/dtonon.com'),
                mode: LaunchMode.externalApplication,
              ),
              child: const Text.rich(
                TextSpan(
                  text: 'by ',
                  children: [
                    TextSpan(
                      text: 'dtonon',
                      style: TextStyle(
                        color: Colors.blue,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Source code:'),
            const SizedBox(height: 2),
            GestureDetector(
              onTap: () => launchUrl(
                Uri.parse('https://github.com/dtonon/manent'),
                mode: LaunchMode.externalApplication,
              ),
              child: const Text(
                'https://github.com/dtonon/manent',
                style: TextStyle(
                  color: Colors.blue,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
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
          canPop: !inSelection && _editingNoteId == null,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              if (_editingNoteId != null) {
                _cancelEdit();
              } else {
                _NoteCardState._selectionModeId.value = null;
              }
            }
          },
          child: Scaffold(
            backgroundColor: background,
            appBar: inSelection
                ? _buildSelectionAppBar()
                : manentAppBar(
                    onTitleTap: _showAbout,
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
                    child: ValueListenableBuilder<bool>(
                      valueListenable: NoteCache.instance.loading,
                      builder: (context, isLoading, _) {
                        if (isLoading) {
                          return Center(
                            child: Semantics(
                              label: 'Loading notes',
                              child: const CircularProgressIndicator(
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(accent),
                              ),
                            ),
                          );
                        }
                        return ValueListenableBuilder<List<DecryptedNote>>(
                          valueListenable: NoteCache.instance.notifier,
                          builder: (context, notes, _) {
                            if (notes.isEmpty) {
                              return const Center(
                                child: Text(
                                  'No notes yet',
                                  style: TextStyle(
                                      color: Colors.grey, fontSize: 14),
                                ),
                              );
                            }
                            return ListView(
                              controller: _scrollController,
                              padding: const EdgeInsets.all(16),
                              children: _buildNoteItems(notes),
                            );
                          },
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
      items.add(_NoteCard(note: note, onEdit: () => _startEdit(note)));
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
    final bottomInset = isMobile ? MediaQuery.of(context).padding.bottom : 0.0;
    final maxHeight = MediaQuery.of(context).size.height * 0.5;
    final isEditing = _editingNoteId != null;
    final hasPendingFile = _pendingFile != null;
    final editingFileAttachment =
        _editingNote?.kind == NoteKind.file ? _editingNote!.attachment : null;

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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isEditing)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 12, 35, 0),
                    child: Row(
                      children: [
                        const Icon(Icons.edit, size: 14, color: Colors.grey),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text(
                            'Editing',
                            style: TextStyle(fontSize: 13, color: Colors.grey),
                          ),
                        ),
                        Semantics(
                          label: 'Cancel editing',
                          button: true,
                          child: GestureDetector(
                            onTap: _cancelEdit,
                            child: const Icon(Icons.close,
                                size: 18, color: Colors.grey),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (editingFileAttachment != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 6, 35, 0),
                    child: Row(
                      children: [
                        const Icon(Icons.attach_file,
                            size: 14, color: Colors.grey),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            editingFileAttachment.filename,
                            style: const TextStyle(
                                fontSize: 13, color: Colors.grey),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (hasPendingFile)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 18, 35, 0),
                    child: Row(
                      children: [
                        if (rasterImageMimeTypes
                            .contains(_pendingFile!.mimeType)) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.memory(
                              _pendingFile!.bytes,
                              width: 36,
                              height: 36,
                              fit: BoxFit.cover,
                              semanticLabel: _pendingFile!.name,
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: rasterImageMimeTypes
                                  .contains(_pendingFile!.mimeType)
                              ? Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        _presetBytes != null
                                            ? '${_currentPreset.label} — ${_formatFileSize(_pendingFile!.bytes.length)}'
                                            : '${_currentPreset.label} — ',
                                        style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.black87),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (_presetBytes == null)
                                      const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  Colors.black45),
                                        ),
                                      ),
                                  ],
                                )
                              : Text(
                                  '${_pendingFile!.name} — ${_formatFileSize(_pendingFile!.bytes.length)}',
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.black87),
                                  overflow: TextOverflow.ellipsis,
                                ),
                        ),
                        if (rasterImageMimeTypes
                                .contains(_pendingFile!.mimeType) &&
                            () {
                              final pb = _presetBytes;
                              if (pb == null ||
                                  pb.length < ImageResizePreset.values.length) {
                                return false;
                              }
                              final origSize =
                                  pb[ImageResizePreset.original]!.length;
                              return ImageResizePreset.values.any((p) =>
                                  p != ImageResizePreset.original &&
                                  pb[p]!.length < origSize);
                            }()) ...[
                          const SizedBox(width: 20),
                          Semantics(
                            label: 'Image size settings',
                            button: true,
                            child: GestureDetector(
                              onTap: _showImageSizeModal,
                              child: Icon(Icons.tune,
                                  size: 24, color: Colors.grey[400]),
                            ),
                          ),
                        ],
                        const SizedBox(width: 20),
                        Semantics(
                          label: 'Remove attachment',
                          button: true,
                          child: GestureDetector(
                            onTap: () => setState(() {
                              _pendingFile = null;
                              _originalImageBytes = null;
                              _presetBytes = null;
                            }),
                            child: Icon(Icons.close,
                                size: 24, color: Colors.grey[400]),
                          ),
                        ),
                      ],
                    ),
                  ),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 18),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: CallbackShortcuts(
                            bindings: <ShortcutActivator, VoidCallback>{
                              const SingleActivator(LogicalKeyboardKey.enter,
                                      control: true):
                                  () => _editingNoteId != null
                                      ? _confirmEdit()
                                      : _sendNote(),
                              const SingleActivator(LogicalKeyboardKey.enter,
                                      meta: true):
                                  () => _editingNoteId != null
                                      ? _confirmEdit()
                                      : _sendNote(),
                            },
                            child: TextField(
                              controller: _textController,
                              focusNode: _inputFocusNode,
                              maxLines: null,
                              keyboardType: TextInputType.multiline,
                              textInputAction: TextInputAction.newline,
                              decoration: InputDecoration(
                                hintText: hasPendingFile ||
                                        editingFileAttachment != null
                                    ? 'Add a comment...'
                                    : 'Memo...',
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                                hintStyle: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 14,
                                ),
                              ),
                              style: const TextStyle(fontSize: 14, height: 1.3),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Attach icon or send button — mutually exclusive
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _textController,
                          builder: (context, value, _) {
                            final hasText = value.text.trim().isNotEmpty;
                            final canSend = hasPendingFile ||
                                hasText ||
                                editingFileAttachment != null;
                            if (canSend) {
                              return Semantics(
                                label: isEditing ? 'Confirm edit' : 'Send',
                                button: true,
                                child: GestureDetector(
                                  onTap: isEditing ? _confirmEdit : _sendNote,
                                  child: _sending
                                      ? const SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                    accent),
                                          ),
                                        )
                                      : Icon(
                                          isEditing
                                              ? Icons.check_circle_outline
                                              : Icons.send,
                                          color: accent,
                                        ),
                                ),
                              );
                            }
                            if (!isEditing) {
                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (!_NoteCardState._isDesktopOrWeb) ...[
                                    Semantics(
                                      label: 'Take photo',
                                      button: true,
                                      child: GestureDetector(
                                        onTap: _takePhoto,
                                        child: Padding(
                                          padding:
                                              const EdgeInsets.only(right: 20),
                                          child: Icon(Icons.camera_alt,
                                              size: 24,
                                              color: Colors.grey[400]),
                                        ),
                                      ),
                                    ),
                                  ],
                                  Semantics(
                                    label: 'Attach file',
                                    button: true,
                                    child: GestureDetector(
                                      onTap: _pickFile,
                                      child: Padding(
                                        padding:
                                            const EdgeInsets.only(right: 0),
                                        child: Transform.rotate(
                                          angle: -0.55,
                                          child: Icon(Icons.attachment,
                                              size: 24,
                                              color: Colors.grey[400]),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                      ],
                    ),
                  ),
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
      ],
    );
  }

  @override
  void dispose() {
    if (kIsWeb) BrowserContextMenu.enableContextMenu();
    _NoteCardState._selectionModeId.value = null;
    NoteCache.instance.notifier.removeListener(_onNotesChanged);
    NoteCache.instance.promptFallbackRelays
        .removeListener(_onFallbackRelaysPrompt);
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _textController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }
}

class _NoteCard extends StatefulWidget {
  final DecryptedNote note;
  final VoidCallback? onEdit;

  const _NoteCard({required this.note, this.onEdit});

  @override
  State<_NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends State<_NoteCard> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive =>
      widget.note.kind == NoteKind.file && widget.note.attachment?.isImage == true;
  static final _activeMenuId = ValueNotifier<String?>(null);
  static final _selectionModeId = ValueNotifier<String?>(null);
  // Reused across image-viewer opens to avoid cold-starting a new Flutter engine each time
  static WindowController? _imageViewerWindow;
  static StreamSubscription<void>? _windowsChangedSub;

  String? _desktopSelectedContent;
  // Captured in onSecondaryTapDown before SelectionArea word-selects on right-click
  String? _capturedSelectionOnRightClick;
  final _selectionAreaKey = GlobalKey<SelectionAreaState>();

  bool _retrying = false;
  Offset _tapPosition = Offset.zero;
  Future<Uint8List?>? _imageBytesFuture;

  // Converts a global position to the overlay's local coordinate space.
  // Needed on web where the app is in a centered max-width container,
  // so the Overlay is offset from the Flutter view origin.
  static Offset _toOverlayLocal(BuildContext context, Offset globalPosition) {
    final box = Overlay.of(context).context.findRenderObject()! as RenderBox;
    return box.globalToLocal(globalPosition);
  }

  // Cached to keep the same TextSpan instance across rebuilds so SelectableText
  // doesn't reset its selection when _activeMenuId / _selectionModeId change.
  late TextSpan _textSpan;
  final List<TapGestureRecognizer> _urlRecognizers = [];

  static final _urlRegex = RegExp(
    r'https?://[^\s]+|[a-zA-Z0-9][a-zA-Z0-9\-]*\.[a-zA-Z]{2,}(?:/[^\s]*)?',
    caseSensitive: false,
  );

  @override
  void initState() {
    super.initState();
    _rebuildTextSpan();
    _initImageFuture();
  }

  void _initImageFuture() {
    final attachment = widget.note.attachment;
    if (widget.note.kind == NoteKind.file && attachment?.isImage == true) {
      _imageBytesFuture = NoteCache.instance.getFileBytes(attachment!);
    }
  }

  @override
  void didUpdateWidget(_NoteCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.note.text != widget.note.text) {
      _disposeRecognizers();
      _rebuildTextSpan();
    }
    // Reset future if attachment identity changes (e.g. note replaced after sync)
    if (oldWidget.note.attachment?.sha256 != widget.note.attachment?.sha256) {
      _initImageFuture();
    }
  }

  void _rebuildTextSpan() {
    const baseStyle =
        TextStyle(fontSize: 14, height: 1.3, color: Colors.black87);
    _textSpan = TextSpan(
      children: _buildTextSpans(widget.note.text, baseStyle),
    );
  }

  void _disposeRecognizers() {
    for (final r in _urlRecognizers) {
      r.dispose();
    }
    _urlRecognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  static bool get _isDesktopOrWeb {
    if (kIsWeb) {
      // Mobile browsers (iOS/Android) get mobile behavior
      return defaultTargetPlatform != TargetPlatform.iOS &&
          defaultTargetPlatform != TargetPlatform.android;
    }
    return defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

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

  void _showJsonModal(DecryptedNote note) {
    final json = note.toDebugJson();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Expanded(child: Text('JSON', style: TextStyle(fontSize: 16))),
            IconButton(
              icon: const Icon(Icons.copy, size: 20),
              tooltip: 'Copy',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: json));
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
        titlePadding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              json,
              style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  height: 1.5,
                  color: Colors.black87),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveFile() async {
    final attachment = widget.note.attachment;
    if (attachment == null) return;
    final bytes = await NoteCache.instance.getFileBytes(attachment);
    if (bytes == null || !mounted) return;
    if (kIsWeb) {
      await downloadOnWeb(attachment.filename, bytes);
    } else if (_isDesktopOrWeb) {
      // Desktop: get path from picker, write manually
      final path = await FilePicker.platform.saveFile(
        fileName: attachment.filename,
      );
      if (path != null) {
        await File(path).writeAsBytes(bytes);
      }
    } else {
      // Mobile: native save dialog via ACTION_CREATE_DOCUMENT
      await FilePicker.platform.saveFile(
        fileName: attachment.filename,
        bytes: bytes,
      );
    }
  }

  Future<void> _shareFile() async {
    final attachment = widget.note.attachment;
    if (attachment == null) return;
    final bytes = await NoteCache.instance.getFileBytes(attachment);
    if (bytes == null) return;
    await Share.shareXFiles(
      [XFile.fromData(bytes, mimeType: attachment.mimeType)],
      fileNameOverrides: [attachment.filename],
    );
  }

  Future<void> _showContextMenu() async {
    _activeMenuId.value = widget.note.id;

    // Use captured selection (grabbed before right-click word-selection fired)
    final selectedText =
        _isDesktopOrWeb ? _capturedSelectionOnRightClick : null;
    final hasSelection = selectedText != null && selectedText.isNotEmpty;

    final completer = Completer<String?>();
    OverlayEntry? entry;

    void dismiss([String? value]) {
      entry?.remove();
      entry = null;
      completer.complete(value);
    }

    final isFileNote = widget.note.kind == NoteKind.file;
    entry = OverlayEntry(
      builder: (_) => ExcludeFocus(
        child: _NoteMenuOverlay(
          tapPosition: _tapPosition,
          isDesktopOrWeb: _isDesktopOrWeb,
          onSelect: dismiss,
          showRetry: widget.note.error != null,
          showRetrySync: widget.note.syncStatus == SyncStatus.failed ||
              (widget.note.syncStatus == SyncStatus.pending &&
                  widget.note.nostrId == null),
          showSelectText: !_isDesktopOrWeb && !isFileNote,
          showEdit: widget.note.error == null && !isFileNote,
          showEditComment: isFileNote && widget.note.error == null,
          showSave: isFileNote,
          showShare: isFileNote && !_isDesktopOrWeb,
          showCopyComment:
              isFileNote && widget.note.attachment?.comment != null,
          showDebugJson: kDebugMode,
          editedAt: widget.note.editedAt,
          copyLabel: isFileNote
              ? (widget.note.attachment?.isImage == true
                  ? null
                  : 'Copy filename')
              : (hasSelection ? 'Copy selected text' : 'Copy text'),
        ),
      ),
    );

    Overlay.of(context).insert(entry!);
    final result = await completer.future;

    _activeMenuId.value = null;

    if (result == 'show_json') {
      if (mounted) _showJsonModal(widget.note);
    } else if (result == 'save') {
      _saveFile();
    } else if (result == 'share') {
      _shareFile();
    } else if (result == 'copy_comment') {
      await Clipboard.setData(
          ClipboardData(text: widget.note.attachment?.comment ?? ''));
    } else if (result == 'edit' || result == 'edit_comment') {
      widget.onEdit?.call();
    } else if (result == 'retry_sync') {
      NoteCache.instance.retrySync(widget.note.id);
    } else if (result == 'copy') {
      final textToCopy = widget.note.kind == NoteKind.file
          ? (widget.note.attachment?.filename ?? '')
          : (hasSelection ? selectedText : widget.note.text);
      await Clipboard.setData(ClipboardData(text: textToCopy));
    } else if (result == 'select_text') {
      _selectionModeId.value = widget.note.id;
    } else if (result == 'retry') {
      _retry();
    } else if (result == 'delete') {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.enter, control: true):
                () => Navigator.pop(ctx, true),
            const SingleActivator(LogicalKeyboardKey.enter, meta: true): () =>
                Navigator.pop(ctx, true),
          },
          child: Focus(
            autofocus: true,
            child: AlertDialog(
              title: const Text('Delete note'),
              content:
                  const Text('Are you sure you want to delete this message?'),
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
          ),
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

      final recognizer = TapGestureRecognizer()
        ..onTap = () =>
            launchUrl(Uri.parse(fullUrl), mode: LaunchMode.platformDefault);
      _urlRecognizers.add(recognizer);
      spans.add(TextSpan(
        text: url,
        style: baseStyle.copyWith(
          color: accent,
          decoration: TextDecoration.underline,
          decorationColor: accent,
        ),
        recognizer: recognizer,
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
    super.build(context);
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
        void Function(LongPressStartDetails)? onLongPressStart;

        final isFileNote =
            widget.note.kind == NoteKind.file && widget.note.error == null;
        final isFileImage = isFileNote && widget.note.attachment?.isImage == true;

        if (isActiveSelection) {
          // All null — SelectableText handles everything
        } else if (selectionId != null) {
          // Non-active card: tap exits selection mode
          if (!_isDesktopOrWeb) onTap = () => _selectionModeId.value = null;
        } else {
          // Normal mode
          if (!_isDesktopOrWeb) {
            onTapDown = (d) =>
                _tapPosition = _toOverlayLocal(context, d.globalPosition);
            if (isFileImage) {
              onTap = () => _openImageViewer(context);
              onLongPressStart = (d) {
                _tapPosition = _toOverlayLocal(context, d.globalPosition);
                _showContextMenu();
              };
            } else {
              onTap = _showContextMenu;
            }
          }
          if (_isDesktopOrWeb) {
            // File notes (non-image): left-click saves the file directly
            final isFileNonImage = isFileNote && !isFileImage;
            onTap = isFileNonImage
                ? () => _saveFile()
                : isFileImage
                    ? () => _openImageViewer(context)
                    : () {
                        _desktopSelectedContent = null;
                        _capturedSelectionOnRightClick = null;
                        _selectionAreaKey.currentState?.selectableRegion
                            .clearSelection();
                      };
            onSecondaryTapDown = (d) {
              _tapPosition = _toOverlayLocal(context, d.globalPosition);
              // Capture before SelectionArea word-selects on right-click
              _capturedSelectionOnRightClick = _desktopSelectedContent;
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
          onLongPressStart: onLongPressStart,
          child: Container(
            // Image file notes use zero padding — the image fills the card
            padding: isFileImage ? EdgeInsets.zero : const EdgeInsets.all(16),
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

  Future<void> _openImageViewer(BuildContext context) async {
    final attachment = widget.note.attachment;
    if (attachment == null) return;

    // Native desktop: write decrypted bytes to a temp file, open in a new window.
    // The window is reused across clicks to avoid cold-starting a new Flutter engine.
    if (!kIsWeb && _isDesktopOrWeb) {
      final bytes = await NoteCache.instance.getFileBytes(attachment);
      if (bytes == null) return;
      final file = File(
          '${Directory.systemTemp.path}/manent_${attachment.filename}');
      await file.writeAsBytes(bytes);
      final args =
          jsonEncode({'path': file.path, 'filename': attachment.filename});
      final existing = _imageViewerWindow;
      if (existing != null) {
        try {
          await existing.invokeMethod('loadImage', args);
          return;
        } catch (_) {
          _imageViewerWindow = null;
          _windowsChangedSub?.cancel();
          _windowsChangedSub = null;
        }
      }
      final controller = await WindowController.create(
        WindowConfiguration(hiddenAtLaunch: true, arguments: args),
      );
      _imageViewerWindow = controller;
      _windowsChangedSub = onWindowsChanged.listen((_) async {
        final all = await WindowController.getAll();
        if (_imageViewerWindow != null &&
            !all.any((c) => c.windowId == _imageViewerWindow!.windowId)) {
          _imageViewerWindow = null;
          _windowsChangedSub?.cancel();
          _windowsChangedSub = null;
        }
      });
      return;
    }

    // Mobile / web browser: in-app full-screen viewer
    if (!mounted) return;
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (ctx, _, __) =>
            _MobileImageViewer(attachment: attachment),
        transitionDuration: const Duration(milliseconds: 200),
      ),
    );
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
    if (widget.note.kind == NoteKind.file && widget.note.error == null) {
      return _FileNoteContent(
        note: widget.note,
        imageBytesFuture: _imageBytesFuture,
        formatTime: _formatTime,
        buildSyncIcon: _buildSyncIcon,
        isDesktopOrWeb: _isDesktopOrWeb,
      );
    }

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

    final textSpan = _textSpan;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isDesktopOrWeb)
          DefaultSelectionStyle(
            selectionColor: textSelectionColor,
            child: SelectionArea(
              key: _selectionAreaKey,
              onSelectionChanged: (content) {
                final raw = content?.plainText.trim();
                _desktopSelectedContent =
                    (raw != null && raw.isNotEmpty) ? raw : null;
              },
              contextMenuBuilder: (_, __) => const SizedBox.shrink(),
              child: Text.rich(textSpan),
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

// Formats file size for display
String _formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _FileNoteContent extends StatelessWidget {
  final DecryptedNote note;
  final Future<Uint8List?>? imageBytesFuture;
  final String Function(DateTime) formatTime;
  final Widget Function() buildSyncIcon;
  final bool isDesktopOrWeb;

  const _FileNoteContent({
    required this.note,
    required this.imageBytesFuture,
    required this.formatTime,
    required this.buildSyncIcon,
    required this.isDesktopOrWeb,
  });

  @override
  Widget build(BuildContext context) {
    final attachment = note.attachment;
    if (attachment == null) return const SizedBox.shrink();

    if (attachment.isImage) {
      return _buildImageContent(attachment);
    }
    return _buildFileContent(attachment);
  }

  Widget _buildImageContent(NoteAttachment attachment) {
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          FutureBuilder<Uint8List?>(
            future: imageBytesFuture,
            builder: (ctx, snap) {
              if (snap.hasData && snap.data != null) {
                return Image.memory(
                  snap.data!,
                  fit: BoxFit.fitWidth,
                  width: double.infinity,
                  semanticLabel: attachment.filename,
                );
              }
              // Thumbhash placeholder while loading
              if (attachment.thumbhash != null) {
                return _ThumbhashImage(
                  thumbhash: attachment.thumbhash!,
                  filename: attachment.filename,
                );
              }
              return const AspectRatio(
                aspectRatio: 16 / 9,
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            },
          ),
          Positioned(
            bottom: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  buildSyncIcon(),
                  const SizedBox(width: 4),
                  Text(
                    formatTime(note.createdAt),
                    style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    if (attachment.comment == null) return image;
    final commentText = Text(
      attachment.comment!,
      style: const TextStyle(fontSize: 14, height: 1.3, color: Colors.black87),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        image,
        Padding(
          padding: const EdgeInsets.all(16),
          child: isDesktopOrWeb
              ? DefaultSelectionStyle(
                  selectionColor: textSelectionColor,
                  child: SelectionArea(
                    contextMenuBuilder: (_, __) => const SizedBox.shrink(),
                    child: commentText,
                  ),
                )
              : commentText,
        ),
      ],
    );
  }

  Widget _buildFileContent(NoteAttachment attachment) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: const Color(0xFF333333),
              child: Semantics(
                label: 'File: ${attachment.filename}',
                child: const Icon(Icons.insert_drive_file,
                    color: Colors.white, size: 20),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    attachment.filename,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _formatFileSize(attachment.size),
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                buildSyncIcon(),
                Text(
                  formatTime(note.createdAt),
                  style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                ),
              ],
            ),
          ],
        ),
        if (attachment.comment != null) ...[
          const SizedBox(height: 8),
          Builder(builder: (ctx) {
            final t = Text(
              attachment.comment!,
              style: const TextStyle(
                  fontSize: 14, height: 1.3, color: Colors.black87),
            );
            return isDesktopOrWeb
                ? DefaultSelectionStyle(
                    selectionColor: textSelectionColor,
                    child: SelectionArea(
                      contextMenuBuilder: (_, __) => const SizedBox.shrink(),
                      child: t,
                    ),
                  )
                : t;
          }),
        ],
      ],
    );
  }
}

class _ThumbhashImage extends StatefulWidget {
  final String thumbhash;
  final String filename;

  const _ThumbhashImage({required this.thumbhash, required this.filename});

  @override
  State<_ThumbhashImage> createState() => _ThumbhashImageState();
}

class _ThumbhashImageState extends State<_ThumbhashImage> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    try {
      final hashBytes = base64Decode(widget.thumbhash);
      final result = thumbHashToRGBA(hashBytes);
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        Uint8List.fromList(result.rgba),
        result.width,
        result.height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final img = await completer.future;
      if (mounted) setState(() => _image = img);
    } catch (_) {}
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_image == null) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Semantics(
      label: widget.filename,
      image: true,
      child: AspectRatio(
        aspectRatio: _image!.width / _image!.height,
        child: RawImage(
          image: _image,
          fit: BoxFit.fitWidth,
          width: double.infinity,
        ),
      ),
    );
  }
}

class _NoteMenuOverlay extends StatelessWidget {
  final Offset tapPosition;
  final bool isDesktopOrWeb;
  final void Function([String?]) onSelect;
  final bool showRetry;
  final bool showRetrySync;
  final bool showSelectText;
  final bool showEdit;
  final bool showEditComment;
  final DateTime? editedAt;
  // Null hides the copy action (e.g. image notes where filename copy is useless)
  final String? copyLabel;

  final bool showSave;
  final bool showShare;
  final bool showCopyComment;
  final bool showDebugJson;

  const _NoteMenuOverlay({
    required this.tapPosition,
    required this.isDesktopOrWeb,
    required this.onSelect,
    required this.showRetry,
    this.showRetrySync = false,
    this.showSelectText = false,
    this.showEdit = false,
    this.showEditComment = false,
    this.showSave = false,
    this.showShare = false,
    this.showCopyComment = false,
    this.showDebugJson = false,
    this.editedAt,
    this.copyLabel = 'Copy text',
  });

  String _formatEditedAt(DateTime dt) {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    final time =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return 'Edited ${dt.day} ${months[dt.month - 1]} $time';
  }

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
              isDesktopOrWeb: isDesktopOrWeb,
              keyboardHeight: MediaQuery.of(context).viewInsets.bottom),
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
                              style: TextStyle(
                                  fontSize: 14, color: Colors.black87),
                            ),
                          ),
                        ),
                        const Divider(height: 1, color: Color(0xFFE0E0E0)),
                      ],
                      if (showSave) ...[
                        InkWell(
                          onTap: () => onSelect('save'),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            child: Text(
                              'Save',
                              style: TextStyle(
                                  fontSize: 14, color: Colors.black87),
                            ),
                          ),
                        ),
                        const Divider(height: 1, color: Color(0xFFE0E0E0)),
                      ],
                      if (showShare) ...[
                        InkWell(
                          onTap: () => onSelect('share'),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            child: Text(
                              'Share',
                              style: TextStyle(
                                  fontSize: 14, color: Colors.black87),
                            ),
                          ),
                        ),
                        const Divider(height: 1, color: Color(0xFFE0E0E0)),
                      ],
                      if (showCopyComment) ...[
                        InkWell(
                          onTap: () => onSelect('copy_comment'),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            child: Text(
                              'Copy comment',
                              style: TextStyle(
                                  fontSize: 14, color: Colors.black87),
                            ),
                          ),
                        ),
                        const Divider(height: 1, color: Color(0xFFE0E0E0)),
                      ],
                      if (copyLabel != null) ...[
                        InkWell(
                          onTap: () => onSelect('copy'),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            child: Text(
                              copyLabel!,
                              style: const TextStyle(
                                  fontSize: 14, color: Colors.black87),
                            ),
                          ),
                        ),
                      ],
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
                      if (showEdit) ...[
                        const Divider(height: 1, color: Color(0xFFE0E0E0)),
                        InkWell(
                          onTap: () => onSelect('edit'),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            child: Text(
                              'Edit',
                              style: TextStyle(
                                  fontSize: 14, color: Colors.black87),
                            ),
                          ),
                        ),
                      ],
                      if (showEditComment) ...[
                        const Divider(height: 1, color: Color(0xFFE0E0E0)),
                        InkWell(
                          onTap: () => onSelect('edit_comment'),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            child: Text(
                              'Edit comment',
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
                      if (showDebugJson) ...[
                        const Divider(height: 1, color: Color(0xFFE0E0E0)),
                        InkWell(
                          onTap: () => onSelect('show_json'),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            child: Text(
                              'Show raw data',
                              style: TextStyle(
                                  fontSize: 14, color: Colors.black54),
                            ),
                          ),
                        ),
                      ],
                      if (editedAt != null) ...[
                        const Divider(height: 1, color: Color(0xFFE0E0E0)),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          child: Text(
                            _formatEditedAt(editedAt!),
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey[500]),
                          ),
                        ),
                      ],
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
  final double keyboardHeight;

  const _MenuPositionDelegate(this.tapPosition,
      {required this.isDesktopOrWeb, this.keyboardHeight = 0});

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(minWidth: 200, maxWidth: constraints.maxWidth - 32);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double x;
    if (isDesktopOrWeb) {
      x = tapPosition.dx.clamp(8.0, size.width - childSize.width - 8.0);
    } else {
      // Pin to the opposite edge so the finger never covers the menu
      if (tapPosition.dx > size.width / 2) {
        x = 26.0;
      } else {
        x = size.width - childSize.width - 26.0;
      }
    }
    // Clamp above the keyboard when it's open
    final double bottomLimit =
        size.height - keyboardHeight - childSize.height - 48.0;
    final double y = (tapPosition.dy + 4).clamp(48.0, bottomLimit);
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuPositionDelegate old) =>
      old.tapPosition != tapPosition ||
      old.isDesktopOrWeb != isDesktopOrWeb ||
      old.keyboardHeight != keyboardHeight;
}

class _MobileImageViewer extends StatefulWidget {
  final NoteAttachment attachment;

  const _MobileImageViewer({required this.attachment});

  @override
  State<_MobileImageViewer> createState() => _MobileImageViewerState();
}

class _MobileImageViewerState extends State<_MobileImageViewer>
    with SingleTickerProviderStateMixin {
  final _transformController = TransformationController();
  late final AnimationController _animController;
  Animation<Matrix4>? _animation;
  Offset _doubleTapPosition = Offset.zero;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..addListener(() {
        if (_animation != null) {
          _transformController.value = _animation!.value;
        }
      });
  }

  @override
  void dispose() {
    _transformController.dispose();
    _animController.dispose();
    super.dispose();
  }

  void _onDoubleTap() {
    final Matrix4 target;
    if (_transformController.value.getMaxScaleOnAxis() > 1.1) {
      target = Matrix4.identity();
    } else {
      final size = MediaQuery.of(context).size;
      final tx = size.width / 2 - 3 * _doubleTapPosition.dx;
      final ty = size.height / 2 - 3 * _doubleTapPosition.dy;
      target = Matrix4.identity()
        ..translateByDouble(tx, ty, 0, 1)
        ..scaleByDouble(3.0, 3.0, 1.0, 1.0);
    }
    _animation = Matrix4Tween(
      begin: _transformController.value,
      end: target,
    ).animate(
        CurvedAnimation(parent: _animController, curve: Curves.easeInOut));
    _animController
      ..reset()
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
        children: [
          FutureBuilder<Uint8List?>(
            future: NoteCache.instance.getFileBytes(widget.attachment),
            builder: (ctx, snap) {
              if (snap.hasData && snap.data != null) {
                return GestureDetector(
                  onDoubleTapDown: (d) =>
                      _doubleTapPosition = d.localPosition,
                  onDoubleTap: _onDoubleTap,
                  child: InteractiveViewer(
                    transformationController: _transformController,
                    minScale: 0.5,
                    maxScale: 10.0,
                    child: Center(
                      child: Image.memory(
                        snap.data!,
                        fit: BoxFit.contain,
                        semanticLabel: widget.attachment.filename,
                      ),
                    ),
                  ),
                );
              }
              return const Center(
                child: CircularProgressIndicator(
                  valueColor:
                      AlwaysStoppedAnimation<Color>(Colors.white54),
                ),
              );
            },
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 16,
            child: Semantics(
              label: 'Close image viewer',
              button: true,
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(8),
                  child: const Icon(Icons.close,
                      color: Colors.white, size: 24),
                ),
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }
}
