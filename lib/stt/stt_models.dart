import 'dart:io';

// Offered whisper models — multilingual only, never the .en variants.
// Quantized (q5) files: near-identical accuracy at a fraction of the
// download size and RAM. Identified by fileName, not the package's enum,
// because transcription passes an explicit modelPath.
class SttModelInfo {
  final String fileName;
  final String label;
  final String sizeLabel;
  final String quality;
  final String? qualityMobile;
  final bool desktopOnly;

  const SttModelInfo({
    required this.fileName,
    required this.label,
    required this.sizeLabel,
    required this.quality,
    this.qualityMobile,
    this.desktopOnly = false,
  });

  String get qualityLabel =>
      sttIsDesktop ? quality : (qualityMobile ?? quality);

  Uri get url => Uri.parse(
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$fileName');
}

const sttModelCatalog = [
  SttModelInfo(
    fileName: 'ggml-base-q5_1.bin',
    label: 'Base',
    sizeLabel: '59 MB',
    quality: 'Fast, basic accuracy',
    qualityMobile: 'Recommended on phones, basic accuracy',
  ),
  SttModelInfo(
    fileName: 'ggml-small-q5_1.bin',
    label: 'Small',
    sizeLabel: '190 MB',
    quality: 'Recommended, good accuracy',
    qualityMobile: 'Good accuracy, slow on phones',
  ),
  SttModelInfo(
    fileName: 'ggml-large-v3-turbo-q5_0.bin',
    label: 'Large v3 Turbo',
    sizeLabel: '574 MB',
    quality: 'Best accuracy, needs a fast machine',
    desktopOnly: true,
  ),
];

bool get sttIsDesktop =>
    Platform.isLinux || Platform.isMacOS || Platform.isWindows;

List<SttModelInfo> get sttOfferedModels =>
    sttModelCatalog.where((m) => !m.desktopOnly || sttIsDesktop).toList();
