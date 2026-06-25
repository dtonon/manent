import 'dart:async';
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';

// Loads the video into a hidden element, grabs an early frame onto a canvas
// and reads it back as JPEG bytes. Returns null on failure/timeout.
Future<Uint8List?> generateVideoThumbnail(
    Uint8List bytes, String filename) async {
  final completer = Completer<Uint8List?>();
  String? url;
  try {
    final blob = html.Blob([bytes]);
    url = html.Url.createObjectUrlFromBlob(blob);
    final video = html.VideoElement()
      ..src = url
      ..muted = true
      ..preload = 'metadata';

    void finish(Uint8List? result) {
      final u = url;
      if (u != null) html.Url.revokeObjectUrl(u);
      if (!completer.isCompleted) completer.complete(result);
    }

    video.onLoadedData.first.then((_) async {
      try {
        video.currentTime = 0.1;
        await video.onSeeked.first;
        final w = video.videoWidth;
        final h = video.videoHeight;
        if (w == 0 || h == 0) return finish(null);
        final canvas = html.CanvasElement(width: w, height: h);
        (canvas.context2D).drawImage(video, 0, 0);
        final dataUrl = canvas.toDataUrl('image/jpeg', 0.75);
        finish(base64Decode(dataUrl.split(',').last));
      } catch (_) {
        finish(null);
      }
    });
    video.onError.first.then((_) => finish(null));
  } catch (_) {
    if (url != null) html.Url.revokeObjectUrl(url);
    if (!completer.isCompleted) completer.complete(null);
  }
  return completer.future
      .timeout(const Duration(seconds: 8), onTimeout: () => null);
}
