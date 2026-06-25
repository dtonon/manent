// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

// Inline native HTML5 <video controls> element (via a platform view) fed a
// blob URL of the decrypted bytes. The browser handles playback/controls.
class InlineWebVideo extends StatefulWidget {
  final Uint8List bytes;
  final String mimeType;

  const InlineWebVideo({super.key, required this.bytes, required this.mimeType});

  @override
  State<InlineWebVideo> createState() => _InlineWebVideoState();
}

class _InlineWebVideoState extends State<InlineWebVideo> {
  static int _seq = 0;
  late final String _viewType;
  late final String _url;

  @override
  void initState() {
    super.initState();
    final blob = html.Blob([widget.bytes], widget.mimeType);
    _url = html.Url.createObjectUrlFromBlob(blob);
    _viewType = 'manent-inline-video-${_seq++}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      return html.VideoElement()
        ..src = _url
        ..controls = true
        ..preload = 'metadata'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.border = 'none'
        ..style.objectFit = 'contain'
        ..style.backgroundColor = 'black';
    });
  }

  @override
  void dispose() {
    html.Url.revokeObjectUrl(_url);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
