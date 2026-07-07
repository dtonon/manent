import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../utils/primary_selection.dart';

/// Wraps a text field so the middle mouse button pastes the Linux PRIMARY
/// selection (the last-highlighted text in any app) at the caret. On platforms
/// without a PRIMARY selection the child is returned unchanged.
class MiddleClickPaste extends StatelessWidget {
  const MiddleClickPaste({
    super.key,
    required this.controller,
    required this.child,
    this.focusNode,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!PrimarySelection.isSupported) return child;
    return Listener(
      onPointerDown: (event) {
        if (event.buttons == kMiddleMouseButton) _paste();
      },
      child: child,
    );
  }

  Future<void> _paste() async {
    final text = await PrimarySelection.read();
    if (text == null) return;

    final value = controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;

    controller.value = TextEditingValue(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    focusNode?.requestFocus();
  }
}
