import 'dart:typed_data';

class OggPacket {
  final Uint8List data;
  // Granule position of the page this packet ends on, -1 when the page
  // carries none (packet continues on the next page)
  final int granule;
  final bool endsPage;

  const OggPacket(this.data, this.granule, this.endsPage);
}

class OggFormatException implements Exception {
  final String message;
  const OggFormatException(this.message);
  @override
  String toString() => 'OggFormatException: $message';
}

bool isOggStream(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x4F &&
    bytes[1] == 0x67 &&
    bytes[2] == 0x67 &&
    bytes[3] == 0x53;

// Yields the packets of the first logical stream whose first packet starts
// with [magic] (e.g. "OpusHead"). Other interleaved streams are skipped.
// CRCs are not verified.
Iterable<OggPacket> oggPackets(Uint8List bytes, List<int> magic) sync* {
  final bd = ByteData.sublistView(bytes);
  int? serial;
  final pending = BytesBuilder(copy: false);
  var pos = 0;

  while (pos + 27 <= bytes.length) {
    if (!(bytes[pos] == 0x4F &&
        bytes[pos + 1] == 0x67 &&
        bytes[pos + 2] == 0x67 &&
        bytes[pos + 3] == 0x53)) {
      // Resync on the next capture pattern
      pos++;
      continue;
    }
    final headerType = bytes[pos + 5];
    final granule = bd.getInt64(pos + 6, Endian.little);
    final pageSerial = bd.getUint32(pos + 14, Endian.little);
    final segments = bytes[pos + 26];
    final lacingStart = pos + 27;
    if (lacingStart + segments > bytes.length) break;

    var bodyStart = lacingStart + segments;
    var bodyLength = 0;
    for (var i = 0; i < segments; i++) {
      bodyLength += bytes[lacingStart + i];
    }
    if (bodyStart + bodyLength > bytes.length) break;

    final isBos = headerType & 0x02 != 0;
    final isContinued = headerType & 0x01 != 0;

    if (serial == null) {
      if (isBos && segments > 0) {
        final first = bytes[lacingStart];
        if (first >= magic.length) {
          var match = true;
          for (var i = 0; i < magic.length; i++) {
            if (bytes[bodyStart + i] != magic[i]) {
              match = false;
              break;
            }
          }
          if (match) serial = pageSerial;
        }
      }
      if (serial == null) {
        pos = bodyStart + bodyLength;
        continue;
      }
    } else if (pageSerial != serial) {
      pos = bodyStart + bodyLength;
      continue;
    }

    if (!isContinued && pending.isNotEmpty) {
      // A new page without the continuation flag drops the unfinished packet
      pending.clear();
    }

    var offset = bodyStart;
    for (var i = 0; i < segments; i++) {
      final lace = bytes[lacingStart + i];
      pending.add(Uint8List.sublistView(bytes, offset, offset + lace));
      offset += lace;
      if (lace < 255) {
        final last = i == segments - 1;
        yield OggPacket(pending.takeBytes(), last ? granule : -1, last);
      }
    }
    // A final 255 lace means the packet continues on the next page

    pos = bodyStart + bodyLength;
    if (headerType & 0x04 != 0) break; // end of stream
  }
}
