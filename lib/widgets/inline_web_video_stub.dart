import 'dart:typed_data';

import 'package:flutter/widgets.dart';

// Non-web stub — never used (only the web card path builds InlineWebVideo).
class InlineWebVideo extends StatelessWidget {
  final Uint8List bytes;
  final String mimeType;

  const InlineWebVideo({super.key, required this.bytes, required this.mimeType});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
