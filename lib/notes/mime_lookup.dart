import 'package:mime/mime.dart';

// The mime package has no entry for some audio extensions
const _extraMimeTypes = {
  '.opus': 'audio/ogg',
};

String mimeTypeForFilename(String filename) {
  final dot = filename.lastIndexOf('.');
  final ext = dot == -1 ? '' : filename.substring(dot).toLowerCase();
  return _extraMimeTypes[ext] ??
      lookupMimeType(filename) ??
      'application/octet-stream';
}
