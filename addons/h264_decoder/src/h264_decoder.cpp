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

#if defined(__ANDROID__) || defined(ANDROID_ENABLED)
#include <jni.h>
static JavaVM *g_jvm = nullptr;

// JNI_OnLoad is called when the shared library is loaded by the JVM/Android
extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    g_jvm = vm;
    // Don't log here as Godot IO might not be ready, or use standard printf
    return JNI_VERSION_1_6;
}
#endif

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
    
    if (g_jvm) {
        // Register JavaVM with FFmpeg so it can access MediaCodec
        if (av_jni_set_java_vm(g_jvm, nullptr) == 0) {
            UtilityFunctions::print("[H264Decoder] Registered JavaVM with FFmpeg.");
        } else {
            UtilityFunctions::printerr("[H264Decoder] Failed to register JavaVM with FFmpeg!");
        }
    } else {
        UtilityFunctions::printerr("[H264Decoder] JavaVM not found! (JNI_OnLoad not called?)");
    }

    UtilityFunctions::print("[H264Decoder] Checking for h264_mediacodec...");
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
    codec_ctx->thread_count = 1; // 1 thread for lowest latency (no inter-thread buffer delay)
    codec_ctx->thread_type = FF_THREAD_SLICE;

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

    // ═══════════════════════════════════════════════════════════════════════════
    // OPTIMIZATION: Return raw YUV data instead of converting to RGBA with sws_scale
    // This effectively 0-copies the heavy lifting to the GPU shader.
    // ═══════════════════════════════════════════════════════════════════════════

    // Update dimensions if changed
    if (frame->width != width || frame->height != height) {
        width = frame->width;
        height = frame->height;
        UtilityFunctions::print("[H264Decoder] Frame size: ", width, "x", height, 
            " Fmt:", (int)frame->format, " (Outputting YUV)");
    }

    // Prepare YUV buffer (Y + U + V)
    // Assuming YUV420P: Y is full res, U and V are half width/height
    int y_size = width * height;
    int uv_width = width / 2; 
    int uv_height = height / 2;
    int uv_size = uv_width * uv_height;
    int total_size = y_size + (uv_size * 2);

    result.resize(total_size);
    uint8_t* dst = result.ptrw();
    uint8_t* uv_dst_start = dst + y_size;

    // 1. Copy Y Plane (Plane 0 is always Y)
    if (frame->data[0]) {
        for (int i = 0; i < height; i++) {
            memcpy(dst + (i * width), frame->data[0] + (i * frame->linesize[0]), width);
        }
    }

    // 2. Determine Invalidity (Green Screen check)
    // If planes are missing OR all zeros, we must force Grey.
    bool u_missing = !frame->data[1];
    bool v_missing = !frame->data[2] && (frame->format != AV_PIX_FMT_NV12 && frame->format != AV_PIX_FMT_NV21);
    
    bool u_invalid = false;
    bool v_invalid = false;
    
    if (!u_missing) {
        // Validation: Check multiple points. Only if ALL are 0 do we assume it's uninitialized.
        // This prevents false positives on dark pixels.
        u_invalid = (frame->data[1][0] == 0 && 
                     frame->data[1][uv_width/2] == 0 && 
                     frame->data[1][uv_width-1] == 0 &&
                     frame->data[1][uv_size/4] == 0 &&
                     frame->data[1][uv_size/2] == 0 &&
                     frame->data[1][uv_size-1] == 0);
    }
    if (!v_missing && frame->data[2]) {
        v_invalid = (frame->data[2][0] == 0 && 
                     frame->data[2][uv_width/2] == 0 && 
                     frame->data[2][uv_width-1] == 0 &&
                     frame->data[2][uv_size/4] == 0 &&
                     frame->data[2][uv_size/2] == 0 &&
                     frame->data[2][uv_size-1] == 0);
    }

    // 3. NUCLEAR ACTION: Pre-fill UV with Grey if anything is fishy
    // We use || because if either color channel is dead, the image is distorted.
    if (u_missing || v_missing || u_invalid || v_invalid) {
         memset(uv_dst_start, 128, uv_size * 2);
    }

    // 4. Coping based on format
    if (frame->format == AV_PIX_FMT_YUV420P || frame->format == AV_PIX_FMT_YUVJ420P) {
        if (!u_missing && !v_missing) {
            for (int i = 0; i < uv_height; i++) {
                uint8_t* row_dst = uv_dst_start + (i * width);
                memcpy(row_dst, frame->data[1] + (i * frame->linesize[1]), uv_width);
                memcpy(row_dst + uv_width, frame->data[2] + (i * frame->linesize[2]), uv_width);
            }
        }
    } 
    else if (frame->format == AV_PIX_FMT_NV12 || frame->format == AV_PIX_FMT_NV21) {
        if (!u_missing) {
            bool is_nv12 = (frame->format == AV_PIX_FMT_NV12);
            for (int i = 0; i < uv_height; i++) {
                uint8_t* row_dst = uv_dst_start + (i * width);
                uint8_t* uv_src_row = frame->data[1] + (i * frame->linesize[1]);
                for (int x = 0; x < uv_width; x++) {
                    row_dst[x] = is_nv12 ? uv_src_row[x * 2] : uv_src_row[x * 2 + 1];
                    row_dst[uv_width + x] = is_nv12 ? uv_src_row[x * 2 + 1] : uv_src_row[x * 2];
                }
            }
        }
    }
    else if (frame->format == AV_PIX_FMT_YUV422P || frame->format == AV_PIX_FMT_YUVJ422P) {
        // Sample every other row for 420 conversion
        if (!u_missing && !v_missing) {
            for (int i = 0; i < uv_height; i++) {
                uint8_t* row_dst = uv_dst_start + (i * width);
                memcpy(row_dst, frame->data[1] + (i * 2 * frame->linesize[1]), uv_width);
                memcpy(row_dst + uv_width, frame->data[2] + (i * 2 * frame->linesize[2]), uv_width);
            }
        }
    }
    else {
        static int warn_count = 0;
        if (warn_count++ % 100 == 0) {
             UtilityFunctions::printerr("[H264Decoder] Unknown frame format: ", (int)frame->format);
        }
    }

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
