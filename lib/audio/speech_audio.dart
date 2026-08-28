import 'dart:typed_data';

import 'package:audio_decode/audio_decode.dart' as ad;
import 'package:flutter/foundation.dart' show compute;

import 'wav_decoder.dart';

// Whether [toSpeechWav] can handle this file, judged by mime type and
// extension: WAV, mp3 and Ogg Vorbis.
bool isSpeechConvertible(String mimeType, String filename) {
  const mimes = {
    'audio/wav',
    'audio/x-wav',
    'audio/wave',
    'audio/vnd.wave',
    'audio/mpeg',
    'audio/mp3',
    'audio/ogg',
    'audio/vorbis',
  };
  if (mimes.contains(mimeType)) return true;
  final dot = filename.lastIndexOf('.');
  final ext = dot == -1 ? '' : filename.substring(dot).toLowerCase();
  return ext == '.wav' || ext == '.mp3' || ext == '.ogg' || ext == '.oga';
}

// Converts any supported audio to the 16 kHz mono 16-bit WAV whisper
// expects. A file already in that shape is returned as is. Returns null
// when the bytes cannot be decoded.
Future<Uint8List?> toSpeechWav(Uint8List bytes) async {
  final wav = WavPcm.parse(bytes);
  if (wav != null &&
      wav.sampleRate == 16000 &&
      wav.channels == 1 &&
      wav.bitsPerSample == 16 &&
      !wav.isFloat) {
    return bytes;
  }
  try {
    return await compute(_convert, bytes);
  } catch (_) {
    return null;
  }
}

Uint8List? _convert(Uint8List bytes) {
  try {
    final pcm = WavPcm.looksLikeWav(bytes)
        ? ad.decodeWav(bytes)
        : ad.decodeAudio(bytes);
    return ad.encodeWav(ad.toSpeechPcm(pcm));
  } catch (_) {
    return null;
  }
}
