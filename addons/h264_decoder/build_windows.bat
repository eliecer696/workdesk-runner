@echo off
REM Build script for H264 Decoder GDExtension (Windows)
REM Prerequisites:
REM   1. Visual Studio 2022 with C++ workload
REM   2. Python 3.x with SCons: pip install scons
REM   3. FFmpeg shared libraries (run ../download_ffmpeg.ps1)

echo === H264 Decoder GDExtension Build Script ===

REM Check for godot-cpp
if not exist "godot-cpp" (
    echo Cloning godot-cpp...
    git clone --depth 1 --branch godot-4.2-stable https://github.com/godotengine/godot-cpp.git --recursive
)

REM Check for FFmpeg
REM Check for FFmpeg
if not exist "ffmpeg_windows" (
    echo.
    echo ERROR: FFmpeg not found at ffmpeg_windows!
    echo Please run setup_deps.ps1 first.
    pause
    exit /b 1
)

REM Set path for SCons
set FFMPEG_PATH=ffmpeg_windows
set FFMPEG_LIBS=avcodec.lib;avutil.lib;swscale.lib

REM Build godot-cpp first
echo Building godot-cpp...
cd godot-cpp
call scons platform=windows target=template_debug
cd ..

REM Build the extension
echo Building H264 Decoder...
call scons platform=windows target=template_debug

echo.
echo Build complete! Library should be in bin\windows\
pause
