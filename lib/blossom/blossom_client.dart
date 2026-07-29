import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:ndk/ndk.dart';

import '../notes/sync_diagnostics.dart';

class BlossomClient {
  // Follows 3xx redirects for a body-carrying request, re-sending method +
  // body + headers (dart:io does not resend the body on 307/308 by default,
  // so a proxy's http→https 308 would otherwise surface as a failure).
  static Future<http.Response> _sendFollowingRedirects(
    String method,
    Uri uri,
    Map<String, String> headers,
    Uint8List? body,
    Duration timeout,
  ) async {
    var target = uri;
    for (var i = 0; i < 5; i++) {
      final request = http.Request(method, target)
        ..headers.addAll(headers)
        ..followRedirects = false;
      if (body != null) request.bodyBytes = body;

      final streamed = await request.send().timeout(timeout);
      final response = await http.Response.fromStream(streamed);

      final isRedirect = response.statusCode >= 300 &&
          response.statusCode < 400 &&
          response.headers['location'] != null;
      if (!isRedirect) return response;

      target = target.resolve(response.headers['location']!);
    }
    throw Exception('too many redirects');
  }

  // Uploads encrypted bytes to a Blossom server using BUD-01 auth.
  // Returns the blob URL on success, or the failure reason on error.
  static Future<({String? url, String? error})> upload({
    required String server,
    required Uint8List data,
    required String sha256,
    required EventSigner signer,
  }) async {
    final uri = _upgradeScheme(Uri.parse('$server/upload'));
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

      final response = await _sendFollowingRedirects(
        'PUT',
        uri,
        {
          'Authorization': authHeader,
          'Content-Type': 'application/octet-stream',
        },
        data,
        const Duration(seconds: 60),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final url = _urlFromBody(response.body);
        if (url != null) return (url: url, error: null);
        return (
          url: null,
          error: 'HTTP ${response.statusCode} but no usable "url" in body: '
              '${SyncDiagnostics.detail(response.body)}'
        );
      }
      // Blossom servers put the rejection detail in X-Reason (BUD-01)
      final reason = response.headers['x-reason'] ?? response.body;
      return (
        url: null,
        error: 'HTTP ${response.statusCode} ${SyncDiagnostics.detail(reason)}'
      );
    } catch (e) {
      return (
        url: null,
        error: '${e.runtimeType}: ${SyncDiagnostics.detail(e)}'
      );
    }
  }

  static String? _urlFromBody(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['url'] as String?;
    } catch (_) {
      return null;
    }
  }

  // Deletes a blob from a Blossom server using BUD-01 auth. Best-effort.
  static Future<void> delete({
    required String server,
    required String sha256,
    required EventSigner signer,
  }) async {
    final uri = _upgradeScheme(Uri.parse('$server/$sha256'));
    try {
      final expiration =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
      final authEvent = Nip01Event(
        pubKey: signer.getPublicKey(),
        kind: 24242,
        tags: [
          ['t', 'delete'],
          ['x', sha256],
          ['expiration', expiration.toString()],
        ],
        content: 'Delete blob',
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      final signed = await signer.sign(authEvent);
      final eventJson = jsonEncode(Nip01EventModel.fromEntity(signed).toJson());
      final authHeader = 'Nostr ${base64Encode(utf8.encode(eventJson))}';

      await _sendFollowingRedirects(
        'DELETE',
        uri,
        {'Authorization': authHeader},
        null,
        const Duration(seconds: 30),
      );
    } catch (_) {}
  }

  static Future<Uint8List?> download(String url) async {
    try {
      final response = await http
          .get(_upgradeScheme(Uri.parse(url)))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode == 200) return response.bodyBytes;
      return null;
    } catch (_) {
      return null;
    }
  }

  // Upgrades http→https for public hosts. A Blossom server reachable over http
  // typically redirects to https, and the browser refuses to follow a redirect
  // on a CORS preflight, so we request https up front. Local/LAN hosts (which
  // may be http-only) are left untouched.
  static Uri _upgradeScheme(Uri uri) {
    if (uri.scheme != 'http') return uri;
    final host = uri.host;
    final isLocal = host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host.endsWith('.local') ||
        host.startsWith('192.168.') ||
        host.startsWith('10.') ||
        host.startsWith('172.16.');
    if (isLocal) return uri;
    return uri.replace(scheme: 'https');
  }
}

