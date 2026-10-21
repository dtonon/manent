import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

// Compiles the vendored libopus 1.4 (float build, generic C, no CPU-specific
// paths) into one dynamic library registered under the asset id of
// lib/src/bindings.dart, so its @Native symbols resolve to it.
void main(List<String> args) async {
  await build(args, (input, output) async {
    // Web builds run the hook but request no code assets
    if (!input.config.buildCodeAssets) return;

    final targetOS = input.config.code.targetOS;
    final root = input.packageRoot.resolve('src/opus/');

    List<String> listC(String dir) {
      final files =
          Directory.fromUri(root.resolve(dir))
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.c'))
              .map((f) => 'src/opus/$dir/${f.uri.pathSegments.last}')
              .toList()
            ..sort();
      return files;
    }

    final sources = [
      ...listC('celt'),
      ...listC('silk'),
      ...listC('silk/float'),
      ...listC('src'),
    ];

    // On Windows native_toolchain_c runs cl.exe through cmd.exe, whose 8191
    // character limit the 136 absolute source paths exceed. A response file
    // carries them instead; cl.exe accepts @file anywhere on its command line.
    final useResponseFile = targetOS == OS.windows;
    Uri? responseFile;
    if (useResponseFile) {
      await Directory.fromUri(input.outputDirectory).create(recursive: true);
      responseFile = input.outputDirectory.resolve('opus_sources.rsp');
      final lines = sources
          .map((s) => '"${input.packageRoot.resolve(s).toFilePath()}"')
          .join('\r\n');
      await File.fromUri(responseFile).writeAsString('$lines\r\n');
      // CBuilder only registers the sources it is given
      output.dependencies.addAll(sources.map(input.packageRoot.resolve));
    }

    final builder = CBuilder.library(
      name: 'opus_decode',
      assetName: 'src/bindings.dart',
      sources: useResponseFile ? const [] : sources,
      flags: [if (responseFile != null) '@${responseFile.toFilePath()}'],
      includes: [
        'src/opus/include',
        'src/opus/celt',
        'src/opus/silk',
        'src/opus/silk/float',
        'src/opus/src',
      ],
      defines: {
        'OPUS_BUILD': null,
        // Temporary buffers on the stack via alloca: works on every compiler,
        // unlike C99 VLAs which MSVC lacks
        'USE_ALLOCA': null,
        'HAVE_LRINT': null,
        'HAVE_LRINTF': null,
        if (targetOS == OS.windows) '_CRT_SECURE_NO_WARNINGS': null,
        // Keeps alloca and friends visible under a strict C standard on glibc
        if (targetOS != OS.windows) '_GNU_SOURCE': null,
      },
      forcedIncludes: ['src/opus_config.h'],
      libraries: [if (targetOS == OS.android || targetOS == OS.linux) 'm'],
      language: Language.c,
    );
    await builder.run(input: input, output: output);
  });
}
