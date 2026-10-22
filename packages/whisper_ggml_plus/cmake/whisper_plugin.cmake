# Shared by the Android, Linux and Windows builds: compiles the vendored ggml
# and whisper and links them into one whisper_ggml_plus shared library that
# exports the FFI entry points.
#
# Desktop x86-64 uses runtime CPU dispatch: ggml is built as shared libraries
# with one CPU backend per instruction-set level (x64, SSE4.2, AVX, AVX2,
# AVX-512, ...), and the wrapper loads the best one for the running CPU. A
# single static baseline either crashes older CPUs with SIGILL or leaves
# newer ones slow. Android keeps a static single-variant build.

set(WHISPER_PLUGIN_ROOT "${CMAKE_CURRENT_LIST_DIR}/..")
set(WHISPER_PLUGIN_CLASSES "${WHISPER_PLUGIN_ROOT}/darwin/Classes")
set(WHISPER_ROOT_DIR "${WHISPER_PLUGIN_CLASSES}/whisper")
set(WHISPER_SRC_DIR "${WHISPER_ROOT_DIR}/src")
set(GGML_ROOT_DIR "${WHISPER_ROOT_DIR}/ggml")

if(NOT ANDROID AND CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$")
  set(WHISPER_CPU_DISPATCH_DEFAULT ON)
else()
  set(WHISPER_CPU_DISPATCH_DEFAULT OFF)
endif()
option(WHISPER_CPU_DISPATCH "Build every ggml CPU variant and pick one at runtime" ${WHISPER_CPU_DISPATCH_DEFAULT})

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

set(GGML_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GGML_CPU ON CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "Never tune for the build machine" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
set(GGML_ACCELERATE OFF CACHE BOOL "" FORCE)
set(GGML_METAL OFF CACHE BOOL "" FORCE)
set(GGML_ALL_WARNINGS OFF CACHE BOOL "" FORCE)
set(WHISPER_ALL_WARNINGS OFF CACHE BOOL "" FORCE)
set(WHISPER_COREML OFF CACHE BOOL "" FORCE)
set(WHISPER_OPENVINO OFF CACHE BOOL "" FORCE)

add_compile_definitions(WHISPER_VERSION=\"1.8.3\")

if(WHISPER_CPU_DISPATCH)
  set(BUILD_SHARED_LIBS ON CACHE BOOL "ggml shared, loaded per CPU variant" FORCE)
  set(GGML_BACKEND_DL ON CACHE BOOL "" FORCE)
  set(GGML_CPU_ALL_VARIANTS ON CACHE BOOL "" FORCE)
  # The plugin, ggml and the variants land side by side in the app bundle
  set(CMAKE_BUILD_RPATH "$ORIGIN")
  set(CMAKE_BUILD_RPATH_USE_ORIGIN ON)
else()
  set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build vendored libs static" FORCE)
  set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
  set(GGML_CPU_ALL_VARIANTS OFF CACHE BOOL "" FORCE)
  add_compile_definitions(GGML_USE_CPU)
endif()

# ggml and whisper declare install rules with relative destinations. Inside a
# Flutter app the install prefix is a generator expression, which the install
# script cannot expand, so the install step fails. EXCLUDE_FROM_ALL keeps their
# install scripts out of the parent's; the targets still build as dependencies
# of the plugin, which is bundled through the Flutter bundled-libraries list.
# ggml only ever appends to this cached list; reset it so a reconfigure in the
# same build dir cannot reference variants from a previous run
unset(GGML_AVAILABLE_BACKENDS CACHE)
add_subdirectory("${GGML_ROOT_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/ggml" EXCLUDE_FROM_ALL)

if(WHISPER_CPU_DISPATCH)
  # Whisper itself stays inside the plugin library
  set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
endif()

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

target_link_libraries(whisper_ggml_plus PRIVATE whisper ${CMAKE_DL_LIBS})

set_target_properties(whisper_ggml_plus PROPERTIES
  OUTPUT_NAME "whisper_ggml_plus"
)

set(WHISPER_PLUGIN_BUNDLED_LIBRARIES $<TARGET_FILE:whisper_ggml_plus>)

if(WHISPER_CPU_DISPATCH)
  target_compile_definitions(whisper_ggml_plus PRIVATE WHISPER_GGML_PLUS_CPU_DISPATCH)
  # Flutter copies the real files only, so versioned sonames would break the
  # lookup: strip them, every library is referenced by its plain name
  set(WHISPER_GGML_SHARED_TARGETS ggml-base ggml ${GGML_AVAILABLE_BACKENDS})
  foreach(target ${WHISPER_GGML_SHARED_TARGETS})
    set_property(TARGET ${target} PROPERTY VERSION)
    set_property(TARGET ${target} PROPERTY SOVERSION)
    list(APPEND WHISPER_PLUGIN_BUNDLED_LIBRARIES $<TARGET_FILE:${target}>)
  endforeach()
endif()
