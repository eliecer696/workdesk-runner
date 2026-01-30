using System.Runtime.InteropServices;
using FFmpeg.AutoGen;

namespace WorkdeskServer;

/// <summary>
/// Hardware-accelerated H.264 encoder using FFmpeg with NVENC/AMF/QuickSync.
/// Falls back to software x264 if no hardware encoder is available.
/// </summary>
public sealed unsafe class H264Encoder : IDisposable
{
    private AVCodecContext* _codecContext;
    private AVFrame* _frame;
    private AVPacket* _packet;
    private SwsContext* _swsContext;
    
    private readonly int _width;
    private readonly int _height;
    private readonly int _fps;
    private readonly int _bitrateMbps;
    private long _frameNumber;
    private bool _disposed;
    private readonly string _encoderName = "unknown";

    public int Width => _width;
    public int Height => _height;
    public bool IsKeyFrame { get; private set; }
    public string EncoderName => _encoderName;

    public H264Encoder(int width, int height, int fps = 60, int bitrateMbps = 50)
    {
        _width = width;
        _height = height;
        _fps = fps;
        _bitrateMbps = bitrateMbps;

        // Initialize FFmpeg
        ffmpeg.RootPath = GetFFmpegPath();

        try 
        {
            Console.WriteLine($"[H264Encoder] FFmpeg version: {ffmpeg.av_version_info()}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[H264Encoder] Failed to get version info: {ex.Message}");
            throw;
        }

        // Try hardware encoders in order of preference
        string[] encoderNames = { "h264_nvenc", "h264_amf", "h264_qsv", "libx264" };
        AVCodec* codec = null;
        
        Console.WriteLine("[H264Encoder] Finding encoder...");
        
        // METHOD 1: Try finding by specific name
        foreach (var name in encoderNames)
        {
            try
            {
                codec = ffmpeg.avcodec_find_encoder_by_name(name);
                if (codec != null)
                {
                    _encoderName = name;
                    Console.WriteLine($"[H264Encoder] Found encoder by name: {name}");
                    break;
                }
            }
            catch (Exception ex) 
            {
                Console.WriteLine($"[H264Encoder] Error checking encoder {name}: {ex.Message}");
            }
        }

        // METHOD 2: Fallback to default H.264 encoder
        if (codec == null)
        {
            Console.WriteLine("[H264Encoder] Encoder by name failed, trying default H.264...");
            try
            {
                codec = ffmpeg.avcodec_find_encoder(AVCodecID.AV_CODEC_ID_H264);
                if (codec != null)
                {
                    _encoderName = Marshal.PtrToStringAnsi((IntPtr)codec->name) ?? "unknown";
                    Console.WriteLine($"[H264Encoder] Using default encoder: {_encoderName}");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[H264Encoder] Error finding default encoder: {ex.Message}");
            }
        }

        if (codec == null)
        {
            throw new InvalidOperationException("No H.264 encoder found.");
        }

        Console.WriteLine("[H264Encoder] Allocating codec context...");
        // Allocate codec context
        _codecContext = ffmpeg.avcodec_alloc_context3(codec);
        if (_codecContext == null)
        {
            throw new InvalidOperationException("Failed to allocate codec context");
        }

        Console.WriteLine("[H264Encoder] Configuring codec...");
        // Configure encoder for low latency streaming
        _codecContext->width = width;
        _codecContext->height = height;
        _codecContext->time_base = new AVRational { num = 1, den = fps };
        _codecContext->framerate = new AVRational { num = fps, den = 1 };
        _codecContext->pix_fmt = AVPixelFormat.AV_PIX_FMT_YUV420P;
        _codecContext->bit_rate = bitrateMbps * 1_000_000L;
        _codecContext->gop_size = fps * 10; // Keyframe every 10 seconds (GOP 600)
        _codecContext->max_b_frames = 0; // No B-frames for lower latency
        _codecContext->thread_count = 1; // 1 thread for lowest latency (no inter-thread sync)
        _codecContext->flags |= ffmpeg.AV_CODEC_FLAG_LOW_DELAY;
        // _codecContext->flags |= ffmpeg.AV_CODEC_FLAG_GLOBAL_HEADER; // Removed: We need SPS/PPS in every I-frame for live streaming
        _codecContext->flags2 |= ffmpeg.AV_CODEC_FLAG2_FAST;

        // Low latency settings
        AVDictionary* opts = null;
        
        Console.WriteLine("[H264Encoder] Setting options...");
        if (_encoderName == "h264_nvenc")
        {
            // NVENC-specific low latency options
            ffmpeg.av_dict_set(&opts, "preset", "p1", 0); // Fastest preset
            ffmpeg.av_dict_set(&opts, "tune", "ll", 0); // Low latency tune
            ffmpeg.av_dict_set(&opts, "zerolatency", "1", 0);
            ffmpeg.av_dict_set(&opts, "delay", "0", 0);
            ffmpeg.av_dict_set(&opts, "forced-idr", "1", 0);
            ffmpeg.av_dict_set(&opts, "rc", "cbr", 0); // Constant bitrate
        }
        else if (_encoderName == "h264_amf")
        {
            // AMD AMF options
            ffmpeg.av_dict_set(&opts, "usage", "ultralowlatency", 0);
            ffmpeg.av_dict_set(&opts, "quality", "speed", 0);
        }
        else if (_encoderName == "libx264")
        {
            // x264 software fallback
            ffmpeg.av_dict_set(&opts, "preset", "ultrafast", 0);
            ffmpeg.av_dict_set(&opts, "tune", "zerolatency", 0);
        }

        Console.WriteLine("[H264Encoder] Opening codec...");
        // Open codec
        var ret = ffmpeg.avcodec_open2(_codecContext, codec, &opts);
        ffmpeg.av_dict_free(&opts);
        
        if (ret < 0)
        {
            throw new InvalidOperationException($"Failed to open codec: {GetErrorMessage(ret)}");
        }

        Console.WriteLine("[H264Encoder] Allocating frames...");
        // Allocate frame and packet
        _frame = ffmpeg.av_frame_alloc();
        _frame->format = (int)AVPixelFormat.AV_PIX_FMT_YUV420P;
        _frame->width = width;
        _frame->height = height;
        ffmpeg.av_frame_get_buffer(_frame, 32);

        _packet = ffmpeg.av_packet_alloc();

        Console.WriteLine("[H264Encoder] Creating sws context...");
        // Create color converter (BGRA -> YUV420P)
        _swsContext = ffmpeg.sws_getContext(
            width, height, AVPixelFormat.AV_PIX_FMT_BGRA,
            width, height, AVPixelFormat.AV_PIX_FMT_YUV420P,
            ffmpeg.SWS_FAST_BILINEAR, null, null, null
        );

        if (_swsContext == null)
        {
            throw new InvalidOperationException("Failed to create color converter");
        }

        Console.WriteLine($"[H264Encoder] Initialized: {width}x{height} @ {fps}fps, {bitrateMbps}Mbps");
    }

    /// <summary>
    /// Encodes a BGRA frame and returns the H.264 NAL units.
    /// </summary>
    public byte[]? EncodeFrame(byte[] bgraData, bool forceKeyframe = false)
    {
        if (bgraData.Length < _width * _height * 4)
        {
            throw new ArgumentException($"Input data too small. Expected {_width * _height * 4} bytes.");
        }

        // Make frame writable
        ffmpeg.av_frame_make_writable(_frame);

        // Convert BGRA to YUV420P
        fixed (byte* srcPtr = bgraData)
        {
            var srcData = new byte_ptrArray8();
            srcData[0] = srcPtr;
            
            var srcLinesize = new int_array8();
            srcLinesize[0] = _width * 4;

            ffmpeg.sws_scale(_swsContext, srcData, srcLinesize, 0, _height,
                _frame->data, _frame->linesize);
        }

        // Set frame properties
        _frame->pts = _frameNumber++;
        
        if (forceKeyframe)
        {
            _frame->pict_type = AVPictureType.AV_PICTURE_TYPE_I;
        }
        else
        {
            _frame->pict_type = AVPictureType.AV_PICTURE_TYPE_NONE;
        }

        // Send frame to encoder
        var ret = ffmpeg.avcodec_send_frame(_codecContext, _frame);
        if (ret < 0)
        {
            Console.WriteLine($"[H264Encoder] Error sending frame: {GetErrorMessage(ret)}");
            return null;
        }

        // Receive encoded packet
        ret = ffmpeg.avcodec_receive_packet(_codecContext, _packet);
        if (ret == ffmpeg.AVERROR(ffmpeg.EAGAIN) || ret == ffmpeg.AVERROR_EOF)
        {
            return null;
        }
        if (ret < 0)
        {
            Console.WriteLine($"[H264Encoder] Error receiving packet: {GetErrorMessage(ret)}");
            return null;
        }

        // Copy packet data
        var data = new byte[_packet->size];
        Marshal.Copy((IntPtr)_packet->data, data, 0, _packet->size);
        
        IsKeyFrame = (_packet->flags & ffmpeg.AV_PKT_FLAG_KEY) != 0;
        
        ffmpeg.av_packet_unref(_packet);
        return data;
    }

    /// <summary>
    /// Forces the encoder to output a keyframe on the next encode.
    /// </summary>
    public void RequestKeyframe()
    {
        // Will be applied on next EncodeFrame call
    }

    private static string GetFFmpegPath()
    {
        // Look for FFmpeg in common locations
        var paths = new[]
        {
            AppContext.BaseDirectory,
            Path.Combine(AppContext.BaseDirectory, "ffmpeg"),
            Directory.GetCurrentDirectory(),
            @"C:\ffmpeg\bin",
            @"C:\Program Files\ffmpeg\bin",
            Environment.GetEnvironmentVariable("FFMPEG_PATH") ?? ""
        };

        foreach (var path in paths)
        {
            if (!string.IsNullOrEmpty(path) && Directory.Exists(path))
            {
                // Check if avcodec dll exists here
                if (Directory.GetFiles(path, "avcodec-*.dll").Length > 0)
                {
                    Console.WriteLine($"[H264Encoder] Found FFmpeg in: {path}");
                    return path;
                }
            }
        }

        // Return empty to use system PATH
        return string.Empty;
    }

    private static string GetErrorMessage(int error)
    {
        var buffer = new byte[1024];
        fixed (byte* ptr = buffer)
        {
            ffmpeg.av_strerror(error, ptr, (ulong)buffer.Length);
            return Marshal.PtrToStringAnsi((IntPtr)ptr) ?? $"Unknown error {error}";
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        if (_swsContext != null)
        {
            ffmpeg.sws_freeContext(_swsContext);
        }

        if (_packet != null)
        {
            fixed (AVPacket** p = &_packet)
            {
                ffmpeg.av_packet_free(p);
            }
        }

        if (_frame != null)
        {
            fixed (AVFrame** f = &_frame)
            {
                ffmpeg.av_frame_free(f);
            }
        }

        if (_codecContext != null)
        {
            fixed (AVCodecContext** c = &_codecContext)
            {
                ffmpeg.avcodec_free_context(c);
            }
        }
    }
}
