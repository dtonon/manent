Pod::Spec.new do |s|
  s.name             = 'whisper_ggml_plus'
  s.version          = '1.5.2'
  s.summary          = 'Whisper.cpp Flutter plugin with Large-v3-Turbo support.'
  s.description      = <<-DESC
Whisper.cpp Flutter plugin with Large-v3-Turbo (128-mel) support, vendored.
                       DESC
  s.homepage         = 'https://github.com/DDULDDUCK/whisper_ggml_plus'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'DDULDDUCK' => 'https://github.com/DDULDDUCK' }
  s.source           = { :path => '.' }

  s.ios.deployment_target = '12.0'
  s.osx.deployment_target = '10.15'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'

  s.source_files = 'Classes/**/*.{cpp,c,h,hpp,m,mm}'
  # ggml expects exactly one arch directory per build and CocoaPods compiles
  # every file for every slice, so only the ARM kernels stay in. iOS excludes
  # the x86_64 simulator slice below; the macOS x86_64 slice is handled by the
  # app's Podfile (drops arch/arm and defines GGML_CPU_GENERIC for that arch).
  s.exclude_files = '**/*.metal',
                    'Classes/whisper/ggml/src/ggml-cpu/arch/x86/**/*',
                    'Classes/whisper/ggml/src/ggml-cpu/arch/powerpc/**/*',
                    'Classes/whisper/ggml/src/ggml-cpu/arch/loongarch/**/*',
                    'Classes/whisper/ggml/src/ggml-cpu/arch/riscv/**/*',
                    'Classes/whisper/ggml/src/ggml-cpu/arch/s390/**/*',
                    'Classes/whisper/ggml/src/ggml-cpu/arch/wasm/**/*'
  # CoreML glue is written for ARC; ggml-metal and vad_helper manage memory manually
  s.requires_arc = ['Classes/whisper/src/coreml/*.{m,mm}']
  s.public_header_files = 'Classes/whisper/include/whisper.h'

  # Prebuilt Metal shaders, one library per platform (see scripts/)
  s.ios.resource_bundles = { 'whisper_ggml_plus' => ['Resources/ios/default.metallib'] }
  s.osx.resource_bundles = { 'whisper_ggml_plus' => ['Resources/macos/default.metallib'] }

  whisper_flags = "-DWHISPER_GGML_PLUS_NATIVE_VAD -DWHISPER_USE_COREML -DWHISPER_COREML_ALLOW_FALLBACK -DGGML_USE_METAL=1 -DGGML_USE_CPU -DWHISPER_VERSION='\"1.8.3\"' -DGGML_VERSION='\"0.9.5\"' -DGGML_COMMIT='\"unknown\"'"
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_CFLAGS' => whisper_flags,
    'OTHER_CPLUSPLUSFLAGS' => whisper_flags,
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/Classes/whisper" "$(PODS_TARGET_SRCROOT)/Classes/whisper/include" "$(PODS_TARGET_SRCROOT)/Classes/whisper/src" "$(PODS_TARGET_SRCROOT)/Classes/whisper/src/coreml" "$(PODS_TARGET_SRCROOT)/Classes/whisper/ggml/include" "$(PODS_TARGET_SRCROOT)/Classes/whisper/ggml/src" "$(PODS_TARGET_SRCROOT)/Classes/whisper/ggml/src/ggml-cpu"',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++'
  }
  s.ios.pod_target_xcconfig = {
    'IPHONEOS_DEPLOYMENT_TARGET' => '12.0',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64'
  }
  s.osx.pod_target_xcconfig = {
    'MACOSX_DEPLOYMENT_TARGET' => '10.15'
  }

  s.frameworks = 'CoreML', 'Metal', 'Foundation'
  s.ios.frameworks = 'Accelerate'
  s.swift_version = '5.0'
end
