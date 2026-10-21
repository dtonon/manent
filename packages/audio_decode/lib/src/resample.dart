import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_decode_base.dart';

/// Mixes [audio] down to a single channel.
///
/// Channels are averaged, which is what a speech or analysis pipeline wants:
/// picking one channel throws away half the signal, and summing without
/// dividing clips. Returns [audio] unchanged when it is already mono.
PcmAudio toMono(PcmAudio audio) {
  if (audio.channels == 1) return audio;
  if (audio.channels < 1) {
    throw ArgumentError.value(
      audio.channels,
      'audio.channels',
      'must be at least 1',
    );
  }
  final frames = audio.frameCount;
  final out = Int16List(frames);
  final channels = audio.channels;
  for (var frame = 0; frame < frames; frame++) {
    var sum = 0;
    final base = frame * channels;
    for (var channel = 0; channel < channels; channel++) {
      sum += audio.samples[base + channel];
    }
    // Round half away from zero so a quiet signal does not drift toward zero.
    final mean = sum >= 0
        ? (sum + channels ~/ 2) ~/ channels
        : -((-sum + channels ~/ 2) ~/ channels);
    out[frame] = mean.clamp(-32768, 32767);
  }
  return PcmAudio(sampleRate: audio.sampleRate, channels: 1, samples: out);
}

/// Resamples [audio] to [targetRate], keeping its channel count.
///
/// Downsampling low-passes first. Skipping that step is the usual mistake:
/// dropping 44.1 kHz to 16 kHz without filtering folds everything above 8 kHz
/// back into the band as a lower tone that was never in the recording, and it
/// cannot be removed afterwards. The filter is a windowed-sinc FIR at 90% of
/// the target Nyquist, applied per channel; upsampling needs no filter, so it
/// interpolates directly.
///
/// This is linear interpolation over a filtered signal — enough for speech
/// features and analysis, which is what this package's callers do with PCM. A
/// mastering-grade resampler would use a polyphase bank; if that is what you
/// need, this is not it, and saying so here is cheaper than you finding out.
///
/// Returns [audio] unchanged when it is already at [targetRate]. Throws
/// [ArgumentError] if [targetRate] is not positive.
PcmAudio resample(PcmAudio audio, int targetRate) {
  if (targetRate < 1) {
    throw ArgumentError.value(targetRate, 'targetRate', 'must be positive');
  }
  if (audio.sampleRate == targetRate) return audio;
  if (audio.sampleRate < 1) {
    throw ArgumentError.value(
      audio.sampleRate,
      'audio.sampleRate',
      'must be positive to resample',
    );
  }
  if (audio.frameCount == 0) {
    return PcmAudio(
      sampleRate: targetRate,
      channels: audio.channels,
      samples: Int16List(0),
    );
  }

  final channels = audio.channels;
  final source = audio.sampleRate < targetRate
      ? audio
      : _lowPass(audio, cutoff: targetRate * 0.45);

  final ratio = targetRate / audio.sampleRate;
  final outFrames = math.max(1, (source.frameCount * ratio).floor());
  final out = Int16List(outFrames * channels);
  final step = audio.sampleRate / targetRate;

  for (var frame = 0; frame < outFrames; frame++) {
    final position = frame * step;
    final left = position.floor();
    final right = math.min(left + 1, source.frameCount - 1);
    final t = position - left;
    for (var channel = 0; channel < channels; channel++) {
      final a = source.samples[left * channels + channel];
      final b = source.samples[right * channels + channel];
      out[frame * channels + channel] = (a + (b - a) * t).round().clamp(
        -32768,
        32767,
      );
    }
  }
  return PcmAudio(sampleRate: targetRate, channels: channels, samples: out);
}

/// Mono at 16 kHz, the input shape on-device speech models ask for.
///
/// Whisper, wav2vec 2.0 and the Vosk family all want 16 kHz mono 16-bit PCM,
/// so this is the one line between a decoded file and the model.
///
/// Whether the caller has to run it depends on the wrapper, so it is worth
/// checking before reaching for this: some bundle FFmpeg and convert files
/// themselves, though usually only on part of the platforms they support,
/// while others never convert and take the bytes exactly as given. Streaming
/// entry points generally convert nothing. The README's "Feeding a speech
/// model" section compares the current Dart wrappers.
///
/// Equivalent to `resample(toMono(audio), sampleRate)`; the default is 16000
/// and the parameter is there for a model that wants 8 kHz.
PcmAudio toSpeechPcm(PcmAudio audio, {int sampleRate = 16000}) =>
    resample(toMono(audio), sampleRate);

/// A windowed-sinc low-pass at [cutoff] Hz, applied per channel.
///
/// Hamming-windowed, 63 taps: long enough for a transition band that keeps
/// aliases well down at the rates people actually resample between, short
/// enough that a minute of audio filters in milliseconds.
PcmAudio _lowPass(PcmAudio audio, {required double cutoff}) {
  final nyquist = audio.sampleRate / 2;
  if (cutoff >= nyquist) return audio;

  const taps = 63;
  const half = taps ~/ 2;
  final normalized = cutoff / audio.sampleRate; // cycles per sample
  final kernel = Float64List(taps);
  var sum = 0.0;
  for (var i = 0; i < taps; i++) {
    final n = i - half;
    final sinc = n == 0
        ? 2 * normalized
        : math.sin(2 * math.pi * normalized * n) / (math.pi * n);
    // Hamming: sidelobes low enough that the stopband does not leak audibly.
    final window = 0.54 - 0.46 * math.cos(2 * math.pi * i / (taps - 1));
    kernel[i] = sinc * window;
    sum += kernel[i];
  }
  for (var i = 0; i < taps; i++) {
    // Unity gain at DC, so resampling does not change loudness. At the
    // current window and tap count the raw kernel already sums to 0.999, so
    // this corrects about 0.1% and no test can meaningfully pin it — it is
    // here because that is an accident of these constants, not a property of
    // the design. Change the window or the tap count and it starts mattering.
    kernel[i] /= sum;
  }

  final channels = audio.channels;
  final frames = audio.frameCount;
  final out = Int16List(audio.samples.length);
  for (var channel = 0; channel < channels; channel++) {
    for (var frame = 0; frame < frames; frame++) {
      var acc = 0.0;
      for (var tap = 0; tap < taps; tap++) {
        // Clamp at the edges rather than zero-padding, which would fade the
        // first and last milliseconds.
        final index = (frame + tap - half).clamp(0, frames - 1);
        acc += kernel[tap] * audio.samples[index * channels + channel];
      }
      out[frame * channels + channel] = acc.round().clamp(-32768, 32767);
    }
  }
  return PcmAudio(
    sampleRate: audio.sampleRate,
    channels: channels,
    samples: out,
  );
}
