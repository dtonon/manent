import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Access to the X11/Wayland PRIMARY selection — the text most recently
/// highlighted in any application, which the middle mouse button pastes on
/// Linux. This is distinct from the regular (Ctrl+C) clipboard.
///
/// Backed by a native GTK method channel; see `linux/my_application.cc`.
class PrimarySelection {
  static const MethodChannel _channel =
      MethodChannel('manent/primary_selection');

  /// Whether the current platform exposes a PRIMARY selection.
  static bool get isSupported => !kIsWeb && Platform.isLinux;

  /// Returns the current PRIMARY selection text, or null when unsupported,
  /// empty, or unavailable.
  static Future<String?> read() async {
    if (!isSupported) return null;
    try {
      final text = await _channel.invokeMethod<String>('getPrimarySelection');
      if (text == null || text.isEmpty) return null;
      return text;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
