/*
 * H264 Decoder GDExtension Implementation
 * Uses FFmpeg libavcodec for H.264 decoding
 */

#include "h264_decoder.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

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
    UtilityFunctions::print("[H264Decoder] Android platform detected, checking for h264_mediacodec");
    codec = avcodec_find_decoder_by_name("h264_mediacodec");
    if (codec) {
        UtilityFunctions::print("[H264Decoder] Found h264_mediacodec! Using hardware decoding.");
    } else {
        UtilityFunctions::print("[H264Decoder] h264_mediacodec not found in FFmpeg build.");
    }
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

    // Set packet data
    packet->data = const_cast<uint8_t*>(h264_data.ptr());
    packet->size = h264_data.size();

    // Send packet to decoder
    int ret = avcodec_send_packet(codec_ctx, packet);
    if (ret < 0 && ret != AVERROR(EAGAIN)) {
        // Not an error if decoder needs more data
        if (ret != AVERROR_EOF) {
            return result;
        }
    }

    // Receive decoded frame
    ret = avcodec_receive_frame(codec_ctx, frame);
    if (ret < 0) {
        // EAGAIN means we need to send more packets
        // This is normal for the first few frames
        return result;
    }

    // Update dimensions if changed
    if (frame->width != width || frame->height != height) {
        width = frame->width;
        height = frame->height;
        
        // Recreate scaler
        if (sws_ctx) {
            sws_freeContext(sws_ctx);
        }
        
        sws_ctx = sws_getContext(
            width, height, (AVPixelFormat)frame->format,
            width, height, AV_PIX_FMT_RGBA,
            SWS_FAST_BILINEAR, nullptr, nullptr, nullptr
        );
        
        if (!sws_ctx) {
            UtilityFunctions::printerr("[H264Decoder] Failed to create scaler");
            return result;
        }
        
        // Allocate RGB buffer
        int buffer_size = av_image_get_buffer_size(AV_PIX_FMT_RGBA, width, height, 32);
        rgb_buffer.resize(buffer_size);
        
        av_image_fill_arrays(
            frame_rgb->data, frame_rgb->linesize,
            rgb_buffer.ptrw(), AV_PIX_FMT_RGBA,
            width, height, 32
        );
        
        UtilityFunctions::print("[H264Decoder] Frame size: ", width, "x", height);
    }

    // Convert to RGBA
    sws_scale(sws_ctx,
        frame->data, frame->linesize, 0, height,
        frame_rgb->data, frame_rgb->linesize
    );

    // Copy to output buffer (RGBA, 4 bytes per pixel)
    int output_size = width * height * 4;
    result.resize(output_size);
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
