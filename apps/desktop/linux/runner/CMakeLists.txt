cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES C CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "clipboard_image.cc"
  "frame_pacing.cc"
  "wayland/presentation-time-protocol.c"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)
# Compositor frame callbacks and presentation feedback (frame_pacing.cc;
# wayland/ holds wayland-scanner output for presentation-time.xml).
pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::WAYLAND_CLIENT)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
# The embedder API types (frame_pacing.cc), from the SDK's engine sources.
include("${CMAKE_CURRENT_SOURCE_DIR}/../flutter/ephemeral/generated_config.cmake")
target_include_directories(${BINARY_NAME} PRIVATE
  "${FLUTTER_ROOT}/engine/src/flutter/shell/platform/embedder")
