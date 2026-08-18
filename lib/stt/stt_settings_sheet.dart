import 'package:flutter/material.dart';

import '../theme.dart';
import 'stt_model_manager.dart';
import 'stt_models.dart';

Future<void> showSttSettingsSheet(BuildContext context,
    {bool explainFirstUse = false}) async {
  await SttModelManager.instance.init();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _SttSettingsSheet(explainFirstUse: explainFirstUse),
  );
}

class _SttSettingsSheet extends StatelessWidget {
  final bool explainFirstUse;

  const _SttSettingsSheet({required this.explainFirstUse});

  static const _languages = [
    ('auto', 'Auto detect'),
    ('it', 'Italian'),
    ('en', 'English'),
  ];

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;
    final manager = SttModelManager.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([
        manager.activeModel,
        manager.language,
        manager.downloaded,
        manager.downloading,
        manager.downloadProgress,
      ]),
      builder: (context, _) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Voice transcription',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  if (explainFirstUse) ...[
                    const SizedBox(height: 8),
                    Text(
                      'To transcribe voice notes, download a speech model '
                      'first. Transcription runs fully on this device — '
                      'audio never leaves it.',
                      style:
                          TextStyle(fontSize: 13, color: mc.secondaryText),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text('Language',
                      style:
                          TextStyle(fontSize: 12, color: mc.secondaryText)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final (code, label) in _languages)
                        ChoiceChip(
                          label: Text(label),
                          selected: manager.language.value == code,
                          onSelected: (_) => manager.setLanguage(code),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('Model',
                      style:
                          TextStyle(fontSize: 12, color: mc.secondaryText)),
                  for (final info in sttOfferedModels)
                    _modelTile(context, info, manager),
                  const SizedBox(height: 8),
                  Text(
                    'Models are downloaded once and stored on this device.',
                    style: TextStyle(fontSize: 12, color: mc.secondaryText),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: explainFirstUse && manager.hasDownloadedModel
                        ? Semantics(
                            label: 'Start recording',
                            button: true,
                            child: ElevatedButton.icon(
                              onPressed: () => Navigator.pop(context),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: accent,
                                foregroundColor: Colors.white,
                              ),
                              icon: const Icon(Icons.mic_none),
                              label: const Text('Start recording'),
                            ),
                          )
                        : TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Close'),
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _modelTile(
      BuildContext context, SttModelInfo info, SttModelManager manager) {
    final isDownloaded = manager.downloaded.value.contains(info.fileName);
    final isActive = manager.activeModel.value?.fileName == info.fileName;
    final isDownloading = manager.downloading.value == info.fileName;
    final busy = manager.downloading.value != null;

    final Widget trailing;
    if (isDownloading) {
      final progress = manager.downloadProgress.value;
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, value: progress),
          ),
          const SizedBox(width: 8),
          Text(progress != null ? '${(progress * 100).round()}%' : '…'),
          IconButton(
            tooltip: 'Cancel download',
            icon: const Icon(Icons.close),
            onPressed: manager.cancelDownload,
          ),
        ],
      );
    } else if (isDownloaded) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isActive)
            Semantics(
              label: 'Active model',
              child: const Icon(Icons.check_circle, color: accent),
            )
          else
            TextButton(
              onPressed: () => manager.setActive(info),
              child: const Text('Use'),
            ),
          IconButton(
            tooltip: 'Delete model',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(context, info),
          ),
        ],
      );
    } else {
      trailing = TextButton(
        onPressed: busy ? null : () => _download(context, info),
        child: const Text('Download'),
      );
    }

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('${info.label} · ${info.sizeLabel}',
          style: const TextStyle(fontSize: 14)),
      subtitle: Text(info.qualityLabel, style: const TextStyle(fontSize: 12)),
      trailing: trailing,
    );
  }

  Future<void> _download(BuildContext context, SttModelInfo info) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await SttModelManager.instance.download(info);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    }
  }

  Future<void> _confirmDelete(BuildContext context, SttModelInfo info) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete model'),
        content: Text(
            'Delete the ${info.label} model (${info.sizeLabel}) from this '
            'device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await SttModelManager.instance.delete(info);
    }
  }
}
