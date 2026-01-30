/*
 * H264 Decoder GDExtension for Godot 4
 * Real-time H.264 NAL unit decoding using FFmpeg
 * 
 * Designed for low-latency streaming applications (VR headset desktop streaming)
 */

#ifndef H264_DECODER_H
#define H264_DECODER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
}

namespace godot {

class H264Decoder : public RefCounted {
    GDCLASS(H264Decoder, RefCounted)

private:
    AVCodecContext* codec_ctx = nullptr;
    AVFrame* frame = nullptr;
    AVFrame* frame_rgb = nullptr;
    AVPacket* packet = nullptr;
    SwsContext* sws_ctx = nullptr;
    
    int width = 0;
    int height = 0;
    bool initialized = false;
    
    PackedByteArray rgb_buffer;

    // Audio State (IMA ADPCM)
    int last_sample_l = 0;
    int last_index_l = 0;
    int last_sample_r = 0;
    int last_index_r = 0;
    
    // Internal helper for ADPCM
    float decode_sample_ima(uint8_t nibble, int& predicted, int& index);

protected:
    static void _bind_methods();

public:
    H264Decoder();
    ~H264Decoder();
    
    // Initialize decoder (optional - auto-inits on first frame)
    bool initialize(int expected_width = 0, int expected_height = 0);
    
    // Decode H.264 NAL units and return RGBA pixels
    // Input: Raw H.264 data (with or without start codes)
    // Output: RGBA pixel data (width * height * 4 bytes) or empty on error
    PackedByteArray decode_frame(const PackedByteArray& h264_data);
    
    // Audio: Decode IMA ADPCM (4:1) to PCM Stereo (Vector2)
    PackedVector2Array decode_audio(const PackedByteArray& adpcm_data);
    
    // Get decoded frame dimensions
    int get_width() const { return width; }
    int get_height() const { return height; }
    
    // Check if decoder is ready
    bool is_initialized() const { return initialized; }
    
    // Reset decoder state (call after stream interruption)
    void reset();
    
    // Clean up resources
    void cleanup();
};

} // namespace godot

#endif // H264_DECODER_H
