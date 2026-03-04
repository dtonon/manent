import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:ndk/ndk.dart';

class BlossomClient {
  // Uploads encrypted bytes to a Blossom server using BUD-01 auth.
  // Returns the blob URL on success, null on failure.
  static Future<String?> upload({
    required String server,
    required Uint8List data,
    required String sha256,
    required EventSigner signer,
  }) async {
    try {
      final expiration =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
      final authEvent = Nip01Event(
        pubKey: signer.getPublicKey(),
        kind: 24242,
        tags: [
          ['t', 'upload'],
          ['x', sha256],
          ['expiration', expiration.toString()],
        ],
        content: 'Upload blob',
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      final signed = await signer.sign(authEvent);
      final eventJson = jsonEncode(Nip01EventModel.fromEntity(signed).toJson());
      final authHeader = 'Nostr ${base64Encode(utf8.encode(eventJson))}';

      final uri = Uri.parse('${server.trimRight()}/upload');
      final response = await http
          .put(
            uri,
            headers: {
              'Authorization': authHeader,
              'Content-Type': 'application/octet-stream',
            },
            body: data,
          )
          .timeout(const Duration(seconds: 60));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return json['url'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> download(String url) async {
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode == 200) return response.bodyBytes;
      return null;
    } catch (_) {
      return null;
    }
  }
}

