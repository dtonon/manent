// Inline HTML5 video player for web (native <video> element); a no-op stub
// elsewhere so shared card code can reference it unconditionally.
export 'inline_web_video_stub.dart'
    if (dart.library.html) 'inline_web_video_web.dart';
