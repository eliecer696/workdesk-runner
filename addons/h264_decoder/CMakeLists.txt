cmake_minimum_required(VERSION 3.20)
project(h264_decoder)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Find godot-cpp (you need to set GODOT_CPP_PATH or have it in parent directory)
set(GODOT_CPP_PATH "${CMAKE_SOURCE_DIR}/godot-cpp" CACHE PATH "Path to godot-cpp")

# Find FFmpeg
set(FFMPEG_PATH "${CMAKE_SOURCE_DIR}/ffmpeg" CACHE PATH "Path to FFmpeg")

# Include directories
include_directories(
    ${CMAKE_SOURCE_DIR}/src
    ${GODOT_CPP_PATH}/include
    ${GODOT_CPP_PATH}/gen/include
    ${GODOT_CPP_PATH}/gdextension
    ${FFMPEG_PATH}/include
)

# Link directories
link_directories(
    ${GODOT_CPP_PATH}/bin
    ${FFMPEG_PATH}/lib
)

# Source files
file(GLOB_RECURSE SOURCES "src/*.cpp")

# Create shared library
add_library(h264_decoder SHARED ${SOURCES})

# Link libraries
if(WIN32)
    target_link_libraries(h264_decoder
        libgodot-cpp.windows.template_debug.x86_64
        avcodec
        avutil
        swscale
    )
elseif(ANDROID)
    target_link_libraries(h264_decoder
        godot-cpp.android.template_debug.arm64
        avcodec
        avutil
        swscale
    )
else()
    target_link_libraries(h264_decoder
        godot-cpp.linux.template_debug.x86_64
        avcodec
        avutil
        swscale
    )
endif()

# Set output directory
set_target_properties(h264_decoder PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/bin/${CMAKE_SYSTEM_NAME}
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/bin/${CMAKE_SYSTEM_NAME}
)
