import 'dart:convert';

class NoteAttachment {
  final String? url;
  final String? data; // base64 encrypted bytes, inline only
  final String filename;
  final String mimeType;
  final int size; // original unencrypted size
  final String sha256; // of encrypted bytes
  final String key; // hex 32-byte AES key
  final String? thumbhash; // base64, images only
  final String? comment; // optional user comment

  const NoteAttachment({
    this.url,
    this.data,
    required this.filename,
    required this.mimeType,
    required this.size,
    required this.sha256,
    required this.key,
    this.thumbhash,
    this.comment,
  });

  bool get isInline => data != null;
  bool get isImage => mimeType.startsWith('image/');

  Map<String, dynamic> toJson() => {
        if (url != null) 'url': url,
        if (data != null) 'data': data,
        'filename': filename,
        'mime_type': mimeType,
        'size': size,
        'sha256': sha256,
        'key': key,
        if (thumbhash != null) 'thumbhash': thumbhash,
        if (comment != null) 'comment': comment,
      };

  factory NoteAttachment.fromJson(Map<String, dynamic> j) => NoteAttachment(
        url: j['url'] as String?,
        data: j['data'] as String?,
        filename: j['filename'] as String,
        mimeType: j['mime_type'] as String,
        size: j['size'] as int,
        sha256: j['sha256'] as String,
        key: j['key'] as String,
        thumbhash: j['thumbhash'] as String?,
        comment: j['comment'] as String?,
      );

  String toJsonString() => jsonEncode(toJson());

  NoteAttachment copyWith({String? url, String? data}) => NoteAttachment(
        url: url ?? this.url,
        data: data ?? this.data,
        filename: filename,
        mimeType: mimeType,
        size: size,
        sha256: sha256,
        key: key,
        thumbhash: thumbhash,
        comment: comment,
      );
}
