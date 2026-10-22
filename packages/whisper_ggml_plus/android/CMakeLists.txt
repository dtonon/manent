cmake_minimum_required(VERSION 3.22.1)

project(whisper_ggml_plus LANGUAGES C CXX)

# ggml compiles arm64 at the armv8-a baseline unless told otherwise, without
# the dotprod/fp16 instructions the quantized kernels rely on. Not +i8mm: it
# needs armv8.6 and would crash Pixel 6/7-class CPUs. Devices older than
# armv8.2+dotprod are caught by a runtime check in the app (SttService).
if(ANDROID_ABI STREQUAL "arm64-v8a")
  set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+fp16" CACHE STRING "" FORCE)
endif()

include("${CMAKE_CURRENT_LIST_DIR}/../cmake/whisper_plugin.cmake")

find_library(LOG_LIB log)
find_library(ATOMIC_LIB atomic)

target_link_libraries(whisper_ggml_plus PRIVATE ${LOG_LIB})
if(ATOMIC_LIB)
  target_link_libraries(whisper_ggml_plus PRIVATE ${ATOMIC_LIB})
endif()

# 16 KB page alignment required by Android 15+
target_link_options(whisper_ggml_plus PRIVATE
  $<$<OR:$<STREQUAL:${ANDROID_ABI},arm64-v8a>,$<STREQUAL:${ANDROID_ABI},x86_64>>:LINKER:-z,max-page-size=16384>
  $<$<OR:$<STREQUAL:${ANDROID_ABI},arm64-v8a>,$<STREQUAL:${ANDROID_ABI},x86_64>>:LINKER:-z,common-page-size=16384>
)
