# Shared by the Android, Linux and Windows builds: compiles the vendored ggml
# and whisper statically and links them into one whisper_ggml_plus shared
# library that exports the FFI entry points.

set(WHISPER_PLUGIN_ROOT "${CMAKE_CURRENT_LIST_DIR}/..")
set(WHISPER_PLUGIN_CLASSES "${WHISPER_PLUGIN_ROOT}/darwin/Classes")
set(WHISPER_ROOT_DIR "${WHISPER_PLUGIN_CLASSES}/whisper")
set(WHISPER_SRC_DIR "${WHISPER_ROOT_DIR}/src")
set(GGML_ROOT_DIR "${WHISPER_ROOT_DIR}/ggml")

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build vendored libs static" FORCE)
set(GGML_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GGML_CPU ON CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "Never tune for the build machine" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
set(GGML_ACCELERATE OFF CACHE BOOL "" FORCE)
set(GGML_METAL OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_ALL_WARNINGS OFF CACHE BOOL "" FORCE)
set(WHISPER_ALL_WARNINGS OFF CACHE BOOL "" FORCE)
set(WHISPER_COREML OFF CACHE BOOL "" FORCE)
set(WHISPER_OPENVINO OFF CACHE BOOL "" FORCE)

# Desktop x86-64 baseline: AVX2 + FMA + F16C (Intel Haswell 2013+, AMD Zen)
if(NOT ANDROID AND CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$")
  set(GGML_SSE42 ON CACHE BOOL "" FORCE)
  set(GGML_AVX ON CACHE BOOL "" FORCE)
  set(GGML_AVX2 ON CACHE BOOL "" FORCE)
  set(GGML_FMA ON CACHE BOOL "" FORCE)
  set(GGML_F16C ON CACHE BOOL "" FORCE)
  set(GGML_BMI2 OFF CACHE BOOL "" FORCE)
  set(GGML_AVX512 OFF CACHE BOOL "" FORCE)
endif()

add_compile_definitions(
  WHISPER_VERSION=\"1.8.3\"
  GGML_USE_CPU
)

# ggml and whisper declare install rules with relative destinations. Inside a
# Flutter app the install prefix is a generator expression, which the install
# script cannot expand, so the install step fails. EXCLUDE_FROM_ALL keeps their
# install scripts out of the parent's; the targets still build as dependencies
# of the plugin, which is bundled through the Flutter bundled-libraries list.
add_subdirectory("${GGML_ROOT_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/ggml" EXCLUDE_FROM_ALL)
add_subdirectory("${WHISPER_SRC_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/whisper" EXCLUDE_FROM_ALL)

add_library(whisper_ggml_plus SHARED
  "${WHISPER_PLUGIN_CLASSES}/whisper_ggml_plus.cpp"
)

target_include_directories(whisper_ggml_plus PRIVATE
  "${WHISPER_PLUGIN_CLASSES}"
  "${WHISPER_ROOT_DIR}"
  "${WHISPER_ROOT_DIR}/include"
  "${GGML_ROOT_DIR}/include"
)

target_link_libraries(whisper_ggml_plus PRIVATE whisper)

set_target_properties(whisper_ggml_plus PROPERTIES
  OUTPUT_NAME "whisper_ggml_plus"
)
