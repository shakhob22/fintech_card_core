# cardcv — shared OpenCV pre-processing core (consumed from Dart via FFI).
#
# Two build flavours:
#   * With OpenCV  — pass -DOPENCV_ANDROID_SDK=/path/to/OpenCV-android-sdk
#                    (the plugin's build.gradle.kts forwards the
#                    `fintechCardCore.opencvAndroidSdk` Gradle property or the
#                    OPENCV_ANDROID_SDK environment variable automatically).
#   * Stub         — no OpenCV available; compiles a no-op library so consumer
#                    builds never break. The Dart layer detects this at runtime
#                    via cardcv_available() and falls back to the platform
#                    (ML Kit / Vision) preprocessing path.

cmake_minimum_required(VERSION 3.18)
project(cardcv LANGUAGES CXX)

add_library(cardcv SHARED cardcv.cpp)

set_target_properties(cardcv PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  CXX_VISIBILITY_PRESET hidden
)

if(DEFINED OPENCV_ANDROID_SDK)
  # Official free OpenCV Android SDK: https://opencv.org/releases/
  set(OpenCV_DIR "${OPENCV_ANDROID_SDK}/sdk/native/jni")
  find_package(OpenCV REQUIRED COMPONENTS core imgproc)
  target_include_directories(cardcv PRIVATE ${OpenCV_INCLUDE_DIRS})
  target_link_libraries(cardcv ${OpenCV_LIBS})
  target_compile_definitions(cardcv PRIVATE CARDCV_HAS_OPENCV=1)
  message(STATUS "cardcv: building WITH OpenCV from ${OpenCV_DIR}")
else()
  target_compile_definitions(cardcv PRIVATE CARDCV_HAS_OPENCV=0)
  message(STATUS "cardcv: OpenCV SDK not provided — building runtime stub. "
                 "Set fintechCardCore.opencvAndroidSdk to enable the native "
                 "pre-processing pipeline.")
endif()
