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

static const int IMA_INDEX_TABLE[] = {
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8
};

static const int IMA_STEP_TABLE[] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
};

using namespace godot;

void H264Decoder::_bind_methods() {
    ClassDB::bind_method(D_METHOD("initialize", "expected_width", "expected_height"), &H264Decoder::initialize, DEFVAL(0), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("decode_frame", "h264_data"), &H264Decoder::decode_frame);
    ClassDB::bind_method(D_METHOD("get_width"), &H264Decoder::get_width);
    ClassDB::bind_method(D_METHOD("get_height"), &H264Decoder::get_height);
    ClassDB::bind_method(D_METHOD("is_initialized"), &H264Decoder::is_initialized);
    ClassDB::bind_method(D_METHOD("reset"), &H264Decoder::reset);
    ClassDB::bind_method(D_METHOD("cleanup"), &H264Decoder::cleanup);
    ClassDB::bind_method(D_METHOD("decode_audio", "adpcm_data"), &H264Decoder::decode_audio);
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
    
    if (!g_jvm) {
        // Fallback: Try to get the VM from JNI_GetCreatedJavaVMs
        JavaVM* vms[1];
        jsize num_vms = 0;
        if (JNI_GetCreatedJavaVMs(vms, 1, &num_vms) == JNI_OK && num_vms > 0) {
            g_jvm = vms[0];
            UtilityFunctions::print("[H264Decoder] JavaVM found via JNI_GetCreatedJavaVMs fallback.");
        }
    }

    if (g_jvm) {
        // Register JavaVM with FFmpeg so it can access MediaCodec
        if (av_jni_set_java_vm(g_jvm, nullptr) == 0) {
            UtilityFunctions::print("[H264Decoder] Registered JavaVM with FFmpeg.");
        } else {
            UtilityFunctions::printerr("[H264Decoder] Failed to register JavaVM with FFmpeg!");
        }
    } else {
        UtilityFunctions::printerr("[H264Decoder] JavaVM not found! (JNI_OnLoad not called and JNI_GetCreatedJavaVMs failed)");
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
    codec_ctx->thread_count = 0; // Auto-threading for better I-frame handling on mobile
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

PackedVector2Array H264Decoder::decode_audio(const PackedByteArray& adpcm_data) {
    PackedVector2Array result;
    int data_size = adpcm_data.size();
    if (data_size == 0) return result;

    // 2 samples per byte (High nibble L, Low nibble R)
    result.resize(data_size);
    Vector2* dst = result.ptrw();
    const uint8_t* src = adpcm_data.ptr();

    for (int i = 0; i < data_size; i++) {
        uint8_t byte = src[i];
        float sample_l = decode_sample_ima(byte >> 4, last_sample_l, last_index_l);
        float sample_r = decode_sample_ima(byte & 0x0F, last_sample_r, last_index_r);
        dst[i] = Vector2(sample_l, sample_r);
    }

    return result;
}

float H264Decoder::decode_sample_ima(uint8_t nibble, int& predicted, int& index) {
    int step = IMA_STEP_TABLE[index];
    
    // Calculate difference
    int diff = step >> 3;
    if (nibble & 4) diff += step;
    if (nibble & 2) diff += step >> 1;
    if (nibble & 1) diff += step >> 2;

    // Update predictor
    if (nibble & 8) predicted -= diff;
    else predicted += diff;

    // Clamp predictor to 16-bit PCM range
    if (predicted > 32767) predicted = 32767;
    else if (predicted < -32768) predicted = -32768;

    // Update index
    index += IMA_INDEX_TABLE[nibble];
    if (index < 0) index = 0;
    else if (index > 88) index = 88;

    // Return normalized float (-1.0 to 1.0)
    return (float)predicted / 32768.0f;
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
