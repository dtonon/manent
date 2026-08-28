import 'dart:typed_data';

import 'package:audio_decode/audio_decode.dart' as ad;
import 'package:flutter/foundation.dart' show compute;
import 'package:opus_decode/opus_decode.dart' as opus;

import 'wav_decoder.dart';

// Whether [toSpeechWav] can handle this file, judged by mime type and
// extension: WAV, mp3, Ogg Vorbis and Ogg Opus.
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
    'audio/opus',
  };
  if (mimes.contains(mimeType)) return true;
  final dot = filename.lastIndexOf('.');
  final ext = dot == -1 ? '' : filename.substring(dot).toLowerCase();
  return ext == '.wav' ||
      ext == '.mp3' ||
      ext == '.ogg' ||
      ext == '.oga' ||
      ext == '.opus';
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
    final ad.PcmAudio pcm;
    if (WavPcm.looksLikeWav(bytes)) {
      pcm = ad.decodeWav(bytes);
    } else if (opus.isOggOpus(bytes)) {
      final o = opus.decodeOggOpus(bytes);
      pcm = ad.PcmAudio(
          sampleRate: o.sampleRate, channels: o.channels, samples: o.samples);
    } else {
      pcm = ad.decodeAudio(bytes);
    }
    return ad.encodeWav(ad.toSpeechPcm(pcm));
  } catch (_) {
    return null;
  }
}
