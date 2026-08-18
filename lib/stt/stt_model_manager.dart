import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stt_models.dart';

class SttModelManager {
  SttModelManager._();
  static final instance = SttModelManager._();

  static const _activeModelKey = 'stt_active_model';
  static const _languageKey = 'stt_language';
  // Anything smaller than this is an error page, not a model
  static const _minModelBytes = 10 * 1024 * 1024;

  final activeModel = ValueNotifier<SttModelInfo?>(null);
  // 'auto' | 'it' | 'en'
  final language = ValueNotifier<String>('auto');
  // Downloaded and in-flight models, keyed by fileName
  final downloaded = ValueNotifier<Set<String>>(const {});
  final downloading = ValueNotifier<String?>(null);
  final downloadProgress = ValueNotifier<double?>(null);

  Future<void>? _initFuture;
  http.Client? _downloadClient;
  bool _cancelRequested = false;

  bool get hasDownloadedModel => downloaded.value.isNotEmpty;

  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    language.value = prefs.getString(_languageKey) ?? 'auto';

    final found = <String>{};
    for (final info in sttModelCatalog) {
      final f = File(await pathFor(info));
      if (await f.exists() && await f.length() >= _minModelBytes) {
        found.add(info.fileName);
      }
    }
    downloaded.value = found;

    final savedName = prefs.getString(_activeModelKey);
    activeModel.value = sttModelCatalog
            .where((i) => i.fileName == savedName && found.contains(i.fileName))
            .firstOrNull ??
        sttModelCatalog
            .where((i) => found.contains(i.fileName))
            .firstOrNull;
  }

  Future<String> modelsDir() async {
    final dir = await getApplicationSupportDirectory();
    final models = Directory(p.join(dir.path, 'stt_models'));
    if (!await models.exists()) await models.create(recursive: true);
    return models.path;
  }

  Future<String> pathFor(SttModelInfo info) async =>
      p.join(await modelsDir(), info.fileName);

  Future<void> setActive(SttModelInfo info) async {
    activeModel.value = info;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeModelKey, info.fileName);
  }

  Future<void> setLanguage(String lang) async {
    language.value = lang;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, lang);
  }

  // Streams to a .part file, verifies the size, then renames into place
  Future<void> download(SttModelInfo info) async {
    if (downloading.value != null) return;
    await init();
    downloading.value = info.fileName;
    downloadProgress.value = null;
    _cancelRequested = false;
    final client = http.Client();
    _downloadClient = client;
    final part = File('${await pathFor(info)}.part');
    try {
      final response = await client.send(http.Request('GET', info.url));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final total = response.contentLength ?? 0;
      var received = 0;
      final sink = part.openWrite();
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) downloadProgress.value = received / total;
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if ((total > 0 && received != total) || received < _minModelBytes) {
        throw const HttpException('Incomplete download');
      }
      await part.rename(await pathFor(info));
      downloaded.value = {...downloaded.value, info.fileName};
      if (activeModel.value == null) await setActive(info);
    } catch (e) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      if (!_cancelRequested) rethrow;
    } finally {
      client.close();
      _downloadClient = null;
      downloading.value = null;
      downloadProgress.value = null;
    }
  }

  void cancelDownload() {
    _cancelRequested = true;
    _downloadClient?.close();
  }

  Future<void> delete(SttModelInfo info) async {
    final f = File(await pathFor(info));
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
    downloaded.value = {...downloaded.value}..remove(info.fileName);
    if (activeModel.value?.fileName == info.fileName) {
      final next = sttModelCatalog
          .where((i) => downloaded.value.contains(i.fileName))
          .firstOrNull;
      activeModel.value = next;
      final prefs = await SharedPreferences.getInstance();
      if (next != null) {
        await prefs.setString(_activeModelKey, next.fileName);
      } else {
        await prefs.remove(_activeModelKey);
      }
    }
  }
}
