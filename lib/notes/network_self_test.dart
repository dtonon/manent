import 'dart:io';

import 'sync_diagnostics.dart';

// Bisects where relay connections fail by testing each network layer
// against one relay host; results land in the ndk trail of the raw-data
// modal. Desktop/mobile only (dart:io).
bool _running = false;

Future<void> runNetworkSelfTest({String host = 'nos.lol'}) async {
  if (_running) return;
  _running = true;
  final diag = SyncDiagnostics.instance;
  diag.clearSelfTest();
  diag.recordSelfTest('selftest started');

  Future<void> step(String name, Future<String?> Function() op) async {
    final sw = Stopwatch()..start();
    try {
      final extra = await op().timeout(const Duration(seconds: 8));
      diag.recordSelfTest(
          '$name: ok ${sw.elapsedMilliseconds}ms${extra == null ? '' : ' $extra'}');
    } catch (e) {
      diag.recordSelfTest(
          '$name: FAILED ${sw.elapsedMilliseconds}ms [${e.runtimeType}] ${SyncDiagnostics.detail(e)}');
    }
  }

  await step('dns $host', () async {
    final addrs = await InternetAddress.lookup(host);
    return addrs.map((a) => a.address).join(',');
  });

  await step('tcp $host:443', () async {
    final s = await Socket.connect(host, 443,
        timeout: const Duration(seconds: 6));
    s.destroy();
    return null;
  });

  await step('tls $host:443', () async {
    final s = await SecureSocket.connect(host, 443,
        timeout: const Duration(seconds: 6));
    s.destroy();
    return null;
  });

  await step('https GET $host', () async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('https://$host/'));
      final res = await req.close();
      await res.drain<void>();
      return 'HTTP ${res.statusCode}';
    } finally {
      client.close(force: true);
    }
  });

  await step('wss $host', () async {
    final ws = await WebSocket.connect('wss://$host');
    await ws.close();
    return null;
  });

  diag.recordSelfTest('selftest finished');
  _running = false;
}
