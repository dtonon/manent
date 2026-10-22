cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "whisper_ggml_plus")
project(${PROJECT_NAME} LANGUAGES C CXX)

include("${CMAKE_CURRENT_LIST_DIR}/../cmake/whisper_plugin.cmake")

target_compile_definitions(${PROJECT_NAME} PRIVATE
  _CRT_SECURE_NO_WARNINGS
)

if(NOT CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  set(whisper_ggml_plus_bundled_libraries
    $<TARGET_FILE:${PROJECT_NAME}>
    PARENT_SCOPE
  )
endif()
