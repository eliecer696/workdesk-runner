/*
 * H264 Decoder GDExtension Implementation
 * Uses FFmpeg libavcodec for H.264 decoding
 */

#include "h264_decoder.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

// FFmpeg JNI wrapper
extern "C" {
#include <libavcodec/jni.h>
}

using namespace godot;

void H264Decoder::_bind_methods() {
    ClassDB::bind_method(D_METHOD("initialize", "expected_width", "expected_height"), &H264Decoder::initialize, DEFVAL(0), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("decode_frame", "h264_data"), &H264Decoder::decode_frame);
    ClassDB::bind_method(D_METHOD("get_width"), &H264Decoder::get_width);
    ClassDB::bind_method(D_METHOD("get_height"), &H264Decoder::get_height);
    ClassDB::bind_method(D_METHOD("is_initialized"), &H264Decoder::is_initialized);
    ClassDB::bind_method(D_METHOD("reset"), &H264Decoder::reset);
    ClassDB::bind_method(D_METHOD("cleanup"), &H264Decoder::cleanup);
}

H264Decoder::H264Decoder() {
    // Decoder will be initialized on first frame or explicit call
}

H264Decoder::~H264Decoder() {
    cleanup();
}

bool H264Decoder::initialize(int expected_width, int expected_height) {
    if (initialized) {
        return true;
    }

    // Find H.264 decoder (prefer hardware)
    const AVCodec* codec = nullptr;
    
    // Check for Android platform using Godot's define or standard define
    #if defined(__ANDROID__) || defined(ANDROID_ENABLED)
    UtilityFunctions::print("[H264Decoder] Android platform detected.");

    // Removed JNI/MediaCodec support due to stability issues
    // Falling back to software decoder logic
    #else
    // Try NVDEC on desktop
    codec = avcodec_find_decoder_by_name("h264_cuvid");
    if (codec) {
        UtilityFunctions::print("[H264Decoder] Using NVDEC hardware decoder");
    }
    #endif
    
    // Fall back to software decoder
    if (!codec) {
        codec = avcodec_find_decoder(AV_CODEC_ID_H264);
        if (codec) {
            UtilityFunctions::print("[H264Decoder] Using software H.264 decoder");
        }
    }
    
    if (!codec) {
        UtilityFunctions::printerr("[H264Decoder] No H.264 decoder found!");
        return false;
    }

    codec_ctx = avcodec_alloc_context3(codec);
    if (!codec_ctx) {
        UtilityFunctions::printerr("[H264Decoder] Failed to allocate codec context");
        return false;
    }

    // Configure for low latency
    codec_ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
    codec_ctx->flags2 |= AV_CODEC_FLAG2_FAST;
    codec_ctx->thread_count = 0; // Auto

    if (avcodec_open2(codec_ctx, codec, nullptr) < 0) {
        UtilityFunctions::printerr("[H264Decoder] Failed to open codec");
        avcodec_free_context(&codec_ctx);
        return false;
    }

    frame = av_frame_alloc();
    frame_rgb = av_frame_alloc();
    packet = av_packet_alloc();

    if (!frame || !frame_rgb || !packet) {
        UtilityFunctions::printerr("[H264Decoder] Failed to allocate frames/packet");
        cleanup();
        return false;
    }

    width = expected_width;
    height = expected_height;
    initialized = true;
    
    UtilityFunctions::print("[H264Decoder] Initialized successfully");
    return true;
}

