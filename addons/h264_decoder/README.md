# H264 Decoder GDExtension

Real-time H.264 NAL unit decoder for Godot 4.2+, designed for low-latency VR streaming applications.

## Features
- **Hardware acceleration**: MediaCodec (Android/Quest), NVDEC (NVIDIA desktop)
- **Software fallback**: libx264 when no hardware decoder available
- **Low latency**: Optimized for real-time streaming (no buffering)
- **Simple API**: `decode_frame(PackedByteArray) -> PackedByteArray`

## Building (Windows)

### Prerequisites
1. Visual Studio 2022 with C++ workload
2. Python 3.x with SCons: `pip install scons`
3. Git

### Steps

```bash
cd addons/h264_decoder

# 1. Set up FFmpeg (copy from parent ffmpeg-temp folder)
mkdir ffmpeg
xcopy /E ..\..\ffmpeg-temp\ffmpeg-5.1.2-full_build-shared\include ffmpeg\include\
xcopy /E ..\..\ffmpeg-temp\ffmpeg-5.1.2-full_build-shared\lib ffmpeg\lib\

# 2. Run build script
build_windows.bat
```

Or manually:
```bash
# Clone godot-cpp
git clone --depth 1 --branch godot-4.2-stable https://github.com/godotengine/godot-cpp.git --recursive

# Build godot-cpp
cd godot-cpp
scons platform=windows target=template_debug
cd ..

# Build extension
set FFMPEG_PATH=ffmpeg
scons platform=windows target=template_debug
```

## Building (Android/Quest)

```bash
# On Linux/macOS
make bootstrap
make gdextension PLATFORM=android TARGET_ARCH=arm64-v8a
```

## Usage in GDScript

```gdscript
var decoder = H264Decoder.new()

func _on_frame_received(h264_data: PackedByteArray):
    var rgba = decoder.decode_frame(h264_data)
    if rgba.size() > 0:
        var w = decoder.get_width()
        var h = decoder.get_height()
        var image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, rgba)
        texture.update(image)
```

## API Reference

| Method | Description |
|--------|-------------|
| `decode_frame(data: PackedByteArray) -> PackedByteArray` | Decode H.264 frame, returns RGBA pixels |
| `get_width() -> int` | Get decoded frame width |
| `get_height() -> int` | Get decoded frame height |
| `is_initialized() -> bool` | Check if decoder is ready |
| `reset()` | Reset decoder state (call after stream interruption) |
| `cleanup()` | Free all resources |

## License
MIT License - Uses FFmpeg (LGPL) for decoding.
