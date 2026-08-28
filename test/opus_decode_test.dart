import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manent/audio/audio_analysis.dart';
import 'package:manent/audio/speech_audio.dart';
import 'package:manent/audio/wav_decoder.dart';
import 'package:manent/audio/waveform.dart';
import 'package:opus_decode/opus_decode.dart';

// Exercises the libopus build hook end to end on the host
void main() {
  final mono = File('test/fixtures/sine_1s_opus.ogg').readAsBytesSync();
  final stereo =
      File('test/fixtures/sine_1s_stereo_opus.ogg').readAsBytesSync();
  final vorbis = File('test/fixtures/sine_1s_stereo.ogg').readAsBytesSync();

  test('libopus is linked and reports its version', () {
    expect(opusVersion(), startsWith('libopus 1.4'));
  });

  test('detects Ogg Opus but not Ogg Vorbis', () {
    expect(isOggOpus(mono), isTrue);
    expect(isOggOpus(vorbis), isFalse);
    expect(isOggOpus(Uint8List.fromList([1, 2, 3])), isFalse);
  });

  test('decodes a mono file to one second of 48 kHz audio', () {
    final pcm = decodeOggOpus(mono);
    expect(pcm.channels, 1);
    expect(pcm.sampleRate, 48000);
    expect(pcm.duration.inMilliseconds, closeTo(1000, 30));
    var peak = 0;
    for (final s in pcm.samples) {
      if (s.abs() > peak) peak = s.abs();
    }
    // ffmpeg's sine source peaks near 0.09; lossy coding may overshoot a bit
    expect(peak / 32768, inInclusiveRange(0.05, 0.3));
  });

  test('decodes a stereo file', () {
    final pcm = decodeOggOpus(stereo);
    expect(pcm.channels, 2);
    expect(pcm.duration.inMilliseconds, closeTo(1000, 30));
  });

  test('rejects a Vorbis stream', () {
    expect(() => decodeOggOpus(vorbis), throwsA(isA<OpusDecodeException>()));
  });

  test('analysis yields a constant waveform', () async {
    final info = await analyzeAudio(mono, 'audio/ogg');
    expect(info, isNotNull);
    expect(info!.duration, closeTo(1.0, 0.05));
    expect(info.peaks.sublist(5, waveformBuckets - 5).every((p) => p > 0.85),
        isTrue);
  });

  test('converts to 16 kHz mono WAV for whisper', () async {
    final out = await toSpeechWav(stereo);
    expect(out, isNotNull);
    final wav = WavPcm.parse(out!)!;
    expect(wav.sampleRate, 16000);
    expect(wav.channels, 1);
    expect(wav.durationSeconds, closeTo(1.0, 0.05));
  });

  test('opus is a transcribable format', () {
    expect(isSpeechConvertible('audio/ogg', 'voice.ogg'), isTrue);
    expect(isSpeechConvertible('audio/opus', 'voice.opus'), isTrue);
    expect(isSpeechConvertible('application/octet-stream', 'v.OPUS'), isTrue);
  });
}