PackedByteArray H264Decoder::decode_frame(const PackedByteArray& h264_data) {
    PackedByteArray result;
    
    if (h264_data.size() == 0) {
        return result;
    }

    // Auto-initialize if needed
    if (!initialized) {
        if (!initialize()) {
            return result;
        }
    }

    // UtilityFunctions::print("[H264] Decode start. Bytes: ", h264_data.size());

    // Set packet data
    packet->data = const_cast<uint8_t*>(h264_data.ptr());
    packet->size = h264_data.size();

    // Send packet to decoder
    int ret = avcodec_send_packet(codec_ctx, packet);
    if (ret < 0 && ret != AVERROR(EAGAIN)) {
        UtilityFunctions::printerr("[H264] Send packet failed: ", ret);
        if (ret != AVERROR_EOF) {
            return result;
        }
    }

    // Receive decoded frame
    ret = avcodec_receive_frame(codec_ctx, frame);
    if (ret < 0) {
        if (ret != AVERROR(EAGAIN)) {
            UtilityFunctions::printerr("[H264] Receive frame failed: ", ret);
        }
        return result;
    }

    // UtilityFunctions::print("[H264] Got frame: ", frame->width, "x", frame->height, " fmt:", frame->format);

    // Update dimensions and scaler if needed
    if (frame->width != width || frame->height != height || !sws_ctx) {
        width = frame->width;
        height = frame->height;
        
        if (sws_ctx) {
            sws_freeContext(sws_ctx);
        }
        
        sws_ctx = sws_getContext(
            width, height, (AVPixelFormat)frame->format,
            width, height, AV_PIX_FMT_RGBA,
            SWS_BILINEAR, nullptr, nullptr, nullptr
        );
        
        if (!sws_ctx) {
            UtilityFunctions::printerr("[H264] Failed to create scaler");
            return result;
        }
        
        // Resize buffer only when dim changes
        int buffer_size = av_image_get_buffer_size(AV_PIX_FMT_RGBA, width, height, 1); // Align 1 for tight packing
        rgb_buffer.resize(buffer_size);
        UtilityFunctions::print("[H264] Resized buffer to: ", buffer_size);
    }

    // SAFETY: Re-fill arrays every time because Godot's PackedByteArray ptrW can change
    // Also using alignment 1 to match Godot's packed expectation if needed, though 32 is usually safer for FFmpeg.
    // Let's force 1 for safety with pure byte array copying? No, 32 is standard.
    // Ensure the resize was sufficient.
    int buffer_size = av_image_get_buffer_size(AV_PIX_FMT_RGBA, width, height, 1);
    
    // Check buffer size
    if (rgb_buffer.size() < buffer_size) {
         rgb_buffer.resize(buffer_size);
    }

    av_image_fill_arrays(
        frame_rgb->data, frame_rgb->linesize,
        rgb_buffer.ptrw(), AV_PIX_FMT_RGBA,
        width, height, 1
    );

    // UtilityFunctions::print("[H264] Scaling...");
    // Convert to RGBA
    sws_scale(sws_ctx,
        frame->data, frame->linesize, 0, height,
        frame_rgb->data, frame_rgb->linesize
    );

    // Copy to output buffer (RGBA, 4 bytes per pixel)
    int output_size = width * height * 4;
    result.resize(output_size);
    if (result.size() != output_size) {
          UtilityFunctions::printerr("[H264] Result resize failed");
          return result;
    }
    
    // UtilityFunctions::print("[H264] Copying to result...");
    memcpy(result.ptrw(), rgb_buffer.ptr(), output_size);

    return result;
}

void H264Decoder::reset() {
    if (codec_ctx) {
        avcodec_flush_buffers(codec_ctx);
    }
    UtilityFunctions::print("[H264Decoder] Reset");
}

void H264Decoder::cleanup() {
    if (sws_ctx) {
        sws_freeContext(sws_ctx);
        sws_ctx = nullptr;
    }
    if (frame) {
        av_frame_free(&frame);
        frame = nullptr;
    }
    if (frame_rgb) {
        av_frame_free(&frame_rgb);
        frame_rgb = nullptr;
    }
    if (packet) {
        av_packet_free(&packet);
        packet = nullptr;
    }
    if (codec_ctx) {
        avcodec_free_context(&codec_ctx);
        codec_ctx = nullptr;
    }
    
    initialized = false;
    width = 0;
    height = 0;
    rgb_buffer.clear();
}
