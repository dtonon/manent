# Injected into the whisper_ggml_plus CMake build via CMAKE_PROJECT_INCLUDE
# (see android/build.gradle). The plugin forces GGML_NATIVE=OFF without
# setting GGML_CPU_ARM_ARCH, so arm64 compiles at the armv8-a baseline —
# without dotprod/fp16, the instructions the quantized kernels rely on.
# Not +i8mm: it needs armv8.6 (would crash Pixel 6/7-class CPUs). Devices
# older than armv8.2+dotprod are caught by a runtime check in SttService.
# Scoped to arm64-v8a; armeabi-v7a and x86_64 keep their defaults.
if(ANDROID_ABI STREQUAL "arm64-v8a")
  set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+fp16" CACHE STRING "" FORCE)
endif()
