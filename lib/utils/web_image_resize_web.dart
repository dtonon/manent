// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:convert';
import 'dart:typed_data';

Future<Uint8List> resizeImageForWeb(Uint8List bytes, int maxDim) async {
  final blob = html.Blob([bytes]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final img = html.ImageElement()..src = url;
  await img.onLoad.first;
  html.Url.revokeObjectUrl(url);

  final w = img.naturalWidth!;
  final h = img.naturalHeight!;
  final maxOrig = w > h ? w : h;
  if (maxOrig <= maxDim) return bytes;

  final scale = maxDim / maxOrig;
  final tw = (w * scale).round();
  final th = (h * scale).round();

  final canvas = html.CanvasElement(width: tw, height: th);
  canvas.context2D.drawImageScaled(img, 0, 0, tw, th);
  final dataUrl = canvas.toDataUrl('image/jpeg', 0.85);
  return base64Decode(dataUrl.split(',').last);
}
