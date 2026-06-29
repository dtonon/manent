import 'dart:typed_data';

Future<Uint8List> resizeImageForWeb(Uint8List bytes, int maxDim,
    {bool toJpeg = true}) {
  throw UnsupportedError('resizeImageForWeb is only available on web');
}
