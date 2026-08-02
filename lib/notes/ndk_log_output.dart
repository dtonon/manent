import 'package:ndk/ndk.dart';
import 'package:ndk/shared/logger/log_event.dart';

import 'sync_diagnostics.dart';

// Forwards NDK warnings/errors into SyncDiagnostics so release builds can
// surface the underlying relay error instead of NDK's generic message
class SyncDiagnosticsLogOutput implements LogOutput {
  @override
  void output(LogEvent event) {
    final error = event.error == null
        ? ''
        : ' [${event.error.runtimeType}] ${event.error}';
    SyncDiagnostics.instance
        .recordNdk(SyncDiagnostics.detail('${event.message}$error'));
  }

  @override
  void destroy() {}
}
