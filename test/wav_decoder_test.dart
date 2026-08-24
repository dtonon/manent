import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manent/audio/wav_decoder.dart';
import 'package:manent/audio/waveform.dart';

Uint8List _wav16({
  required int sampleRate,
  required int channels,
  required List<int> samples,
}) {
  final dataSize = samples.length * 2;
  final b = ByteData(44 + dataSize);
  void str(int o, String s) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + dataSize, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, channels, Endian.little);
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * channels * 2, Endian.little);
  b.setUint16(32, channels * 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, dataSize, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    b.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

void main() {
  _normalizeTests();
  test('parses 16-bit mono WAV and reports duration', () {
    final samples = List<int>.generate(16000 * 2, (i) => 0);
    final wav =
        WavPcm.parse(_wav16(sampleRate: 16000, channels: 1, samples: samples));
    expect(wav, isNotNull);
    expect(wav!.channels, 1);
    expect(wav.frameCount, 32000);
    expect(wav.durationSeconds, closeTo(2.0, 1e-9));
  });

  test('peaks follow the loud and quiet halves', () {
    final samples = List<int>.generate(
      8000,
      (i) => i < 4000
          ? (math.sin(i / 10) * 30000).round()
          : (math.sin(i / 10) * 3000).round(),
    );
    final wav =
        WavPcm.parse(_wav16(sampleRate: 8000, channels: 1, samples: samples))!;
    final peaks = normalizePeaks(wav.peaks(10));
    expect(peaks.length, 10);
    expect(peaks.first, closeTo(1.0, 0.05));
    expect(peaks.last, closeTo(0.1, 0.03));
  });

  test('stereo frames count once', () {
    final samples = List<int>.filled(4000, 100);
    final wav =
        WavPcm.parse(_wav16(sampleRate: 1000, channels: 2, samples: samples))!;
    expect(wav.frameCount, 2000);
    expect(wav.durationSeconds, closeTo(2.0, 1e-9));
  });

  test('rejects non-WAV bytes and truncated headers', () {
    expect(WavPcm.parse(Uint8List.fromList([1, 2, 3])), isNull);
    expect(WavPcm.parse(Uint8List.fromList('RIFF0000WAVE'.codeUnits)), isNull);
  });

  test('waveform round-trips through base64 and resamples by max', () {
    final peaks = [0.0, 0.5, 1.0, 0.25];
    final decoded = decodeWaveform(encodeWaveform(peaks))!;
    expect(decoded.length, 4);
    expect(decoded[2], closeTo(1.0, 1e-9));
    expect(decoded[1], closeTo(0.5, 0.01));
    expect(resamplePeaks(peaks, 2), [0.5, 1.0]);
    expect(resamplePeaks(peaks, 8).length, 8);
    expect(decodeWaveform(null), isNull);
    expect(decodeWaveform('***'), isNull);
  });
}

void _normalizeTests() {
  test('normalize raises a quiet file to the target peak', () {
    final samples =
        List<int>.generate(2000, (i) => (math.sin(i / 7) * 1000).round());
    final bytes = _wav16(sampleRate: 8000, channels: 1, samples: samples);
    normalizeWavInPlace(bytes);
    final wav = WavPcm.parse(bytes)!;
    var peak = 0.0;
    for (var f = 0; f < wav.frameCount; f++) {
      peak = math.max(peak, wav.sample(f, 0).abs());
    }
    expect(peak, closeTo(0.9, 0.01));
  });

  test('normalize leaves a loud file alone', () {
    final samples =
        List<int>.generate(2000, (i) => (math.sin(i / 7) * 31000).round());
    final bytes = _wav16(sampleRate: 8000, channels: 1, samples: samples);
    final before = Uint8List.fromList(bytes);
    normalizeWavInPlace(bytes);
    expect(bytes, before);
  });

  test('normalize caps the gain on near-silent input', () {
    final samples = List<int>.generate(2000, (i) => i.isEven ? 10 : -10);
    final bytes = _wav16(sampleRate: 8000, channels: 1, samples: samples);
    normalizeWavInPlace(bytes, maxGain: 32);
    final wav = WavPcm.parse(bytes)!;
    expect(wav.sample(0, 0), closeTo(320 / 32768, 1e-6));
  });

  test('normalize ignores non-WAV bytes', () {
    final junk = Uint8List.fromList([1, 2, 3, 4]);
    expect(normalizeWavInPlace(junk), junk);
  });
}
