import 'dart:convert';

const rasterImageMimeTypes = {
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
  'image/bmp',
};

class NoteAttachment {
  final String? url;
  final String? data; // base64 encrypted bytes, inline only
  final String filename;
  final String mimeType;
  final int size; // original unencrypted size
  final String sha256; // of encrypted bytes
  final String key; // hex 32-byte AES key
  final String? thumbhash; // base64, images only
  final String? caption;
  final bool sensitive;
  final String? dim; // "<width>x<height>", images only

  const NoteAttachment({
    this.url,
    this.data,
    required this.filename,
    required this.mimeType,
    required this.size,
    required this.sha256,
    required this.key,
    this.thumbhash,
    this.caption,
    this.sensitive = false,
    this.dim,
  });

  bool get isInline => data != null;
  bool get isImage => rasterImageMimeTypes.contains(mimeType);

  Map<String, dynamic> toJson() => {
        if (url != null) 'url': url,
        if (data != null) 'data': data,
        'filename': filename,
        'file-type': mimeType,
        'encryption-algorithm': 'aes-gcm',
        'size': size,
        'x': sha256,
        'decryption-key': key,
        if (thumbhash != null) 'thumbhash': thumbhash,
        if (caption != null) 'caption': caption,
        if (sensitive) 'sensitive': true,
        if (dim != null) 'dim': dim,
      };

  factory NoteAttachment.fromJson(Map<String, dynamic> j) => NoteAttachment(
        url: j['url'] as String?,
        data: j['data'] as String?,
        filename: j['filename'] as String,
        mimeType: (j['file-type'] ?? j['mime_type'])
            as String, // TODO: 'mime_type' is deprecated, remove it after some time
        size: j['size'] as int,
        sha256: (j['x'] ?? j['sha256'])
            as String, // TODO: 'sha256' is deprecated, remove it after some time
        key: (j['decryption-key'] ?? j['key'])
            as String, // TODO: 'key' is deprecated, remove it after some time
        thumbhash: j['thumbhash'] as String?,
        caption: (j['caption'] ?? j['comment'])
            as String?, // TODO: 'comment' is deprecated, remove it after some time
        sensitive: j['sensitive'] == true,
        dim: j['dim'] as String?,
      );

  String toJsonString() => jsonEncode(toJson());

  NoteAttachment copyWith({String? url, String? data, bool? sensitive}) =>
      NoteAttachment(
        url: url ?? this.url,
        data: data ?? this.data,
        filename: filename,
        mimeType: mimeType,
        size: size,
        sha256: sha256,
        key: key,
        thumbhash: thumbhash,
        caption: caption,
        sensitive: sensitive ?? this.sensitive,
        dim: dim,
      );
}
