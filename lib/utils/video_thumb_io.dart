import 'dart:async';
import 'dart:io';

import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';

const _maxSide = 640;
const _quality = 75;

// Writes the video to a temp file and asks the OS-native thumbnailer for a
// first-frame JPEG. Linux has no OS thumbnailer and the plugin's FFmpeg build
// breaks across distro majors, so it grabs the frame through libmpv instead
// (already a runtime dependency). Any failure returns null.
Future<Uint8List?> generateVideoThumbnail(
    Uint8List bytes, String filename) async {
  File? src;
  try {
    src = File('${Directory.systemTemp.path}/manent_thumbsrc_$filename');
    await src.writeAsBytes(bytes);
    if (Platform.isLinux) return await _mpvThumbnail(src.path);
    return await FcNativeVideoThumbnail().saveThumbnailToBytes(
      srcFile: src.path,
      width: _maxSide,
      height: _maxSide,
      format: 'jpeg',
      quality: _quality,
    );
  } catch (_) {
    return null;
  } finally {
    try {
      src?.deleteSync();
    } catch (_) {}
  }
}

// Without a video widget media_kit keeps decoding off (vid=no), so the track
// is enabled by hand; vo=null renders the frame without a window.
Future<Uint8List?> _mpvThumbnail(String path) async {
  final player = Player(
    configuration: const PlayerConfiguration(vo: 'null', muted: true),
  );
  try {
    await player.setVideoTrack(VideoTrack.auto());
    final firstFrame = player.stream.width.firstWhere((w) => (w ?? 0) > 0);
    await player.open(Media(path), play: false);
    await firstFrame.timeout(const Duration(seconds: 10));
    Uint8List? jpeg;
    for (var i = 0; i < 20 && jpeg == null; i++) {
      jpeg = await player.screenshot(format: 'image/jpeg');
      if (jpeg == null) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    if (jpeg == null) return null;
    return compute(_shrink, jpeg);
  } finally {
    await player.dispose();
  }
}

// Scales the full-size frame down to the same box the native thumbnailers use.
Uint8List? _shrink(Uint8List jpeg) {
  final frame = img.decodeJpg(jpeg);
  if (frame == null) return null;
  final longest = frame.width > frame.height ? frame.width : frame.height;
  if (longest <= _maxSide) return jpeg;
  final scale = _maxSide / longest;
  final resized = img.copyResize(
    frame,
    width: (frame.width * scale).round(),
    height: (frame.height * scale).round(),
    interpolation: img.Interpolation.average,
  );
  return img.encodeJpg(resized, quality: _quality);
}
