import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

const _standardDirs = ['/usr/bin', '/bin', '/usr/local/bin'];

typedef _GetenvC = Pointer<Uint8> Function(Pointer<Uint8>);
typedef _SetenvC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Int32);
typedef _SetenvDart = int Function(Pointer<Uint8>, Pointer<Uint8>, int);
typedef _MallocC = Pointer<Uint8> Function(IntPtr);
typedef _MallocDart = Pointer<Uint8> Function(int);
typedef _FreeC = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);

bool _isExecutable(String path) {
  final stat = FileStat.statSync(path);
  return stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0;
}

String? _findIn(Iterable<String> dirs) {
  for (final d in dirs) {
    if (d.isNotEmpty && _isExecutable('$d/parecord')) return d;
  }
  return null;
}

/// The record plugin spawns `parecord` by bare name. When the app is started
/// with a PATH that misses its folder, this adds it. Must run first in main:
/// Dart snapshots the environment on the first Platform.environment read and
/// hands that snapshot to every child process.
void addParecordToPath() {
  if (!Platform.isLinux) return;
  try {
    final libc = DynamicLibrary.process();
    final getenv = libc.lookupFunction<_GetenvC, _GetenvC>('getenv');
    final setenv = libc.lookupFunction<_SetenvC, _SetenvDart>('setenv');
    final malloc = libc.lookupFunction<_MallocC, _MallocDart>('malloc');
    final free = libc.lookupFunction<_FreeC, _FreeDart>('free');

    Pointer<Uint8> cString(String s) {
      final bytes = utf8.encode(s);
      final ptr = malloc(bytes.length + 1);
      ptr.asTypedList(bytes.length + 1)
        ..setAll(0, bytes)
        ..[bytes.length] = 0;
      return ptr;
    }

    final name = cString('PATH');
    final current = getenv(name);
    var path = '';
    if (current != nullptr) {
      var n = 0;
      while (current[n] != 0) {
        n++;
      }
      path = utf8.decode(current.asTypedList(n), allowMalformed: true);
    }
    final dirs = path.split(':');
    final missing = _findIn(dirs) == null ? _findIn(_standardDirs) : null;
    if (missing != null) {
      final value =
          cString([...dirs.where((d) => d.isNotEmpty), missing].join(':'));
      setenv(name, value, 1);
      free(value);
    }
    free(name);
  } catch (_) {}
}

bool parecordInstalled() =>
    _findIn([
      ...(Platform.environment['PATH'] ?? '').split(':'),
      ..._standardDirs,
    ]) !=
    null;
