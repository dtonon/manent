import 'dart:io';
import 'dart:typed_data';

import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';

// Writes the video to a temp file and asks the OS-native thumbnailer for a
// first-frame JPEG. Linux needs system ffmpeg libs; any failure returns null.
Future<Uint8List?> generateVideoThumbnail(
    Uint8List bytes, String filename) async {
  File? src;
  try {
    src = File('${Directory.systemTemp.path}/manent_thumbsrc_$filename');
    await src.writeAsBytes(bytes);
    final thumb = await FcNativeVideoThumbnail().saveThumbnailToBytes(
      srcFile: src.path,
      width: 640,
      height: 640,
      format: 'jpeg',
      quality: 75,
    );
    return thumb;
  } catch (_) {
    return null;
  } finally {
    try {
      src?.deleteSync();
    } catch (_) {}
  }
}
