import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart' as b;
import 'ogg.dart';

const _opusHead = [0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64]; // OpusHead
const _opusTags = [0x4F, 0x70, 0x75, 0x73, 0x54, 0x61, 0x67, 0x73]; // OpusTags
const _rate = 48000;
// Longest Opus packet is 120 ms
const _maxFrame = 5760;

class OpusDecodeException implements Exception {
  final String message;
  const OpusDecodeException(this.message);
  @override
  String toString() => 'OpusDecodeException: $message';
}

// Decoded Ogg Opus audio: always 48 kHz, 16-bit interleaved samples
class OpusPcm {
  final int channels;
  final Int16List samples;
  const OpusPcm({required this.channels, required this.samples});

  int get sampleRate => _rate;
  int get frameCount => channels == 0 ? 0 : samples.length ~/ channels;
  Duration get duration =>
      Duration(microseconds: frameCount * 1000000 ~/ _rate);
}

// True when the bytes are an Ogg container whose first stream is Opus
bool isOggOpus(Uint8List bytes) {
  if (!isOggStream(bytes)) return false;
  // Look for OpusHead in the first page body
  final limit = math.min(bytes.length, 27 + 255 + 8);
  for (var i = 27; i + 8 <= limit; i++) {
    var ok = true;
    for (var j = 0; j < 8; j++) {
      if (bytes[i + j] != _opusHead[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

String opusVersion() => b.opusGetVersionString().cast<Utf8>().toDartString();

OpusPcm decodeOggOpus(Uint8List bytes) {
  if (!isOggStream(bytes)) throw const OpusDecodeException('Not an Ogg stream');

  Pointer<b.OpusDecoder>? decoder;
  final errorPtr = calloc<Int>();
  Pointer<Uint8> packetBuf = nullptr;
  var packetCap = 0;
  Pointer<Int16> pcmBuf = nullptr;
  final chunks = <Int16List>[];
  var channels = 0;
  var preSkip = 0;
  var gainQ8 = 0;
  var totalFrames = 0;
  var lastGranule = -1;
  var index = 0;

  try {
    for (final packet in oggPackets(bytes, _opusHead)) {
      final data = packet.data;
      if (index == 0) {
        if (data.length < 19) throw const OpusDecodeException('Bad OpusHead');
        final bd = ByteData.sublistView(data);
        channels = data[9];
        preSkip = bd.getUint16(10, Endian.little);
        gainQ8 = bd.getInt16(16, Endian.little);
        final mapping = data[18];
        if (mapping != 0 || channels < 1 || channels > 2) {
          throw OpusDecodeException(
            'Unsupported channel mapping $mapping with $channels channels',
          );
        }
        decoder = b.opusDecoderCreate(_rate, channels, errorPtr);
        if (errorPtr.value != 0 || decoder == nullptr) {
          throw OpusDecodeException(
            'opus_decoder_create failed: ${errorPtr.value}',
          );
        }
        pcmBuf = calloc<Int16>(_maxFrame * channels);
        index++;
        continue;
      }
      if (index == 1) {
        // OpusTags: comment header, nothing to decode
        if (data.length < 8 || !_startsWith(data, _opusTags)) {
          throw const OpusDecodeException('Missing OpusTags');
        }
        index++;
        continue;
      }
      index++;
      if (data.isEmpty) continue;

      if (data.length > packetCap) {
        if (packetBuf != nullptr) calloc.free(packetBuf);
        packetCap = math.max(data.length, 4096);
        packetBuf = calloc<Uint8>(packetCap);
      }
      packetBuf.asTypedList(packetCap).setRange(0, data.length, data);
      final n = b.opusDecode(
        decoder!,
        packetBuf,
        data.length,
        pcmBuf,
        _maxFrame,
        0,
      );
      if (n < 0) throw OpusDecodeException('opus_decode failed: $n');
      chunks.add(Int16List.fromList(pcmBuf.asTypedList(n * channels)));
      totalFrames += n;
      if (packet.endsPage && packet.granule >= 0) lastGranule = packet.granule;
    }
  } finally {
    if (decoder != null && decoder != nullptr) b.opusDecoderDestroy(decoder);
    calloc.free(errorPtr);
    if (packetBuf != nullptr) calloc.free(packetBuf);
    if (pcmBuf != nullptr) calloc.free(pcmBuf);
  }

  if (channels == 0) throw const OpusDecodeException('No Opus stream found');

  // Trim the encoder pre-skip at the start and, when the final granule
  // position says so, the padding at the end
  var start = math.min(preSkip, totalFrames);
  var end = totalFrames;
  if (lastGranule >= 0) {
    final claimed = lastGranule - preSkip;
    if (claimed >= 0 && claimed < end - start) end = start + claimed;
  }
  final frames = math.max(0, end - start);
  final out = Int16List(frames * channels);
  var written = 0;
  var skip = start * channels;
  var remaining = frames * channels;
  for (final chunk in chunks) {
    if (remaining == 0) break;
    var from = 0;
    if (skip > 0) {
      final take = math.min(skip, chunk.length);
      skip -= take;
      from = take;
      if (from >= chunk.length) continue;
    }
    final count = math.min(chunk.length - from, remaining);
    out.setRange(written, written + count, chunk, from);
    written += count;
    remaining -= count;
  }

  if (gainQ8 != 0) _applyGain(out, gainQ8);
  return OpusPcm(channels: channels, samples: out);
}

bool _startsWith(Uint8List data, List<int> prefix) {
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) return false;
  }
  return true;
}

// OpusHead output gain, in Q7.8 dB
void _applyGain(Int16List samples, int gainQ8) {
  final factor = math.pow(10, gainQ8 / (20 * 256)).toDouble();
  for (var i = 0; i < samples.length; i++) {
    samples[i] = (samples[i] * factor).round().clamp(-32768, 32767);
  }
}
