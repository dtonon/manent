import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manent/audio/audio_analysis.dart';
import 'package:manent/audio/speech_audio.dart';
import 'package:manent/audio/wav_decoder.dart';
import 'package:manent/audio/waveform.dart';

// Exercises the audio_decode build hook end to end on the host: these fail
// if the C decoders did not compile or cannot be loaded.
void main() {
  final fixtures = Directory('test/fixtures');
  final mp3 = File('${fixtures.path}/sine_1s.mp3').readAsBytesSync();
  final ogg = File('${fixtures.path}/sine_1s_stereo.ogg').readAsBytesSync();
  final wav44 =
      File('${fixtures.path}/sine_1s_stereo_44k.wav').readAsBytesSync();

  test('mp3 yields a one second constant waveform', () async {
    final info = await analyzeAudio(mp3, 'audio/mpeg');
    expect(info, isNotNull);
    expect(info!.duration, closeTo(1.0, 0.1));
    expect(info.peaks.length, waveformBuckets);
    // A steady sine normalizes to ~1 everywhere; allow codec ramps at the ends
    final middle = info.peaks.sublist(5, waveformBuckets - 5);
    expect(middle.every((p) => p > 0.85), isTrue);
  });

  test('stereo ogg yields duration and peaks', () async {
    final info = await analyzeAudio(ogg, 'audio/ogg');
    expect(info, isNotNull);
    expect(info!.duration, closeTo(1.0, 0.1));
    expect(info.peaks.sublist(5, waveformBuckets - 5).every((p) => p > 0.85),
        isTrue);
  });

  test('unknown bytes return null', () async {
    final info =
        await analyzeAudio(Uint8List.fromList(List.filled(64, 7)), 'audio/aac');
    expect(info, isNull);
  });

  test('mp3 converts to 16 kHz mono WAV for whisper', () async {
    final out = await toSpeechWav(mp3);
    expect(out, isNotNull);
    final wav = WavPcm.parse(out!)!;
    expect(wav.sampleRate, 16000);
    expect(wav.channels, 1);
    expect(wav.bitsPerSample, 16);
    expect(wav.durationSeconds, closeTo(1.0, 0.1));
  });

  test('44.1 kHz stereo WAV is resampled and downmixed', () async {
    final out = await toSpeechWav(wav44);
    expect(out, isNotNull);
    final wav = WavPcm.parse(out!)!;
    expect(wav.sampleRate, 16000);
    expect(wav.channels, 1);
    expect(wav.durationSeconds, closeTo(1.0, 0.05));
  });

  test('a 16 kHz mono WAV passes through untouched', () async {
    final out = await toSpeechWav(wav44);
    final again = await toSpeechWav(out!);
    expect(identical(again, out), isTrue);
  });

  test('transcribable formats are recognised by mime or extension', () {
    expect(isSpeechConvertible('audio/mpeg', 'a.mp3'), isTrue);
    expect(isSpeechConvertible('audio/ogg', 'a.ogg'), isTrue);
    expect(isSpeechConvertible('audio/x-wav', 'a.wav'), isTrue);
    expect(isSpeechConvertible('application/octet-stream', 'a.MP3'), isTrue);
    expect(isSpeechConvertible('audio/mp4', 'a.m4a'), isFalse);
    expect(isSpeechConvertible('audio/aac', 'a.aac'), isFalse);
  });
}
