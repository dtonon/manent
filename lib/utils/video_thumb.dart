// Generates a JPEG thumbnail (first frame) from raw video bytes.
// Native platforms use fc_native_video_thumbnail (OS-native APIs); web uses
// a hidden <video> + <canvas>. Returns null when unsupported or on failure.
export 'video_thumb_io.dart' if (dart.library.html) 'video_thumb_web.dart';
