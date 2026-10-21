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
  final String? transcript; // speech-to-text of audio, kept apart from caption
  final bool sensitive;
  final String? dim; // "<width>x<height>", images only
  final double? duration; // seconds, audio only
  final String? waveform; // base64, one 0-255 peak per bucket, audio only

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
    this.transcript,
    this.sensitive = false,
    this.dim,
    this.duration,
    this.waveform,
  });

  bool get isInline => data != null;
  bool get isImage => rasterImageMimeTypes.contains(mimeType);
  bool get isGif => mimeType == 'image/gif';
  bool get isVideo => mimeType.startsWith('video/');
  bool get isAudio => mimeType.startsWith('audio/');

  // Audio someone spoke in, by the only evidence that cannot lie: a transcript
  bool get isVoiceNote => isAudio && transcript != null;

  // Short uppercase label for badges, e.g. MP4 / MOV — from the extension,
  // falling back to the mime subtype.
  String get formatBadge {
    final dot = filename.lastIndexOf('.');
    if (dot != -1 && dot < filename.length - 1) {
      return filename.substring(dot + 1).toUpperCase();
    }
    final slash = mimeType.indexOf('/');
    return slash != -1 ? mimeType.substring(slash + 1).toUpperCase() : 'VIDEO';
  }

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
        if (transcript != null) 'transcript': transcript,
        if (sensitive) 'sensitive': true,
        if (dim != null) 'dim': dim,
        if (duration != null) 'duration': duration,
        if (waveform != null) 'waveform': waveform,
      };

  factory NoteAttachment.fromJson(Map<String, dynamic> j) => NoteAttachment(
        url: j['url'] as String?,
        data: j['data'] as String?,
        filename: j['filename'] as String,
        mimeType: _normalizeMimeType(
            (j['file-type'] ?? j['mime_type'])
                as String, // TODO: 'mime_type' is deprecated, remove it after some time
            j['filename'] as String),
        size: j['size'] as int,
        sha256: (j['x'] ?? j['sha256'])
            as String, // TODO: 'sha256' is deprecated, remove it after some time
        key: (j['decryption-key'] ?? j['key'])
            as String, // TODO: 'key' is deprecated, remove it after some time
        thumbhash: j['thumbhash'] as String?,
        caption: (j['caption'] ?? j['comment'])
            as String?, // TODO: 'comment' is deprecated, remove it after some time
        transcript: j['transcript'] as String?,
        sensitive: j['sensitive'] == true,
        dim: j['dim'] as String?,
        duration: (j['duration'] as num?)?.toDouble(),
        waveform: j['waveform'] as String?,
      );

  String toJsonString() => jsonEncode(toJson());

  // Opus notes saved before the extension was known carry a generic type
  static String _normalizeMimeType(String mimeType, String filename) {
    if (mimeType == 'application/octet-stream' &&
        filename.toLowerCase().endsWith('.opus')) {
      return 'audio/ogg';
    }
    return mimeType;
  }

  // Caption and transcript can be cleared by passing clearCaption /
  // clearTranscript, since null means "keep"
  NoteAttachment copyWith({
    String? url,
    String? data,
    bool? sensitive,
    String? caption,
    bool clearCaption = false,
    String? transcript,
    bool clearTranscript = false,
  }) =>
      NoteAttachment(
        url: url ?? this.url,
        data: data ?? this.data,
        filename: filename,
        mimeType: mimeType,
        size: size,
        sha256: sha256,
        key: key,
        thumbhash: thumbhash,
        caption: clearCaption ? null : (caption ?? this.caption),
        transcript: clearTranscript ? null : (transcript ?? this.transcript),
        sensitive: sensitive ?? this.sensitive,
        dim: dim,
        duration: duration,
        waveform: waveform,
      );
}
