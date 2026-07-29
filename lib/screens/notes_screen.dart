import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;

import 'package:crop_your_image/crop_your_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:share_plus/share_plus.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart';
import 'package:thumbhash/thumbhash.dart' hide Image;
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/web_download.dart';
import '../utils/web_image_resize.dart';
import '../utils/video_thumb.dart';

import 'package:ndk/ndk.dart';

import '../auth/auth_state.dart';
import '../auth/relay_constants.dart';
import '../blossom/blossom_constants.dart';
import '../notes/note.dart';
import '../notes/note_attachment.dart';
import '../notes/note_cache.dart';
import '../notes/sync_diagnostics.dart';
import '../theme.dart';
import '../widgets/gif_player.dart';
import '../widgets/inline_web_video.dart';
import '../widgets/manent_app_bar.dart';
import '../widgets/middle_click_paste.dart';
import '../widgets/media_kit_video_screen.dart';
import '../widgets/video_player_screen.dart';

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
  // The list is always reverse:true (newest at index 0 = visual bottom). This
  // tracks whether the user is currently near the bottom (pixels ≈ 0), used to
  // pin new notes and toggle the scroll-to-bottom button.
  bool _atBottom = true;
  bool _showScrollToBottom = false;
  static const _bottomThreshold = 50.0;
  String? _newestNoteId;
  DateTime _lastInteractionTime = DateTime.now();
  StreamSubscription? _sharingMediaSub;
  static const _processTextChannel = MethodChannel('manent/process_text');
  String? _editingNoteId;
  DecryptedNote? _editingNote;
  // True while a file is being dragged over the window
  bool _dragging = false;
  // Pending file selected by user, cleared after send
  ({Uint8List bytes, String name, String mimeType})? _pendingFile;
  // Original image bytes before any resize (null for non-image files)
  Uint8List? _originalImageBytes;
  ImageResizePreset _currentPreset = ImageResizePreset.original;
  // Encoded bytes per preset, computed in background after image pick
  Map<ImageResizePreset, Uint8List>? _presetBytes;
  // Guards against opening the crop editor twice on a rapid double-tap
  bool _openingEditor = false;

  @override
  void initState() {
    super.initState();
    NoteCache.instance.notifier.addListener(_onNotesChanged);
    _textController.addListener(() => _lastInteractionTime = DateTime.now());
    NoteCache.instance.promptFallbackRelays
        .addListener(_onFallbackRelaysPrompt);
    if (NoteCache.instance.promptFallbackRelays.value) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _onFallbackRelaysPrompt());
    }
    NoteCache.instance.promptFallbackBlossom
        .addListener(_onFallbackBlossomPrompt);
    final initialNotes = NoteCache.instance.notifier.value;
    _newestNoteId = initialNotes.isEmpty ? null : initialNotes.last.id;
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
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      _initSharingIntent();
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _initProcessText();
    }
  }

  bool _onHardwareKey(KeyEvent event) {
    if (!mounted) return false;
    if (event is! KeyDownEvent) return false;
    // Paste from clipboard — works even when the input is unfocused, but not
    // while editing (there the paste is a plain text edit).
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isMetaPressed ||
            HardwareKeyboard.instance.isControlPressed) &&
        _editingNoteId == null) {
      // A focused text field pastes text itself; only take over when none is.
      // The focused node belongs to the Focus widget *inside* EditableText,
      // so the check must look up the tree.
      final focusContext = FocusManager.instance.primaryFocus?.context;
      final focusedEditable = focusContext != null &&
          focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
      // Fire and forget; return false so a text paste still reaches the field
      _pasteFromClipboard(allowText: !focusedEditable);
      return false;
    }
    if (event.logicalKey != LogicalKeyboardKey.arrowUp) return false;
    if (_textController.text.isNotEmpty || _editingNoteId != null) return false;
    _editLastNote();
    return true;
  }

  Future<void> _pasteFromClipboard({required bool allowText}) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      if (allowText) {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        _appendToInput(data?.text);
      }
      return;
    }
    final reader = await clipboard.read();
    const candidates = <(SimpleFileFormat, String, String)>[
      (Formats.png, 'png', 'image/png'),
      (Formats.jpeg, 'jpg', 'image/jpeg'),
      (Formats.gif, 'gif', 'image/gif'),
      (Formats.webp, 'webp', 'image/webp'),
      (Formats.bmp, 'bmp', 'image/bmp'),
    ];
    for (final (format, ext, mimeType) in candidates) {
      if (!reader.canProvide(format)) continue;
      reader.getFile(format, (file) async {
        final bytes = await file.readAll();
        // State may have changed while reading (e.g. edit started)
        if (!mounted || _editingNoteId != null) return;
        final name = 'pasted-${DateTime.now().millisecondsSinceEpoch}.$ext';
        await _handleImagePicked(bytes, name, mimeType);
      });
      return;
    }
    if (!allowText) return;
    if (reader.canProvide(Formats.plainText)) {
      _appendToInput(await reader.readValue(Formats.plainText));
    }
  }

  // Paste landing in the input while it is unfocused: append and focus it
  void _appendToInput(String? text) {
    if (text == null || text.isEmpty || !mounted) return;
    if (_editingNoteId != null) return;
    final newText = _textController.text + text;
    setState(() {
      _textController.text = newText;
      _textController.selection =
          TextSelection.collapsed(offset: newText.length);
    });
    _inputFocusNode.requestFocus();
  }

  // Drag & drop is a desktop/web concept — the whole window is the target
  bool get _supportsDragDrop =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  Future<void> _onDropFiles(List<XFile> files) async {
    if (mounted && _dragging) setState(() => _dragging = false);
    // Disabled while editing — there a drop can't attach to the edited note
    if (_editingNoteId != null || files.isEmpty) return;
    final xfile = files.first;
    final bytes = await xfile.readAsBytes();
    if (!mounted || _editingNoteId != null) return;
    final name = xfile.name.isNotEmpty
        ? xfile.name
        : 'dropped-${DateTime.now().millisecondsSinceEpoch}';
    final mimeType = lookupMimeType(name) ?? 'application/octet-stream';
    if (rasterImageMimeTypes.contains(mimeType)) {
      await _handleImagePicked(bytes, name, mimeType);
    } else {
      setState(() {
        _pendingFile = (bytes: bytes, name: name, mimeType: mimeType);
        _originalImageBytes = null;
        _presetBytes = null;
      });
    }
  }

  Widget _wrapWithDropRegion(Widget child) {
    if (!_supportsDragDrop) return child;
    return DropTarget(
      // Fully disabled while editing (no overlay, no drop)
      enable: _editingNoteId == null,
      onDragEntered: (_) {
        if (!_dragging) setState(() => _dragging = true);
      },
      onDragExited: (_) {
        if (_dragging) setState(() => _dragging = false);
      },
      onDragDone: (details) => _onDropFiles(details.files),
      child: Stack(
        children: [
          child,
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _dragging ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: _buildDragOverlay(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDragOverlay() {
    return Semantics(
      label: 'Drop a file to attach it',
      child: Container(
        color: Colors.black.withValues(alpha: 0.45),
        child: const Center(
          child: CustomPaint(
            painter: _DashedBorderPainter(color: Colors.white),
            child: SizedBox(
              width: 170,
              height: 170,
              child: Center(
                child: Icon(Icons.arrow_upward, size: 60, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onNotesChanged() {
    final notes = NoteCache.instance.notifier.value;
    final newestId = notes.isEmpty ? null : notes.last.id;
    final newestChanged = newestId != _newestNoteId;
    _newestNoteId = newestId;

    if (!newestChanged) return;

    if (_atBottom) {
      // Near the bottom — snap fully to the newest note so it's visible.
      // reverse:true keeps the offset stable, so a small nudge to 0 is enough.
      _jumpToBottom();
      return;
    }

    final inactive =
        DateTime.now().difference(_lastInteractionTime).inSeconds >= 30;

    if (inactive) {
      _jumpToBottom();
      setState(() {
        _atBottom = true;
        _showScrollToBottom = false;
      });
    } else {
      setState(() => _showScrollToBottom = true);
    }
  }

  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels != 0.0) {
      _scrollController.jumpTo(0.0);
    }
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
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
    setState(() {
      _atBottom = true;
      _showScrollToBottom = false;
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
      final caption = _textController.text.trim();
      setState(() {
        _sending = true;
        _pendingFile = null;
      });
      _textController.clear();
      await NoteCache.instance.addFile(
        file.bytes,
        file.name,
        caption: caption.isEmpty ? null : caption,
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

  void _onFallbackBlossomPrompt() {
    if (!NoteCache.instance.promptFallbackBlossom.value) return;
    NoteCache.instance.promptFallbackBlossom.value = false;
    // Nothing to suggest if the working servers are already in use
    final inUse = NoteCache.instance.blossomServers;
    if (fallbackBlossomServers.every(inUse.contains)) return;
    _showRejectedBlossomDialog();
  }

  Future<void> _showRejectedBlossomDialog() async {
    final shown = await AuthService.getBlossomPromptShown();
    if (shown || !mounted) return;
    await AuthService.setBlossomPromptShown();
    if (!mounted) return;
    final suggested =
        fallbackBlossomServers.map(_hostOf).join(' and ');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Upload refused'),
        content: Text(
          'Your Blossom servers refused the upload — many of them only accept '
          'recognizable media, and Manent encrypts files before sending them. '
          'Would you like to add $suggested? '
          'They are only used locally (no kind:10063 update) and you can '
          'remove them anytime in the profile page.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No thanks'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add servers'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    // Keep the existing servers: they may still hold previously uploaded blobs
    final merged = <String>{...widget.blossomServers, ...fallbackBlossomServers};
    await widget.onBlossomServersChanged(merged.toList());
    NoteCache.instance.retryAllFailed();
  }

  Future<bool> _showFallbackBlossomDialog() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('No Blossom servers'),
        content: Text(
          'File uploads larger than 32KB require a Blossom server. '
          'Your account has none configured — would you like to use '
          '${fallbackBlossomServers.map(_hostOf).join(' and ')}? '
          'You can see, and eventually remove them, in the profile page.',
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
      await widget.onBlossomServersChanged(List.of(fallbackBlossomServers));
      return true;
    }
    return false;
  }

  String _hostOf(String server) => Uri.parse(server).host;

  Future<void> _pickFile() async {
    _inputFocusNode.unfocus();
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(withData: kIsWeb);
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().contains('zenity') ||
              e.toString().contains('kdialog')
          ? 'Install zenity (GNOME) or kdialog (KDE) to pick files on Linux.'
          : 'Could not open file picker: $e';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
    _inputFocusNode.unfocus();
    final xfile = await ImagePicker().pickImage(source: ImageSource.camera);
    if (xfile == null) return;
    final bytes = await xfile.readAsBytes();
    final mimeType = lookupMimeType(xfile.name) ?? 'image/jpeg';
    await _handleImagePicked(bytes, xfile.name, mimeType);
  }

  // Long-press the camera icon records a video via the native camera app,
  // keeping all its settings (zoom, HDR…). Videos skip the image pipeline.
  Future<void> _recordVideo() async {
    _inputFocusNode.unfocus();
    final xfile = await ImagePicker().pickVideo(source: ImageSource.camera);
    if (xfile == null) return;
    final bytes = await xfile.readAsBytes();
    if (!mounted) return;
    final mimeType = lookupMimeType(xfile.name) ?? 'video/mp4';
    setState(() {
      _pendingFile = (bytes: bytes, name: xfile.name, mimeType: mimeType);
      _originalImageBytes = null;
      _presetBytes = null;
    });
  }

  // Raster image that can be resized/cropped — excludes GIFs, whose animation
  // would be flattened by the (first-frame-only) resize and crop pipelines.
  static bool _isResizableImage(String mimeType) =>
      rasterImageMimeTypes.contains(mimeType) && mimeType != 'image/gif';

  Future<void> _handleImagePicked(Uint8List bytes, String name, String mimeType,
      {bool losslessBitmap = false}) async {
    // GIFs are sent as-is to preserve the animation — no resize, no crop
    if (mimeType == 'image/gif') {
      setState(() {
        _originalImageBytes = null;
        _presetBytes = null;
        _currentPreset = ImageResizePreset.original;
        _pendingFile = (bytes: bytes, name: name, mimeType: mimeType);
      });
      return;
    }
    // Preserve the source format through resizing: JPEG stays JPEG, everything
    // else becomes PNG (keeps transparency). Normalize exotic formats — webp,
    // bmp — to PNG up front so every preset shares one format across platforms.
    if (mimeType != 'image/jpeg' && mimeType != 'image/png') {
      bytes = await compute(_encodePng, bytes);
      if (!mounted) return;
      name = _swapExtension(name, 'png');
      mimeType = 'image/png';
    }
    final toJpeg = mimeType == 'image/jpeg';

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
    final targetBytes = await _resizeOne(bytes, targetPreset,
        toJpeg: toJpeg, bitmapInput: losslessBitmap);
    if (!mounted) return;
    setState(() {
      _currentPreset = targetPreset;
      _pendingFile = (bytes: targetBytes, name: name, mimeType: mimeType);
      _presetBytes = {targetPreset: targetBytes};
    });

    // Then compute remaining presets (needed only for the size modal)
    final allBytes =
        await _resizeAll(bytes, toJpeg: toJpeg, bitmapInput: losslessBitmap);
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

  // Open the full-screen crop/rotate editor on the full-quality original.
  // The editor is lossless (PNG output); the resize step below is the single
  // compression pass, so we keep the source format instead of forcing JPEG.
  Future<void> _editPendingImage() async {
    if (_openingEditor) return;
    final file = _pendingFile;
    final original = _originalImageBytes;
    if (file == null || original == null) return;
    _openingEditor = true;
    try {
      final edited = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => _ImageEditorScreen(bytes: original),
        ),
      );
      if (edited == null || !mounted) return;
      // Editor output is a lossless PNG bitmap; the resize step compresses once.
      await _handleImagePicked(edited, file.name, file.mimeType,
          losslessBitmap: true);
    } finally {
      _openingEditor = false;
    }
  }

  static String _swapExtension(String name, String ext) {
    final dot = name.lastIndexOf('.');
    final base = dot == -1 ? name : name.substring(0, dot);
    return '$base.$ext';
  }

  static Uint8List _encodeResized(img.Image im, bool toJpeg) =>
      Uint8List.fromList(
          toJpeg ? img.encodeJpg(im, quality: 85) : img.encodePng(im));

  static Map<ImageResizePreset, Uint8List> _computeAllPresets(
      (Uint8List, bool, bool) args) {
    final (bytes, toJpeg, bitmapInput) = args;
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return {for (final p in ImageResizePreset.values) p: bytes};
    }
    Uint8List resize(int maxDim) {
      final maxOrig =
          decoded.width > decoded.height ? decoded.width : decoded.height;
      // Lossless bitmap input always needs its single encode, even at full size
      if (maxOrig <= maxDim) {
        return bitmapInput ? _encodeResized(decoded, toJpeg) : bytes;
      }
      final scale = maxDim / maxOrig;
      final resized = img.copyResize(
        decoded,
        width: (decoded.width * scale).round(),
        height: (decoded.height * scale).round(),
      );
      return _encodeResized(resized, toJpeg);
    }

    return {
      ImageResizePreset.small: resize(800),
      ImageResizePreset.medium: resize(1440),
      ImageResizePreset.large: resize(2500),
      ImageResizePreset.original: bytes,
    };
  }

  static Uint8List _computePreset(
      (Uint8List, ImageResizePreset, bool, bool) args) {
    final (bytes, preset, toJpeg, bitmapInput) = args;
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
    // Lossless bitmap input always needs its single encode, even at full size
    if (maxOrig <= maxDim) {
      return bitmapInput ? _encodeResized(decoded, toJpeg) : bytes;
    }
    final scale = maxDim / maxOrig;
    final resized = img.copyResize(
      decoded,
      width: (decoded.width * scale).round(),
      height: (decoded.height * scale).round(),
    );
    return _encodeResized(resized, toJpeg);
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

  // Largest pixel dimension read from the header, no full pixel decode
  static Future<int> _maxDimension(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final maxDim = descriptor.width > descriptor.height
        ? descriptor.width
        : descriptor.height;
    descriptor.dispose();
    return maxDim;
  }

  // Encode the full-res edited bitmap once for the Original preset: JPEG at 80%
  // (no downscale to justify a higher quality), or keep the lossless PNG as-is.
  Future<Uint8List> _encodeOriginalBitmap(Uint8List bytes, bool toJpeg) async =>
      toJpeg ? compute(_encodeJpegQuality, (bytes, 80)) : bytes;

  Future<Uint8List> _resizeOne(Uint8List bytes, ImageResizePreset preset,
      {required bool toJpeg, bool bitmapInput = false}) async {
    if (preset == ImageResizePreset.original) {
      // Edited input is a lossless bitmap needing one encode; a picked file is
      // already compressed, so pass it through untouched.
      return bitmapInput ? _encodeOriginalBitmap(bytes, toJpeg) : bytes;
    }
    final maxDim = _presetMaxDim(preset);
    // Lossless bitmap (edited) input routes through the image package, which
    // always re-encodes; native/canvas short-circuits would leak raw PNG bytes.
    if (!bitmapInput) {
      if (kIsWeb) return resizeImageForWeb(bytes, maxDim, toJpeg: toJpeg);
      if (_useNativeResize) {
        // Leave already-small images untouched, matching web/desktop paths
        if (await _maxDimension(bytes) <= maxDim) return bytes;
        return await FlutterImageCompress.compressWithList(
          bytes,
          minWidth: maxDim,
          minHeight: maxDim,
          quality: 85,
          format: toJpeg ? CompressFormat.jpeg : CompressFormat.png,
        );
      }
    }
    return compute(_computePreset, (bytes, preset, toJpeg, bitmapInput));
  }

  Future<Map<ImageResizePreset, Uint8List>> _resizeAll(Uint8List bytes,
      {required bool toJpeg, bool bitmapInput = false}) async {
    final Map<ImageResizePreset, Uint8List> map;
    // Lossless bitmap (edited) input routes through the image package, which
    // always re-encodes; native/canvas short-circuits would leak raw PNG bytes.
    if (kIsWeb && !bitmapInput) {
      final results = await Future.wait([
        resizeImageForWeb(bytes, 800, toJpeg: toJpeg),
        resizeImageForWeb(bytes, 1440, toJpeg: toJpeg),
        resizeImageForWeb(bytes, 2500, toJpeg: toJpeg),
      ]);
      map = {
        ImageResizePreset.small: results[0],
        ImageResizePreset.medium: results[1],
        ImageResizePreset.large: results[2],
        ImageResizePreset.original: bytes,
      };
    } else if (_useNativeResize && !bitmapInput) {
      final maxOrig = await _maxDimension(bytes);
      final format = toJpeg ? CompressFormat.jpeg : CompressFormat.png;
      // Leave already-small images untouched, matching web/desktop paths
      Future<Uint8List> resize(int maxDim) async => maxOrig <= maxDim
          ? bytes
          : FlutterImageCompress.compressWithList(bytes,
              minWidth: maxDim, minHeight: maxDim, quality: 85, format: format);
      // Native threads run in parallel on multi-core CPUs
      final results =
          await Future.wait([resize(800), resize(1440), resize(2500)]);
      map = {
        ImageResizePreset.small: results[0],
        ImageResizePreset.medium: results[1],
        ImageResizePreset.large: results[2],
        ImageResizePreset.original: bytes,
      };
    } else {
      map = await compute(_computeAllPresets, (bytes, toJpeg, bitmapInput));
    }
    // Edited input has no pristine file to keep — encode Original once too
    if (bitmapInput) {
      map[ImageResizePreset.original] =
          await _encodeOriginalBitmap(bytes, toJpeg);
    }
    return map;
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
    final mc = context.mc;
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
                Semantics(
                  label: 'Image preview, tap to view full screen',
                  button: true,
                  child: GestureDetector(
                    onTap: () {
                      if (!kIsWeb && _NoteCardState._isDesktopOrWeb) {
                        _openImageInDesktopViewer(
                            all[selected]!, _pendingFile!.name);
                      } else {
                        Navigator.of(ctx, rootNavigator: true).push(
                          PageRouteBuilder<void>(
                            opaque: false,
                            barrierColor: Colors.black,
                            pageBuilder: (_, __, ___) => _MobileImageViewer(
                              imageBytesFuture: Future.value(all[selected]!),
                              semanticLabel: 'Image preview',
                            ),
                            transitionDuration:
                                const Duration(milliseconds: 200),
                          ),
                        );
                      }
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(ctx).size.height * 0.35,
                        ),
                        child: Container(
                          width: double.infinity,
                          color: mc.cardDim,
                          child: Image.memory(
                            original,
                            fit: BoxFit.contain,
                            semanticLabel: 'Image preview',
                          ),
                        ),
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
                                color: isSelected ? accent : mc.border,
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
                                        fontSize: 12, color: mc.secondaryText),
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

  void _initProcessText() {
    _processTextChannel.setMethodCallHandler((call) async {
      if (call.method == 'onProcessText') {
        final text = call.arguments as String?;
        if (text != null && text.isNotEmpty) _handleSharedText(text);
      }
    });
    // Retrieve any text that arrived before Dart was ready
    _processTextChannel
        .invokeMethod<String>('getInitialProcessText')
        .then((text) {
      if (text != null && text.isNotEmpty) _handleSharedText(text);
    });
  }

  void _initSharingIntent() {
    _sharingMediaSub = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_handleSharedMedia);
    ReceiveSharingIntent.instance.getInitialMedia().then((media) {
      if (media.isNotEmpty) _handleSharedMedia(media);
    });
  }

  void _handleSharedText(String text) {
    if (!mounted || text.isEmpty) return;
    final current = _textController.text;
    final normalized = text.endsWith('\n') ? text : '$text\n';
    final newText = current.isEmpty ? normalized : '$current\n$normalized';
    setState(() {
      _textController.text = newText;
      _textController.selection =
          TextSelection.collapsed(offset: newText.length);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _inputFocusNode.requestFocus();
      SystemChannels.textInput.invokeMethod('TextInput.show');
    });
  }

  Future<void> _handleSharedMedia(List<SharedMediaFile> media) async {
    if (media.isEmpty || !mounted) return;
    final item = media.first;
    if (item.type == SharedMediaType.text || item.type == SharedMediaType.url) {
      _handleSharedText(item.path);
      ReceiveSharingIntent.instance.reset();
      return;
    }
    try {
      final bytes = await File(item.path).readAsBytes();
      final name = item.path.split('/').last;
      final mimeType =
          item.mimeType ?? lookupMimeType(name) ?? 'application/octet-stream';
      if (mounted) {
        if (rasterImageMimeTypes.contains(mimeType)) {
          await _handleImagePicked(bytes, name, mimeType);
        } else {
          setState(() =>
              _pendingFile = (bytes: bytes, name: name, mimeType: mimeType));
        }
      }
    } catch (_) {}
    ReceiveSharingIntent.instance.reset();
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
        ? (note.attachment?.caption ?? '')
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

  Future<bool?> _confirmLogout(BuildContext sheetCtx) {
    final unsynced = NoteCache.instance.notifier.value
        .where((n) => n.syncStatus != SyncStatus.synced)
        .length;
    return showDialog<bool>(
      context: sheetCtx,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Log out?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Logging out removes the notes stored on this device. '
              'Synced notes can be restored from your relays next time you log in.',
            ),
            if (unsynced > 0) ...[
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Colors.red, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'You have $unsynced unsynced '
                      '${unsynced == 1 ? 'note' : 'notes'} — '
                      'they will be lost.',
                      style: const TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            style: TextButton.styleFrom(
                foregroundColor: dialogCtx.mc.primaryText),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
  }

  void _showProfileSheet() {
    final mc = context.mc;
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
              SizedBox(
                height: 24,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Align(
                      alignment: Alignment.topCenter,
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: mc.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Positioned(
                      top: -12,
                      right: -12,
                      child: Semantics(
                        label: 'Close',
                        button: true,
                        child: IconButton(
                          icon: Icon(Icons.close, color: mc.iconMuted),
                          tooltip: 'Close',
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ),
                    ),
                  ],
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
                  color: mc.secondaryText,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                decoration: BoxDecoration(
                  color: mc.cardDim,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  "Connected by ${switch (widget.user.signingMethod) {
                    SigningMethod.bunker => 'Bunker',
                    SigningMethod.browserExtension => 'Extension',
                    SigningMethod.androidSigner => 'Local signer',
                    SigningMethod.nsec => 'Nsec',
                  }}",
                  style: TextStyle(
                    fontSize: 12,
                    color: mc.secondaryText,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (widget.user.writeRelays.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'Write relays',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: mc.secondaryText,
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
                        color: mc.secondaryText,
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
                    color: mc.secondaryText,
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
                                color: mc.secondaryText,
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
                    color: mc.secondaryText,
                  ),
                ),
                const SizedBox(height: 8),
                // kind:10063 servers are read-only (no X button)
                ...kind10063Servers.map(
                  (url) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      url,
                      style: TextStyle(fontSize: 14, color: mc.secondaryText),
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
                                color: mc.secondaryText,
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
                    final confirmed = await _confirmLogout(ctx);
                    if (confirmed != true) return;
                    if (ctx.mounted) Navigator.pop(ctx);
                    await widget.onLogout();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: mc.strongButtonBg,
                    foregroundColor: mc.strongButtonFg,
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
              Text('v.$version',
                  style: TextStyle(color: ctx.mc.secondaryText)),
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
    // Background and elevation come from appBarTheme
    return AppBar(
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
            onPressed: () {
              _NoteCardState._selectionModeId.value = null;
              _inputFocusNode.unfocus();
            },
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
        return _wrapWithDropRegion(PopScope(
          canPop: !inSelection && _editingNoteId == null,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              if (_editingNoteId != null) {
                _cancelEdit();
              } else {
                _NoteCardState._selectionModeId.value = null;
                _inputFocusNode.unfocus();
              }
            }
          },
          child: Scaffold(
            backgroundColor: context.mc.surface,
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
                  ? () {
                      _NoteCardState._selectionModeId.value = null;
                      _inputFocusNode.unfocus();
                    }
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
                        return ValueListenableBuilder<bool>(
                          valueListenable: NoteCache.instance.loadingOlder,
                          builder: (context, isLoadingOlder, _) {
                            return ValueListenableBuilder<List<DecryptedNote>>(
                              valueListenable: NoteCache.instance.notifier,
                              builder: (context, notes, _) {
                                if (notes.isEmpty) {
                                  return Center(
                                    child: Text(
                                      'No notes yet',
                                      style: TextStyle(
                                          color: context.mc.secondaryText,
                                          fontSize: 14),
                                    ),
                                  );
                                }
                                return Stack(
                                  children: [
                                    NotificationListener<ScrollNotification>(
                                      onNotification: (n) {
                                        if (n is ScrollUpdateNotification) {
                                          _lastInteractionTime = DateTime.now();
                                          // reverse:true — pixels ≈ 0 is the
                                          // bottom (newest). Toggle the
                                          // scroll-to-bottom button as the user
                                          // moves away from / back to it.
                                          final atBottom = n.metrics.pixels <=
                                              _bottomThreshold;
                                          if (atBottom != _atBottom) {
                                            setState(() {
                                              _atBottom = atBottom;
                                              _showScrollToBottom = !atBottom;
                                            });
                                          }
                                        }
                                        return false;
                                      },
                                      child: ListView(
                                        controller: _scrollController,
                                        reverse: true,
                                        padding: const EdgeInsets.all(16),
                                        children: _buildNoteItems(notes,
                                            loadingOlder: isLoadingOlder),
                                      ),
                                    ),
                                    if (_showScrollToBottom)
                                      Positioned(
                                        right: 16,
                                        bottom: 16,
                                        child: Semantics(
                                          label: 'Scroll to latest note',
                                          button: true,
                                          child: GestureDetector(
                                            onTap: _scrollToBottom,
                                            child: Container(
                                              width: 36,
                                              height: 36,
                                              decoration: const BoxDecoration(
                                                color: accent,
                                                shape: BoxShape.circle,
                                              ),
                                              child: const Icon(
                                                Icons.keyboard_arrow_down,
                                                color: Colors.white,
                                                size: 24,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                              },
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
        ));
      },
    );
  }

  List<Widget> _buildNoteItems(List<DecryptedNote> notes,
      {bool loadingOlder = false}) {
    if (notes.isEmpty) return [];

    // Build oldest-first, then flip: the list is always reverse:true, so
    // index 0 = newest = visual bottom, and older notes run toward the top.
    final items = <Widget>[];

    final loadingWidget = loadingOlder
        ? Semantics(
            label: 'Loading older notes',
            child: const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(accent),
                  ),
                ),
              ),
            ),
          )
        : null;

    DateTime? currentDate;
    for (final note in notes) {
      final noteDate = DateUtils.dateOnly(note.createdAt);
      if (currentDate == null || noteDate != currentDate) {
        if (items.isNotEmpty) items.add(const SizedBox(height: 12));
        items.add(_buildDateSeparator(_formatDate(note.createdAt)));
        items.add(const SizedBox(height: 12));
      } else {
        items.add(const SizedBox(height: 12));
      }
      items.add(_NoteCard(
          key: ValueKey(note.id), note: note, onEdit: () => _startEdit(note)));
      currentDate = noteDate;
    }

    // Flip so newest (last) lands at index 0 (visual bottom). Older notes are
    // at high indices (top), so the "loading older" indicator goes at the end.
    final out = items.reversed.toList();
    if (loadingWidget != null) {
      out.add(const SizedBox(height: 12));
      out.add(loadingWidget);
    }
    return out;
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
    final mc = context.mc;
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
              color: mc.card,
              boxShadow: [
                BoxShadow(
                  color: mc.shadow,
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
                        Icon(Icons.edit, size: 14, color: mc.secondaryText),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Editing',
                            style: TextStyle(
                                fontSize: 13, color: mc.secondaryText),
                          ),
                        ),
                        Semantics(
                          label: 'Cancel editing',
                          button: true,
                          child: GestureDetector(
                            onTap: _cancelEdit,
                            child: Icon(Icons.close,
                                size: 18, color: mc.secondaryText),
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
                        Icon(Icons.attach_file,
                            size: 14, color: mc.secondaryText),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            editingFileAttachment.filename,
                            style: TextStyle(
                                fontSize: 13, color: mc.secondaryText),
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
                          GestureDetector(
                            onTap: _presetBytes != null
                                ? _showImageSizeModal
                                : null,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: Image.memory(
                                _pendingFile!.bytes,
                                width: 36,
                                height: 36,
                                fit: BoxFit.cover,
                                semanticLabel: _pendingFile!.name,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: _isResizableImage(_pendingFile!.mimeType)
                              ? GestureDetector(
                                  onTap: _presetBytes != null
                                      ? _showImageSizeModal
                                      : null,
                                  child: Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          _presetBytes != null
                                              ? '${_currentPreset.label} — ${_formatFileSize(_pendingFile!.bytes.length)}'
                                              : '${_currentPreset.label} — ',
                                          style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                              color: mc.primaryText),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (_presetBytes == null)
                                        SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                    mc.iconMuted),
                                          ),
                                        ),
                                    ],
                                  ),
                                )
                              : Text(
                                  '${_pendingFile!.name} — ${_formatFileSize(_pendingFile!.bytes.length)}',
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: mc.primaryText),
                                  overflow: TextOverflow.ellipsis,
                                ),
                        ),
                        if (_isResizableImage(_pendingFile!.mimeType)) ...[
                          Semantics(
                            label: 'Edit image',
                            button: true,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: (_presetBytes != null &&
                                      _originalImageBytes != null)
                                  ? _editPendingImage
                                  : null,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 20),
                                child: Icon(Icons.crop_rotate,
                                    size: 24, color: mc.iconMuted),
                              ),
                            ),
                          ),
                        ],
                        if (_isResizableImage(_pendingFile!.mimeType) &&
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
                          Semantics(
                            label: 'Image size settings',
                            button: true,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _showImageSizeModal,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 20),
                                child: Icon(Icons.tune,
                                    size: 24, color: mc.iconMuted),
                              ),
                            ),
                          ),
                        ],
                        Semantics(
                          label: 'Remove attachment',
                          button: true,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setState(() {
                              _pendingFile = null;
                              _originalImageBytes = null;
                              _presetBytes = null;
                            }),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 20),
                              child: Icon(Icons.close,
                                  size: 24, color: mc.iconMuted),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Flexible(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _inputFocusNode.requestFocus(),
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
                            child: MiddleClickPaste(
                              controller: _textController,
                              focusNode: _inputFocusNode,
                              child: TextField(
                                controller: _textController,
                                focusNode: _inputFocusNode,
                                maxLines: null,
                                keyboardType: TextInputType.multiline,
                                textInputAction: TextInputAction.newline,
                                onTap: () {
                                  // Android creates word selections on single
                                  // tap in a focused field; collapse to cursor
                                  if (!_textController.selection.isCollapsed) {
                                    _textController.selection =
                                        TextSelection.collapsed(
                                      offset: _textController
                                          .selection.extentOffset,
                                    );
                                  }
                                },
                                decoration: InputDecoration(
                                  hintText: hasPendingFile ||
                                          editingFileAttachment != null
                                      ? 'Add a caption...'
                                      : 'Memo...',
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding: EdgeInsets.zero,
                                  hintStyle: TextStyle(
                                    color: mc.hintText,
                                    fontSize: 14,
                                  ),
                                ),
                                style:
                                    const TextStyle(fontSize: 14, height: 1.3),
                              ),
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
                                  behavior: HitTestBehavior.opaque,
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
                                      label:
                                          'Take photo, long press to record video',
                                      button: true,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: _takePhoto,
                                        onLongPress: _recordVideo,
                                        child: Padding(
                                          padding:
                                              const EdgeInsets.only(right: 20),
                                          child: Icon(Icons.camera_alt_outlined,
                                              size: 24,
                                              color: mc.iconMuted),
                                        ),
                                      ),
                                    ),
                                  ],
                                  Semantics(
                                    label: 'Attach file',
                                    button: true,
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: _pickFile,
                                      child: Padding(
                                        padding:
                                            const EdgeInsets.only(right: 0),
                                        child: Transform.rotate(
                                          angle: 0.55,
                                          child: Icon(Icons.attach_file,
                                              size: 24,
                                              color: mc.iconMuted),
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
                ),
              ],
            ),
          ),
        ),
        if (bottomInset > 0)
          Container(
            height: bottomInset,
            color: mc.cardDim,
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
    NoteCache.instance.promptFallbackBlossom
        .removeListener(_onFallbackBlossomPrompt);
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _sharingMediaSub?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }
}

// Re-encode any decodable image to PNG, preserving transparency (via compute)
Uint8List _encodePng(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  return Uint8List.fromList(img.encodePng(decoded));
}

// Re-encode any decodable image to JPEG at the given quality (via compute)
Uint8List _encodeJpegQuality((Uint8List, int) args) {
  final (bytes, quality) = args;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  return Uint8List.fromList(img.encodeJpg(decoded, quality: quality));
}

// Rotate by 90° * quarterTurns losslessly, re-encoding to PNG (runs via compute)
Uint8List _rotateLossless((Uint8List, int) args) {
  final (bytes, quarterTurns) = args;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  final rotated = img.copyRotate(decoded, angle: 90 * quarterTurns);
  return Uint8List.fromList(img.encodePng(rotated));
}

// Cropper that always emits lossless PNG regardless of the source format, so no
// compression happens in the editor. Parsing still uses the real detected
// format; only the encode is overridden. Tear-offs stay top-level to survive
// crop_your_image's compute() isolate hop.
class _PngCropper extends ImageCropper<img.Image> {
  const _PngCropper();
  @override
  RectValidator<img.Image> get rectValidator => defaultRectValidator;
  @override
  RectCropper<img.Image> get rectCropper => _pngRectCropper;
  @override
  CircleCropper<img.Image> get circleCropper => _pngCircleCropper;
}

Uint8List _pngRectCropper(img.Image original,
    {required Offset topLeft,
    required Size size,
    required ImageFormat? outputFormat}) {
  return Uint8List.fromList(img.encodePng(img.copyCrop(
    original,
    x: topLeft.dx.toInt(),
    y: topLeft.dy.toInt(),
    width: size.width.toInt(),
    height: size.height.toInt(),
  )));
}

// Circle crop is never used (rectangular UI only), but the interface requires it
Uint8List _pngCircleCropper(img.Image original,
        {required Offset center,
        required double radius,
        required ImageFormat? outputFormat}) =>
    throw UnsupportedError('circle crop is not used');

// Full-screen crop & rotate editor; pops the edited lossless PNG bytes (or null)
class _ImageEditorScreen extends StatefulWidget {
  final Uint8List bytes;
  const _ImageEditorScreen({required this.bytes});

  @override
  State<_ImageEditorScreen> createState() => _ImageEditorScreenState();
}

class _ImageEditorScreenState extends State<_ImageEditorScreen> {
  final CropController _controller = CropController();
  late Uint8List _current = widget.bytes;
  // Bumped on each rotate to force Crop to re-init with the rotated bytes,
  // since it renders widget.image directly and only parses on first init.
  int _revision = 0;
  bool _busy = false;

  Future<void> _rotate(int quarterTurns) async {
    if (_busy) return;
    setState(() => _busy = true);
    final rotated = await compute(_rotateLossless, (_current, quarterTurns));
    if (!mounted) return;
    setState(() {
      _current = rotated;
      _revision++;
      _busy = false;
    });
  }

  void _apply() {
    if (_busy) return;
    setState(() => _busy = true);
    _controller.crop();
  }

  void _cancel() {
    if (_busy) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _apply,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _apply,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            elevation: 0,
            automaticallyImplyLeading: false,
            title: const Text('Edit image', style: TextStyle(fontSize: 18)),
            actions: [
              Semantics(
                label: 'Cancel editing',
                button: true,
                child: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Crop(
                        key: ValueKey(_revision),
                        controller: _controller,
                        image: _current,
                        // Default the selection to the whole image, so a
                        // rotate-only edit needs no manual resize
                        initialRectBuilder: InitialRectBuilder.withBuilder(
                            (viewportRect, imageRect) => imageRect),
                        // Force lossless PNG output — compression happens once, later
                        imageCropper: const _PngCropper(),
                        baseColor: Colors.black,
                        maskColor: Colors.black.withValues(alpha: 0.6),
                        cornerDotBuilder: (size, _) =>
                            const DotControl(color: Colors.white),
                        progressIndicator: const CircularProgressIndicator(
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                        onCropped: (result) {
                          if (!mounted) return;
                          switch (result) {
                            case CropSuccess(:final croppedImage):
                              Navigator.of(context).pop(croppedImage);
                            case CropFailure():
                              setState(() => _busy = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Could not crop the image')),
                              );
                          }
                        },
                      ),
                    ),
                    // While processing, hide the crop chrome but keep the image
                    // visible (dimmed) so no stale selection rectangle shows
                    if (_busy)
                      Positioned.fill(
                        child: Semantics(
                          label: 'Processing image',
                          child: ColoredBox(
                            color: Colors.black,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.memory(_current, fit: BoxFit.contain),
                                const ColoredBox(color: Color(0x66000000)),
                                const Center(
                                  child: CircularProgressIndicator(
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.white),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Container(
                color: Colors.black,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Semantics(
                              label: 'Rotate left',
                              button: true,
                              child: IconButton(
                                icon: const Icon(Icons.rotate_left,
                                    color: Colors.white),
                                iconSize: 30,
                                onPressed: _busy ? null : () => _rotate(-1),
                              ),
                            ),
                            const SizedBox(width: 40),
                            Semantics(
                              label: 'Rotate right',
                              button: true,
                              child: IconButton(
                                icon: const Icon(Icons.rotate_right,
                                    color: Colors.white),
                                iconSize: 30,
                                onPressed: _busy ? null : () => _rotate(1),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Semantics(
                          label: _busy ? 'Saving image' : 'Save image',
                          button: true,
                          child: SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: accent,
                                foregroundColor: Colors.white,
                                disabledBackgroundColor:
                                    accent.withValues(alpha: 0.5),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onPressed: _busy ? null : _apply,
                              child: _busy
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                                Colors.white),
                                      ),
                                    )
                                  : const Text('Save',
                                      style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Real first-frame thumbnail for a video, generated natively (or via canvas
// on web) from the decrypted bytes and cached by sha256. Falls back to a plain
// dark box while loading or where extraction isn't available (e.g. no ffmpeg).
class _VideoThumbnail extends StatefulWidget {
  final NoteAttachment attachment;
  const _VideoThumbnail({required this.attachment});

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  // sha256 -> thumbnail bytes (null = generated but none available)
  static final Map<String, Uint8List?> _cache = {};

  Uint8List? _thumb;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final key = widget.attachment.sha256;
    if (_cache.containsKey(key)) {
      _thumb = _cache[key];
      return;
    }
    final bytes = await NoteCache.instance.getFileBytes(widget.attachment);
    if (bytes == null) return;
    final thumb =
        await generateVideoThumbnail(bytes, widget.attachment.filename);
    _cache[key] = thumb;
    if (!mounted) return;
    setState(() => _thumb = thumb);
  }

  @override
  Widget build(BuildContext context) {
    final thumb = _thumb;
    if (thumb != null) {
      return Image.memory(
        thumb,
        fit: BoxFit.fitWidth,
        width: double.infinity,
        semanticLabel: widget.attachment.filename,
      );
    }
    return const AspectRatio(
      aspectRatio: 16 / 9,
      child: ColoredBox(color: Color(0xFF1A1A1A)),
    );
  }
}

// Web only: fetches the decrypted bytes then plays them inline via a native
// <video> element. Non-web builds never construct this.
class _WebVideoInline extends StatefulWidget {
  final NoteAttachment attachment;
  const _WebVideoInline({required this.attachment});

  @override
  State<_WebVideoInline> createState() => _WebVideoInlineState();
}

class _WebVideoInlineState extends State<_WebVideoInline> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = await NoteCache.instance.getFileBytes(widget.attachment);
    if (mounted) setState(() => _bytes = b);
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (b == null) {
      return const ColoredBox(
        color: Color(0xFF1A1A1A),
        child: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white54),
          ),
        ),
      );
    }
    return InlineWebVideo(bytes: b, mimeType: widget.attachment.mimeType);
  }
}

// Dashed rounded-square border for the drag & drop overlay
class _DashedBorderPainter extends CustomPainter {
  final Color color;
  const _DashedBorderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    const dashLength = 11.0;
    const gapLength = 8.0;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(18),
    );
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = distance + dashLength;
        canvas.drawPath(
          metric.extractPath(distance, next.clamp(0, metric.length)),
          paint,
        );
        distance = next + gapLength;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color;
}

class LinkedText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final bool selectionMode;
  final GlobalKey<SelectionAreaState>? selectionAreaKey;
  final ValueChanged<SelectedContent?>? onSelectionChanged;

  const LinkedText({
    super.key,
    required this.text,
    // No color — inherits the ambient DefaultTextStyle (onSurface), so note
    // body text adapts to light/dark automatically. Link spans set accent.
    this.style = const TextStyle(fontSize: 14, height: 1.3),
    this.selectionMode = false,
    this.selectionAreaKey,
    this.onSelectionChanged,
  });

  @override
  State<LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<LinkedText> {
  static final _urlRegex = RegExp(
    r'https?://[^\s]+|[a-zA-Z0-9][a-zA-Z0-9\-]*\.[a-zA-Z]{2,}(?:/[^\s]*)?',
    caseSensitive: false,
  );

  late TextSpan _textSpan;
  final List<TapGestureRecognizer> _recognizers = [];

  static bool get _isDesktopOrWeb {
    if (kIsWeb) {
      return defaultTargetPlatform != TargetPlatform.iOS &&
          defaultTargetPlatform != TargetPlatform.android;
    }
    return defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void didUpdateWidget(LinkedText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.style != widget.style) {
      _disposeRecognizers();
      _rebuild();
    }
  }

  void _rebuild() {
    _textSpan = TextSpan(children: _buildSpans(widget.text, widget.style));
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  List<InlineSpan> _buildSpans(String text, TextStyle baseStyle) {
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
      _recognizers.add(recognizer);
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
    final span = _textSpan;
    if (_isDesktopOrWeb) {
      return DefaultSelectionStyle(
        selectionColor: textSelectionColor,
        child: SelectionArea(
          key: widget.selectionAreaKey,
          onSelectionChanged: widget.onSelectionChanged,
          contextMenuBuilder: (_, __) => const SizedBox.shrink(),
          child: Text.rich(span),
        ),
      );
    }
    if (widget.selectionMode) {
      return DefaultSelectionStyle(
        selectionColor: textSelectionColor,
        child: SelectableText.rich(span),
      );
    }
    return Text.rich(span);
  }
}

class _NoteCard extends StatefulWidget {
  final DecryptedNote note;
  final VoidCallback? onEdit;

  const _NoteCard({super.key, required this.note, this.onEdit});

  @override
  State<_NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends State<_NoteCard>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive =>
      widget.note.kind == NoteKind.file &&
      widget.note.attachment?.isImage == true;
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
  bool _isRevealed = false;
  Offset _tapPosition = Offset.zero;
  Future<Uint8List?>? _imageBytesFuture;

  // Converts a global position to the overlay's local coordinate space.
  // Needed on web where the app is in a centered max-width container,
  // so the Overlay is offset from the Flutter view origin.
  static Offset _toOverlayLocal(BuildContext context, Offset globalPosition) {
    final box = Overlay.of(context).context.findRenderObject()! as RenderBox;
    return box.globalToLocal(globalPosition);
  }

  @override
  void initState() {
    super.initState();
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
    // Reset future if attachment identity changes (e.g. note replaced after sync)
    if (oldWidget.note.attachment?.sha256 != widget.note.attachment?.sha256) {
      _initImageFuture();
    }
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
          child: Icon(Icons.check, size: 14, color: context.mc.faintText),
        );
      case SyncStatus.failed:
        return Semantics(
          label: 'Sync failed',
          child: const Icon(Icons.sync_problem, size: 14, color: accent),
        );
      case SyncStatus.pending:
        return Semantics(
          label: 'Sync pending',
          child:
              Icon(Icons.access_time, size: 14, color: context.mc.faintText),
        );
    }
  }

  Future<void> _retry() async {
    setState(() => _retrying = true);
    await NoteCache.instance.retryDecrypt(widget.note.id);
    if (mounted) setState(() => _retrying = false);
  }

  void _showJsonModal(DecryptedNote note) {
    final diagnostics = SyncDiagnostics.instance.forNote(note.id);
    final json = diagnostics.isEmpty
        ? note.toDebugJson()
        : '${note.toDebugJson()}\n\n--- sync log ---\n${diagnostics.join('\n')}';
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
              style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  height: 1.5,
                  color: ctx.mc.primaryText),
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

  Future<void> _copyImage() async {
    final attachment = widget.note.attachment;
    if (attachment == null) return;
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return; // Platform without clipboard write support
    final bytes = await NoteCache.instance.getFileBytes(attachment);
    if (bytes == null) return;
    final format = switch (attachment.mimeType) {
      'image/png' => Formats.png,
      'image/jpeg' => Formats.jpeg,
      'image/gif' => Formats.gif,
      'image/webp' => Formats.webp,
      'image/bmp' => Formats.bmp,
      _ => Formats.png,
    };
    final item = DataWriterItem();
    item.add(format(bytes));
    await clipboard.write([item]);
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
          showCopyImage: isFileNote && widget.note.attachment?.isImage == true,
          showShare: isFileNote && !_isDesktopOrWeb,
          showCopyCaption:
              isFileNote && widget.note.attachment?.caption != null,
          showSensitive: widget.note.error == null,
          isSensitive: widget.note.sensitive,
          // Kept in release for failed notes so they can report the sync log
          showDebugJson:
              kDebugMode || widget.note.syncStatus == SyncStatus.failed,
          editedAt: widget.note.editedAt,
          fileSize: widget.note.attachment?.size,
          dim: widget.note.attachment?.dim,
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

    if (result == 'set_sensitive') {
      NoteCache.instance.setSensitive(widget.note.id, !widget.note.sensitive);
    } else if (result == 'show_json') {
      if (mounted) _showJsonModal(widget.note);
    } else if (result == 'save') {
      _saveFile();
    } else if (result == 'copy_image') {
      _copyImage();
    } else if (result == 'share') {
      _shareFile();
    } else if (result == 'copy_caption') {
      await Clipboard.setData(
          ClipboardData(text: widget.note.attachment?.caption ?? ''));
    } else if (result == 'edit' || result == 'edit_caption') {
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
      FocusManager.instance.primaryFocus?.unfocus();
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

        final mc = context.mc;
        final color =
            (!inAnyMode || menuId == widget.note.id || isActiveSelection)
                ? mc.card
                : mc.cardDim;

        void Function(TapDownDetails)? onTapDown;
        void Function()? onTap;
        void Function(TapDownDetails)? onSecondaryTapDown;
        void Function(LongPressStartDetails)? onLongPressStart;

        final isFileNote =
            widget.note.kind == NoteKind.file && widget.note.error == null;
        final isFileImage =
            isFileNote && widget.note.attachment?.isImage == true;
        final isFileVideo =
            isFileNote && widget.note.attachment?.isVideo == true;
        final isFileGif = isFileNote && widget.note.attachment?.isGif == true;
        // On web, GIFs/videos play inline in the card — the outer tap just
        // opens the context menu (the inline player handles its own controls).
        final isWebInlineMedia = kIsWeb && (isFileVideo || isFileGif);

        if (isActiveSelection) {
          // All null — SelectableText handles everything
        } else if (selectionId != null) {
          // Non-active card: tap exits selection mode
          if (!_isDesktopOrWeb) {
            onTap = () {
              _selectionModeId.value = null;
              FocusManager.instance.primaryFocus?.unfocus();
            };
          }
        } else {
          // Normal mode
          if (!_isDesktopOrWeb) {
            onTapDown = (d) =>
                _tapPosition = _toOverlayLocal(context, d.globalPosition);
            if (isWebInlineMedia) {
              onTap = _showContextMenu;
            } else if (isFileImage) {
              onTap = () => _openImageViewer(context);
              onLongPressStart = (d) {
                _tapPosition = _toOverlayLocal(context, d.globalPosition);
                _showContextMenu();
              };
            } else if (isFileVideo) {
              onTap = () => _openVideo(context);
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
            onTap = isWebInlineMedia
                ? _showContextMenu
                : isFileVideo
                    ? () => _openVideo(context)
                    : isFileNonImage
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
            // Image/video notes use zero padding — the preview fills the card
            padding: (isFileImage || isFileVideo)
                ? EdgeInsets.zero
                : const EdgeInsets.fromLTRB(16, 16, 16, 8),
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

  // Platforms with an in-app video_player; others open the video externally
  static bool get _videoPlayable =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  void _openVideo(BuildContext context) {
    final attachment = widget.note.attachment;
    if (attachment == null) return;
    // macOS/Linux open a separate native window; iOS/Android play in-app via
    // video_player; Windows plays in-app via media_kit; web opens inline.
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      _openMediaInDesktopWindow(attachment);
    } else if (_videoPlayable) {
      _openVideoPlayer(context);
    } else if (!kIsWeb) {
      _openVideoInApp(context);
    } else {
      _openVideoExternally();
    }
  }

  Future<void> _openVideoPlayer(BuildContext context) async {
    final attachment = widget.note.attachment;
    if (attachment == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (!mounted) return;
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (ctx, _, __) => VideoPlayerScreen(
          bytesFuture: NoteCache.instance.getFileBytes(attachment),
          filename: attachment.filename,
        ),
        transitionDuration: const Duration(milliseconds: 200),
      ),
    );
  }

  // Linux/Windows: video_player has no desktop implementation, so play in-app
  // with media_kit (libmpv-backed).
  Future<void> _openVideoInApp(BuildContext context) async {
    final attachment = widget.note.attachment;
    if (attachment == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (!mounted) return;
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (ctx, _, __) => MediaKitVideoScreen(
          bytesFuture: NoteCache.instance.getFileBytes(attachment),
          filename: attachment.filename,
        ),
        transitionDuration: const Duration(milliseconds: 200),
      ),
    );
  }

  // Web: no in-app player on the outer tap path — open the video in the browser
  Future<void> _openVideoExternally() async {
    final attachment = widget.note.attachment;
    if (attachment == null) return;
    final bytes = await NoteCache.instance.getFileBytes(attachment);
    if (bytes == null) return;
    await openBytesInBrowser(bytes, attachment.mimeType);
  }

  // Native desktop: write decrypted bytes to a temp file, open in a separate
  // window (reused across clicks). Handles images, GIFs and video.
  Future<void> _openMediaInDesktopWindow(NoteAttachment attachment) async {
    final bytes = await NoteCache.instance.getFileBytes(attachment);
    if (bytes == null) return;
    final file =
        File('${Directory.systemTemp.path}/manent_${attachment.filename}');
    await file.writeAsBytes(bytes);
    final args = jsonEncode({
      'path': file.path,
      'filename': attachment.filename,
      'mimeType': attachment.mimeType,
    });
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
  }

  Future<void> _openImageViewer(BuildContext context) async {
    final attachment = widget.note.attachment;
    if (attachment == null) return;

    if (!kIsWeb && _isDesktopOrWeb) {
      await _openMediaInDesktopWindow(attachment);
      return;
    }

    // Mobile / web browser: in-app full-screen viewer
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (ctx, _, __) => _MobileImageViewer(
          imageBytesFuture: NoteCache.instance.getFileBytes(attachment),
          semanticLabel: attachment.filename,
          isGif: attachment.isGif,
        ),
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
    final mc = context.mc;
    if (widget.note.kind == NoteKind.file && widget.note.error == null) {
      return _FileNoteContent(
        note: widget.note,
        imageBytesFuture: _imageBytesFuture,
        formatTime: _formatTime,
        buildSyncIcon: _buildSyncIcon,
        isDesktopOrWeb: _isDesktopOrWeb,
        isRevealed: _isRevealed,
        onReveal: () => setState(() => _isRevealed = true),
        onHide: () => setState(() => _isRevealed = false),
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
            style: TextStyle(
                fontSize: 14, height: 1.3, color: mc.primaryText),
          ),
          if (widget.note.nostrId != null)
            Text(
              'Event ID: ${widget.note.nostrId}',
              style: TextStyle(
                  fontSize: 14, height: 1.3, color: mc.primaryText),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatTime(widget.note.createdAt),
                  style: TextStyle(fontSize: 12, color: mc.faintText),
                ),
                const SizedBox(width: 4),
                _buildSyncIcon(),
              ],
            ),
          ),
        ],
      );
    }

    // Sensitive overlay for text notes
    if (widget.note.sensitive && !_isRevealed) {
      final preview = widget.note.text.length > 200
          ? widget.note.text.substring(0, 200)
          : widget.note.text;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 36),
              child: Stack(
                children: [
                  ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Text(
                      preview,
                      style: TextStyle(
                          fontSize: 14, height: 1.3, color: mc.primaryText),
                    ),
                  ),
                  Positioned.fill(
                    child: Center(
                      child: Semantics(
                        label: 'Show sensitive content',
                        button: true,
                        child: ElevatedButton(
                          onPressed: () => setState(() => _isRevealed = true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: mc.card,
                            foregroundColor: mc.primaryText,
                            elevation: 2,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 8),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.visibility_outlined, size: 16),
                              SizedBox(width: 6),
                              Text('Show'),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: widget.note.sensitive && _isRevealed ? 12 : 6),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildSyncIcon(),
                const SizedBox(width: 4),
                Text(
                  _formatTime(widget.note.createdAt),
                  style: TextStyle(fontSize: 12, color: mc.faintText),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinkedText(
          text: widget.note.text,
          selectionMode: inSelectionMode,
          selectionAreaKey: _selectionAreaKey,
          onSelectionChanged: (content) {
            final raw = content?.plainText.trim();
            _desktopSelectedContent =
                (raw != null && raw.isNotEmpty) ? raw : null;
          },
        ),
        SizedBox(height: widget.note.sensitive && _isRevealed ? 12 : 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (widget.note.sensitive && _isRevealed)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _isRevealed = false),
                child: Semantics(
                  label: 'Hide sensitive content',
                  button: true,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: mc.cardDim,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.visibility_off_outlined,
                            size: 12, color: mc.secondaryText),
                        const SizedBox(width: 4),
                        Text(
                          'Hide',
                          style:
                              TextStyle(fontSize: 11, color: mc.secondaryText),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              const SizedBox.shrink(),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildSyncIcon(),
                const SizedBox(width: 4),
                Text(
                  _formatTime(widget.note.createdAt),
                  style: TextStyle(fontSize: 12, color: mc.faintText),
                ),
              ],
            ),
          ],
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

// Opens image bytes in a native desktop viewer window (no reuse/tracking).
Future<void> _openImageInDesktopViewer(Uint8List bytes, String filename) async {
  final file = File('${Directory.systemTemp.path}/manent_$filename');
  await file.writeAsBytes(bytes);
  final args = jsonEncode({'path': file.path, 'filename': filename});
  await WindowController.create(
    WindowConfiguration(hiddenAtLaunch: true, arguments: args),
  );
}

class _FileNoteContent extends StatelessWidget {
  final DecryptedNote note;
  final Future<Uint8List?>? imageBytesFuture;
  final String Function(DateTime) formatTime;
  final Widget Function() buildSyncIcon;
  final bool isDesktopOrWeb;
  final bool isRevealed;
  final VoidCallback onReveal;
  final VoidCallback onHide;

  const _FileNoteContent({
    required this.note,
    required this.imageBytesFuture,
    required this.formatTime,
    required this.buildSyncIcon,
    required this.isDesktopOrWeb,
    required this.isRevealed,
    required this.onReveal,
    required this.onHide,
  });

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;
    final attachment = note.attachment;
    if (attachment == null) return const SizedBox.shrink();

    if (note.sensitive && !isRevealed) {
      return _buildSensitivePlaceholder(mc, attachment);
    }

    if (attachment.isImage) {
      return _buildImageContent(attachment);
    }
    if (attachment.isVideo) {
      return _buildVideoContent(mc, attachment);
    }
    return _buildFileContent(mc, attachment);
  }

  Widget _buildVideoContent(ManentColors mc, NoteAttachment attachment) {
    Widget badge(Widget child) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(4),
          ),
          child: child,
        );

    // On web, play the video inline (native <video controls>); elsewhere show
    // a tappable thumbnail that opens the player/window.
    final Widget preview = kIsWeb
        ? ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: _WebVideoInline(attachment: attachment),
            ),
          )
        : ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              children: [
                _VideoThumbnail(attachment: attachment),
                Positioned.fill(
                  child: Center(
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: Semantics(
                        label: 'Play video',
                        button: true,
                        child: const Icon(Icons.play_arrow,
                            color: Colors.white, size: 36),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 12,
                  left: 12,
                  child: badge(Text(
                    attachment.formatBadge,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[700]),
                  )),
                ),
                Positioned(
                  bottom: 12,
                  right: 12,
                  child: badge(Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      buildSyncIcon(),
                      const SizedBox(width: 4),
                      Text(
                        formatTime(note.createdAt),
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                    ],
                  )),
                ),
                if (note.sensitive)
                  Positioned(
                    bottom: 12,
                    left: 12,
                    child: Semantics(
                      label: 'Hide sensitive content',
                      button: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onHide,
                        child: badge(Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.visibility_off_outlined,
                                size: 12, color: Colors.grey[600]),
                            const SizedBox(width: 4),
                            Text('Hide',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.grey[600])),
                          ],
                        )),
                      ),
                    ),
                  ),
              ],
            ),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        preview,
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${attachment.filename} - ${_formatFileSize(attachment.size)}',
                style: TextStyle(
                    fontSize: 14, height: 1.3, color: mc.secondaryText),
                overflow: TextOverflow.ellipsis,
              ),
              if (attachment.caption != null) ...[
                const SizedBox(height: 6),
                LinkedText(text: attachment.caption!),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static ButtonStyle _showButtonStyle(ManentColors mc) =>
      ElevatedButton.styleFrom(
        backgroundColor: mc.card,
        foregroundColor: mc.primaryText,
        elevation: 2,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      );

  Widget _buildSensitivePlaceholder(
      ManentColors mc, NoteAttachment attachment) {
    if (attachment.isImage) {
      return _buildImageSensitivePlaceholder(mc, attachment);
    }
    return _buildFileSensitivePlaceholder(mc, attachment);
  }

  Widget _buildImageSensitivePlaceholder(
      ManentColors mc, NoteAttachment attachment) {
    final Widget bg;
    if (attachment.thumbhash != null) {
      bg = _ThumbhashImage(
        thumbhash: attachment.thumbhash!,
        filename: attachment.filename,
      );
    } else {
      bg = AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(color: mc.cardDim),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          bg,
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
          Positioned.fill(
            child: Center(
              child: Semantics(
                label: 'Show sensitive content',
                button: true,
                child: ElevatedButton(
                  onPressed: onReveal,
                  style: _showButtonStyle(mc),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.visibility_outlined, size: 16),
                      SizedBox(width: 6),
                      Text('Show'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileSensitivePlaceholder(
      ManentColors mc, NoteAttachment attachment) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 60),
            child: Stack(
              children: [
                IgnorePointer(
                  child: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 22,
                          backgroundColor: const Color(0xFF333333),
                          child: const Icon(Icons.insert_drive_file,
                              color: Colors.white, size: 20),
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
                                style: TextStyle(
                                    fontSize: 12, color: mc.secondaryText),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Center(
                    child: Semantics(
                      label: 'Show sensitive content',
                      button: true,
                      child: ElevatedButton(
                        onPressed: onReveal,
                        style: _showButtonStyle(mc),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.visibility_outlined, size: 16),
                            SizedBox(width: 6),
                            Text('Show'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              buildSyncIcon(),
              const SizedBox(width: 4),
              Text(
                formatTime(note.createdAt),
                style: TextStyle(fontSize: 12, color: Colors.grey[400]),
              ),
            ],
          ),
        ),
      ],
    );
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
                // GIFs: on web play inline in the card (still → play → controls);
                // elsewhere show a still + play icon that opens the viewer.
                if (attachment.isGif) {
                  if (kIsWeb) {
                    return GifPlayer(
                      bytes: snap.data!,
                      semanticLabel: attachment.filename,
                      inline: true,
                    );
                  }
                  return _GifStillImage(
                    bytes: snap.data!,
                    cacheKey: attachment.sha256,
                    filename: attachment.filename,
                  );
                }
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
          if (note.sensitive)
            Positioned(
              bottom: 16,
              left: 16,
              child: Semantics(
                label: 'Hide sensitive content',
                button: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onHide,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.visibility_off_outlined,
                            size: 12, color: Colors.grey[500]),
                        const SizedBox(width: 4),
                        Text(
                          'Hide',
                          style:
                              TextStyle(fontSize: 11, color: Colors.grey[500]),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    if (attachment.caption == null) return image;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        image,
        Padding(
          padding: const EdgeInsets.all(16),
          child: LinkedText(text: attachment.caption!),
        ),
      ],
    );
  }

  Widget _buildFileContent(ManentColors mc, NoteAttachment attachment) {
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
                    style: TextStyle(fontSize: 12, color: mc.secondaryText),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (attachment.caption != null) ...[
          const SizedBox(height: 8),
          LinkedText(text: attachment.caption!),
        ],
        SizedBox(height: note.sensitive ? 12 : 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (note.sensitive)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onHide,
                child: Semantics(
                  label: 'Hide sensitive content',
                  button: true,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: mc.cardDim,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.visibility_off_outlined,
                            size: 12, color: mc.secondaryText),
                        const SizedBox(width: 4),
                        Text(
                          'Hide',
                          style:
                              TextStyle(fontSize: 11, color: mc.secondaryText),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              const SizedBox.shrink(),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                buildSyncIcon(),
                const SizedBox(width: 4),
                Text(
                  formatTime(note.createdAt),
                  style: TextStyle(fontSize: 12, color: mc.faintText),
                ),
              ],
            ),
          ],
        ),
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

// Still first frame of a GIF with a centered play icon; the animation only
// plays in the fullscreen viewer. Non-animated GIFs render without the icon.
class _GifStillImage extends StatefulWidget {
  final Uint8List bytes;
  final String cacheKey; // sha256
  final String filename;

  const _GifStillImage({
    required this.bytes,
    required this.cacheKey,
    required this.filename,
  });

  @override
  State<_GifStillImage> createState() => _GifStillImageState();
}

class _GifStillImageState extends State<_GifStillImage> {
  // One first frame kept alive per gif (sha256) — small, avoids re-decoding
  // while scrolling. Not disposed: shared across cards.
  static final Map<String, ui.Image> _frameCache = {};
  static final Set<String> _animatedKeys = {};

  ui.Image? _frame;
  bool _animated = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cached = _frameCache[widget.cacheKey];
    if (cached != null) {
      _frame = cached;
      _animated = _animatedKeys.contains(widget.cacheKey);
      return;
    }
    try {
      final codec = await ui.instantiateImageCodec(widget.bytes);
      final animated = codec.frameCount > 1;
      final frame = await codec.getNextFrame();
      codec.dispose();
      _frameCache[widget.cacheKey] = frame.image;
      if (animated) _animatedKeys.add(widget.cacheKey);
      if (!mounted) return;
      setState(() {
        _frame = frame.image;
        _animated = animated;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    if (frame == null) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        Semantics(
          label: widget.filename,
          image: true,
          child: AspectRatio(
            aspectRatio: frame.width / frame.height,
            child: RawImage(
              image: frame,
              fit: BoxFit.fitWidth,
              width: double.infinity,
            ),
          ),
        ),
        if (_animated) ...[
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.play_arrow, color: Colors.white, size: 36),
          ),
          Positioned(
            top: 16,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'GIF',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey[700],
                ),
              ),
            ),
          ),
        ],
      ],
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
  final bool showCopyImage;
  final bool showShare;
  final bool showCopyCaption;
  final bool showSensitive;
  final bool isSensitive;
  final bool showDebugJson;
  final int? fileSize;
  final String? dim;

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
    this.showCopyImage = false,
    this.showShare = false,
    this.showCopyCaption = false,
    this.showSensitive = false,
    this.isSensitive = false,
    this.showDebugJson = false,
    this.editedAt,
    this.copyLabel = 'Copy text',
    this.fileSize,
    this.dim,
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

  // color null inherits the menu's DefaultTextStyle (primaryText) so it adapts
  Widget _menuItem(String action, String label, {Color? color}) {
    return InkWell(
      onTap: () => onSelect(action),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(label, style: TextStyle(fontSize: 14, color: color)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;
    // Menu actions in display order; dividers are interposed only between items
    // so none ever touches the top or bottom edge of the menu.
    final items = <Widget>[
      if (showRetrySync) _menuItem('retry_sync', 'Retry sync'),
      if (showSave) _menuItem('save', 'Save'),
      if (showCopyImage) _menuItem('copy_image', 'Copy'),
      if (showShare) _menuItem('share', 'Share'),
      if (showCopyCaption) _menuItem('copy_caption', 'Copy caption'),
      if (copyLabel != null) _menuItem('copy', copyLabel!),
      if (showSelectText) _menuItem('select_text', 'Select text'),
      if (showRetry) _menuItem('retry', 'Try to decrypt again'),
      if (showEdit) _menuItem('edit', 'Edit'),
      if (showEditComment) _menuItem('edit_caption', 'Edit caption'),
      if (showSensitive)
        _menuItem('set_sensitive',
            isSensitive ? 'Unset as sensitive' : 'Set as sensitive'),
      _menuItem('delete', 'Delete', color: Colors.red),
      if (showDebugJson)
        _menuItem('show_json', 'Show raw data', color: mc.secondaryText),
      if (fileSize != null || editedAt != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (fileSize != null)
                Text(
                  'Size: ${_formatFileSize(fileSize!)}',
                  style: TextStyle(fontSize: 12, color: mc.secondaryText),
                ),
              if (dim != null)
                Text(
                  'Dimensions: $dim',
                  style: TextStyle(fontSize: 12, color: mc.secondaryText),
                ),
              if ((fileSize != null || dim != null) && editedAt != null)
                const SizedBox(height: 6),
              if (editedAt != null)
                Text(
                  _formatEditedAt(editedAt!),
                  style: TextStyle(fontSize: 12, color: mc.secondaryText),
                ),
            ],
          ),
        ),
    ];

    final children = <Widget>[];
    for (final item in items) {
      if (children.isNotEmpty) {
        children.add(Divider(height: 1, color: mc.border));
      }
      children.add(item);
    }

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
              color: mc.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: mc.border),
              boxShadow: [
                BoxShadow(
                  color: mc.shadow,
                  blurRadius: 24,
                  spreadRadius: 0,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Material(
                color: Colors.transparent,
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: mc.primaryText),
                  child: IntrinsicWidth(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
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
  final Future<Uint8List?> imageBytesFuture;
  final String semanticLabel;
  final bool isGif;

  const _MobileImageViewer({
    required this.imageBytesFuture,
    required this.semanticLabel,
    this.isGif = false,
  });

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
              future: widget.imageBytesFuture,
              builder: (ctx, snap) {
                if (snap.hasData && snap.data != null) {
                  if (widget.isGif) {
                    return GifPlayer(
                      bytes: snap.data!,
                      semanticLabel: widget.semanticLabel,
                    );
                  }
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
                          semanticLabel: widget.semanticLabel,
                        ),
                      ),
                    ),
                  );
                }
                return const Center(
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white54),
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
                    child:
                        const Icon(Icons.close, color: Colors.white, size: 24),
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
