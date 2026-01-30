using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using System.Windows.Forms;
using NAudio.Wave;
using NAudio.CoreAudioApi;

namespace WorkdeskServer;

internal static class Program
{
    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION - Optimized for Virtual Desktop-like performance
    // ═══════════════════════════════════════════════════════════════════════════
    private const int Port = 9000;
    private const int TargetFps = 60;           // Match monitor refresh rate as requested
    private const int BitrateMbps = 15;         // High bitrate for 5G (v3.7)
    private const int MaxClients = 4;
    private const bool UseHardwareCapture = true;   // DXGI vs GDI+
    private const bool UseH264Encoding = true;      // H.264 vs JPEG fallback
    private const bool EnableAudio = true;          // System Audio Loopback
    private const int AudioSampleRate = 48000;      // CD Quality
    private const int AudioChannels = 2;            // Stereo

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════
    private static readonly ConcurrentDictionary<Guid, ClientState> Clients = new();
    private static Channel<CapturedFrame>? _captureChannel;
    private static Channel<EncodedFrame>? _encodeChannel;
    private static DxgiCapture? _dxgiCapture;
    private static H264Encoder? _h264Encoder;
    private static IWaveIn? _audioCapture;
    private static Channel<byte[]>? _audioChannel;
    private static bool _requestKeyframe = false;
    private static long _frameCount = 0;
    
    // Pipeline Debugging Counters
    private static long _capturedCount = 0;
    private static long _encodedCount = 0;
    private static long _sentCount = 0;
    private static long _audioSentCount = 0;
    
    // Constant Stream State
    private static byte[]? _lastFrameBuffer = null;
    private static int _lastWidth = 0;
    private static int _lastHeight = 0;
    
    // Win32 imports
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    private const uint MOUSEEVENTF_RIGHTUP = 0x0010;

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")] private static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

    // ═══════════════════════════════════════════════════════════════════════════
    // DATA TYPES
    // ═══════════════════════════════════════════════════════════════════════════
    private record CapturedFrame(byte[] Data, int Width, int Height, float CursorU, float CursorV, long FrameNumber);
    private record EncodedFrame(byte[] Data, float CursorU, float CursorV, bool IsKeyFrame, long FrameNumber);
    
    private class ClientState
    {
        public WebSocket Socket { get; init; } = null!;
        public bool NeedsKeyframe { get; set; } = true;
        public long LastFrameSent { get; set; } = -1;
    }

    [StructLayout(LayoutKind.Sequential)]
    public class PointerMessage
    {
        public string Type { get; set; } = "";
        public float U { get; set; }
        public float V { get; set; }
        public bool Pressed { get; set; }
        public bool Down { get; set; }
        public bool Up { get; set; }
        public int Button { get; set; } = 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MAIN
    // ═══════════════════════════════════════════════════════════════════════════
    public static async Task Main(string[] args)
    {
        Console.WriteLine("╔══════════════════════════════════════════════════════════════╗");
        Console.WriteLine("║          Workdesk VR Streaming Server (Optimized)            ║");
        Console.WriteLine("║          Using Virtual Desktop-style architecture            ║");
        Console.WriteLine("╚══════════════════════════════════════════════════════════════╝");

        // Create async channels for pipeline
        _captureChannel = Channel.CreateBounded<CapturedFrame>(new BoundedChannelOptions(120)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = true
        });

        _encodeChannel = Channel.CreateBounded<EncodedFrame>(new BoundedChannelOptions(120)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = true
        });

        _audioChannel = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(200)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = true
        });

        // Start pipeline tasks
        var cts = new CancellationTokenSource();
        var captureTask = Task.Run(() => CaptureLoopAsync(cts.Token));
        var encodeTask = Task.Run(() => EncodeLoopAsync(cts.Token));
        var sendTask = Task.Run(() => SendLoopAsync(cts.Token));
        var audioTask = EnableAudio ? Task.Run(() => AudioLoopAsync(cts.Token)) : Task.CompletedTask;

        // Start web server
        var builder = WebApplication.CreateBuilder(args);
        builder.WebHost.UseUrls("http://0.0.0.0:80", "http://0.0.0.0:9000");
        var app = builder.Build();

        app.UseWebSockets();
        app.MapGet("/", () => Results.Text("Workdesk VR server running (optimized)"));
        app.Map("/ws", HandleWebSocketAsync);

        Console.WriteLine($"[Server] Target: {TargetFps} FPS, {BitrateMbps} Mbps");
        Console.WriteLine($"[Server] Capture: {(UseHardwareCapture ? "DXGI (GPU)" : "GDI+ (CPU)")}");
        Console.WriteLine($"[Server] Encoding: {(UseH264Encoding ? "H.264 Hardware" : "JPEG Fallback")}");
        Console.WriteLine($"[Server] Encoding: {(UseH264Encoding ? "H.264 Hardware" : "JPEG Fallback")}");
        Console.WriteLine("[Server] Listening on ports 80, 9000");

        // Helper loop to print occasional stats
        _ = Task.Run(async () => {
             while (!cts.IsCancellationRequested) {
                 await Task.Delay(5000);
                 Console.WriteLine($"[Stats] Capture Mode: {(_dxgiCapture != null ? "DXGI" : "GDI+")} | " +
                     $"Cap: {_capturedCount} Enc: {_encodedCount} VideoSent: {_sentCount} AudioSent: {_audioSentCount}");
             }
        });

        await app.RunAsync();
        
        cts.Cancel();
        await Task.WhenAll(captureTask, encodeTask, sendTask, audioTask);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WEBSOCKET HANDLER
    // ═══════════════════════════════════════════════════════════════════════════
    private static async Task HandleWebSocketAsync(HttpContext context)
    {
        if (!context.WebSockets.IsWebSocketRequest)
        {
            context.Response.StatusCode = 400;
            return;
        }

        var socket = await context.WebSockets.AcceptWebSocketAsync();
        var id = Guid.NewGuid();
        var clientState = new ClientState { Socket = socket, NeedsKeyframe = true };
        Clients[id] = clientState;

        Console.WriteLine($"[Server] Client connected: {id} (total: {Clients.Count})");
        
        // Request keyframe for new client
        _requestKeyframe = true;
        Console.WriteLine($"[Server] Keyframe requested for new client {id}");

        await ReceiveLoopAsync(socket, id);
    }

    private static async Task ReceiveLoopAsync(WebSocket socket, Guid id)
    {
        var buffer = new byte[4096];
        try
        {
            while (socket.State == WebSocketState.Open)
            {
                var result = await socket.ReceiveAsync(buffer, CancellationToken.None);
                if (result.MessageType == WebSocketMessageType.Close)
                    break;

                if (result.MessageType == WebSocketMessageType.Text)
                {
                    var text = Encoding.UTF8.GetString(buffer, 0, result.Count);
                    HandleClientMessage(text, id);
                }
            }
        }
        catch { }
        finally
        {
            Clients.TryRemove(id, out _);
            Console.WriteLine($"[Server] Client disconnected: {id} (remaining: {Clients.Count})");
            try { await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "Closing", CancellationToken.None); } catch { }
        }
    }

    private static void HandleClientMessage(string text, Guid clientId)
    {
        try
        {
            var msg = JsonSerializer.Deserialize<PointerMessage>(text);
            if (msg == null) return;

            switch (msg.Type)
            {
                case "pointer":
                    HandlePointerMessage(msg);
                    break;
                case "request_keyframe":
                    if (Clients.TryGetValue(clientId, out var client))
                        client.NeedsKeyframe = true;
                    _requestKeyframe = true;
                    Console.WriteLine($"[Server] Force keyframe requested by client {clientId}");
                    break;
            }
        }
        catch { }
    }

    private static void HandlePointerMessage(PointerMessage msg)
    {
        var screenWidth = GetSystemMetrics(0);
        var screenHeight = GetSystemMetrics(1);
        var x = (int)(msg.U * screenWidth);
        var y = (int)(msg.V * screenHeight);

        SetCursorPos(x, y);

        if (msg.Button == 0)
        {
            if (msg.Down) mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
            if (msg.Up) mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
        }
        else if (msg.Button == 1)
        {
            if (msg.Down) mouse_event(MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, UIntPtr.Zero);
            if (msg.Up) mouse_event(MOUSEEVENTF_RIGHTUP, 0, 0, 0, UIntPtr.Zero);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PIPELINE: CAPTURE LOOP
    // ═══════════════════════════════════════════════════════════════════════════
    private static async Task CaptureLoopAsync(CancellationToken ct)
    {
        var frameIntervalMs = 1000.0 / TargetFps;
        var stopwatch = new Stopwatch();
        var screenBounds = Screen.PrimaryScreen?.Bounds ?? new Rectangle(0, 0, 1920, 1080);
        long frameNumber = 0;

        // Initialize capture
        if (UseHardwareCapture)
        {
            try
            {
                _dxgiCapture = new DxgiCapture();
                Console.WriteLine($"[Capture] DXGI initialized: {_dxgiCapture.Width}x{_dxgiCapture.Height}");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[Capture] DXGI failed, falling back to GDI+: {ex.Message}");
            }
        }

        // Allocate reusable buffer size tracker
        // FIX: Don't use a single array, alloc new one per frame to avoid race condition
        var bufferSize = (_dxgiCapture?.Width ?? screenBounds.Width) * 
                        (_dxgiCapture?.Height ?? screenBounds.Height) * 4;
        
        Console.WriteLine("[Capture] Loop started");
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(1000.0 / TargetFps));

        while (await timer.WaitForNextTickAsync(ct))
        {
            // stopwatch.Restart();


            if (Clients.Count > 0)
            {
                try
                {
                    // Get cursor position
                    GetCursorPos(out POINT cursor);
                    float cursorU = (float)cursor.X / screenBounds.Width;
                    float cursorV = (float)cursor.Y / screenBounds.Height;

                    byte[]? capturedData = null;
                    int width = 0, height = 0;

                    if (_dxgiCapture != null)
                    {
                        // DXGI Path
                        if (_dxgiCapture.TryAcquireFrame(10)) // 10ms timeout to wait for VBlank
                        {
                            // FIX: Allocate NEW buffer to prevent overwriting data still being encoded
                            // In a production app, use a BufferPool. For now, GC handles it fine.
                            var frameBuffer = new byte[bufferSize];
                            
                            _dxgiCapture.GetFrameDataInto(frameBuffer);
                            _dxgiCapture.ReleaseFrame();
                            capturedData = frameBuffer;
                            width = _dxgiCapture.Width;
                            height = _dxgiCapture.Height;
                            
                            _capturedCount++;
                            
                            // Cache valid frame for re-use
                            _lastFrameBuffer = frameBuffer;
                            _lastWidth = width;
                            _lastHeight = height;
                        }
                        else
                        {
                            // DXGI Timeout (No screen change)
                            
                            // FORCE CONSTANT STREAM: Re-send last frame
                            if (_lastFrameBuffer != null)
                            {
                                capturedData = _lastFrameBuffer;
                                width = _lastWidth;
                                height = _lastHeight;
                                // Don't increment captured count for duplicates? Or do? 
                                // Let's do it to show pipeline is alive.
                                _capturedCount++;
                            }
                            // UNLESS a client needs a keyframe (e.g. just connected) and we have no data
                            // In that case, force a GDI+ capture to unblock the stream
                            else if (Clients.Values.Any(c => c.NeedsKeyframe) || _capturedCount == 0)
                            {
                                // Console.WriteLine("[Capture] Force GDI+ fallback for static screen keyframe");
                                try
                                {
                                    (capturedData, width, height) = CaptureGdiPlus(screenBounds);
                                    _capturedCount++;
                                    
                                    // Cache GDI frame too
                                    _lastFrameBuffer = capturedData;
                                    _lastWidth = width;
                                    _lastHeight = height;
                                } 
                                catch (Exception ex)
                                {
                                    Console.WriteLine($"[Capture] Fallback failed: {ex.Message}");
                                }
                            }
                            else
                            {
                                capturedData = null;
                            }
                        }
                    }
                    else
                    {
                        // GDI+ Fallback (only if DXGI failed to initialize)
                        (capturedData, width, height) = CaptureGdiPlus(screenBounds);
                         _capturedCount++;
                    }

                    if (capturedData != null)
                    {
                        var frame = new CapturedFrame(capturedData, width, height, cursorU, cursorV, frameNumber++);
                        await _captureChannel!.Writer.WriteAsync(frame, ct);
                    }
                }
                catch (Exception ex)
                {
                    // Throttle error logs
                    if (frameNumber % 60 == 0) Console.WriteLine($"[Capture] Error: {ex.Message}");
                }
            }

            // PeriodicTimer handles the delay now
        }

        _dxgiCapture?.Dispose();
    }

    private static (byte[] data, int width, int height) CaptureGdiPlus(Rectangle bounds)
    {
        using var bmp = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
        using var gfx = Graphics.FromImage(bmp);
        gfx.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size);

        // Convert to byte array
        var data = bmp.LockBits(new Rectangle(0, 0, bounds.Width, bounds.Height),
            ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var bytes = new byte[data.Stride * data.Height];
            Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            return (bytes, bounds.Width, bounds.Height);
        }
        finally
        {
            bmp.UnlockBits(data);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PIPELINE: ENCODE LOOP
    // ═══════════════════════════════════════════════════════════════════════════
    private static async Task EncodeLoopAsync(CancellationToken ct)
    {
        var jpegEncoder = ImageCodecInfo.GetImageEncoders().FirstOrDefault(c => c.FormatID == ImageFormat.Jpeg.Guid);
        var encoderParams = new EncoderParameters(1) { Param = { [0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 85L) } };
        var stopwatch = new Stopwatch();

        Console.WriteLine("[Encode] Loop started");

        await foreach (var frame in _captureChannel!.Reader.ReadAllAsync(ct))
        {
            stopwatch.Restart();

            try
            {
                byte[]? encodedData = null;
                bool isKeyFrame = false;

                // Try H.264 encoding
                if (UseH264Encoding)
                {
                    if (_h264Encoder == null)
                    {
                        try
                        {
                            _h264Encoder = new H264Encoder(frame.Width, frame.Height, TargetFps, BitrateMbps);
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine($"[Encode] H.264 init failed: {ex.Message}");
                        }
                    }

                    if (_h264Encoder != null)
                    {
                        var forceKey = _requestKeyframe;
                        if (forceKey) { 
                             _requestKeyframe = false;
                             Console.WriteLine("[Encode] Encoding forced KEYFRAME");
                        }
                        
                        encodedData = _h264Encoder.EncodeFrame(frame.Data, forceKey);
                        isKeyFrame = _h264Encoder.IsKeyFrame;
                    }
                }

                // Fallback to JPEG
                if (encodedData == null)
                {
                    encodedData = EncodeJpeg(frame.Data, frame.Width, frame.Height, jpegEncoder, encoderParams);
                    isKeyFrame = true; // JPEG frames are always "keyframes"
                }

                if (encodedData != null)
                {
                    var encoded = new EncodedFrame(encodedData, frame.CursorU, frame.CursorV, isKeyFrame, frame.FrameNumber);
                    if (!_encodeChannel!.Writer.TryWrite(encoded))
                    {
                        // This shouldn't happen with capacity 120 unless network is REALLY dead, but good for debug
                        // Console.WriteLine("[Encode] Warning: Encode channel full, dropped oldest frame");
                        await _encodeChannel!.Writer.WriteAsync(encoded, ct);
                    }
                    
                    _encodedCount++;

                    _frameCount++;
                    if (_frameCount % 1200 == 1)
                    {
                        Console.WriteLine($"[Encode] Frame #{_frameCount}, size: {encodedData.Length} bytes, " +
                            $"key: {isKeyFrame}, time: {stopwatch.ElapsedMilliseconds}ms");
                        
                        // Force a keyframe every GOP interval if it wasn't one already
                        _requestKeyframe = true;
                    }
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[Encode] Error: {ex.Message}");
            }
        }

        _h264Encoder?.Dispose();
    }

    private static byte[]? EncodeJpeg(byte[] bgraData, int width, int height, ImageCodecInfo? codec, EncoderParameters? parameters)
    {
        using var bmp = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        var data = bmp.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        try
        {
            Marshal.Copy(bgraData, 0, data.Scan0, Math.Min(bgraData.Length, data.Stride * height));
        }
        finally
        {
            bmp.UnlockBits(data);
        }

        using var ms = new MemoryStream();
        if (codec != null && parameters != null)
            bmp.Save(ms, codec, parameters);
        else
            bmp.Save(ms, ImageFormat.Jpeg);

        return ms.ToArray();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PIPELINE: SEND LOOP
    // ═══════════════════════════════════════════════════════════════════════════
    private static async Task SendLoopAsync(CancellationToken ct)
    {
        Console.WriteLine("[Send] Loop started");

        await foreach (var frame in _encodeChannel!.Reader.ReadAllAsync(ct))
        {
            if (Clients.IsEmpty) continue;

            // Build frame packet: [FrameType:1][CursorU:4][CursorV:4][Data:N]
            // FrameType: 0=P-Frame, 1=I-Frame
            byte frameType = (byte)(frame.IsKeyFrame ? 1 : 0);
            
            var payload = new byte[9 + frame.Data.Length];
            payload[0] = frameType;
            BitConverter.GetBytes(frame.CursorU).CopyTo(payload, 1);
            BitConverter.GetBytes(frame.CursorV).CopyTo(payload, 5);
            frame.Data.CopyTo(payload, 9);

            // Send to all clients in parallel
            var sendTasks = new List<Task>();
            foreach (var (id, client) in Clients)
            {
                if (client.Socket.State != WebSocketState.Open) continue;

                // Skip P-frames for clients that need keyframes
                if (!frame.IsKeyFrame && client.NeedsKeyframe) continue;

                if (frame.IsKeyFrame)
                    client.NeedsKeyframe = false;

                sendTasks.Add(SendToClientAsync(client, payload, frame.FrameNumber));
            }
            
            if (sendTasks.Count > 0)
            {
                _sentCount++;
                await Task.WhenAll(sendTasks);
            }
        }
    }

    private static async Task SendToClientAsync(ClientState client, byte[] payload, long frameNumber)
    {
        try
        {
            // Use a cancellation token with a timeout to prevent hanging on a dead socket
            using var cts = new CancellationTokenSource(5000); // 5000ms timeout to allow large I-frames on slow networks
            await client.Socket.SendAsync(payload, WebSocketMessageType.Binary, true, cts.Token);
            client.LastFrameSent = frameNumber;
        }
        catch (Exception ex)
        {
            // Client will be removed when receive loop detects disconnect, or we can flag it here
            // For now, just logging on debug if needed, but keeping it silent to avoid spam
            // Console.WriteLine($"[Send] Error sending to client: {ex.Message}");
        }
    }

    private static async Task AudioLoopAsync(CancellationToken ct)
    {
        try
        {
            using var capture = new WasapiLoopbackCapture();
            var format = capture.WaveFormat;
            Console.WriteLine($"[Audio] Capturing from: {format.SampleRate}Hz {format.Channels}ch {format.BitsPerSample}bit ({capture.ShareMode})");
            
            if (format.SampleRate != 48000)
            {
                Console.WriteLine("[Audio] WARNING: Host sample rate is NOT 48kHz. This may cause 'cracks' or audio drift.");
                Console.WriteLine("[Audio] RECOMMENDATION: Set your Windows default playback device to 48000Hz (DVD Quality).");
            }
            
            var encoder = new ImaAdpcmEncoder();
            
            // Resampler for consistent 48kHz output
            var targetFormat = new WaveFormat(48000, 16, 2);
            var bufferedWaveProvider = new BufferedWaveProvider(capture.WaveFormat) { BufferDuration = TimeSpan.FromSeconds(1), DiscardOnBufferOverflow = true };
            using var resampler = new MediaFoundationResampler(bufferedWaveProvider, targetFormat);
            resampler.ResamplerQuality = 60; // High quality
            
            capture.DataAvailable += (s, e) =>
            {
                if (Clients.IsEmpty) return;

                // Push to buffer
                bufferedWaveProvider.AddSamples(e.Buffer, 0, e.BytesRecorded);

                // Use a reasonable buffer size for reading
                var outBuffer = new byte[8192]; 
                int bytesRead;
                
                while ((bytesRead = resampler.Read(outBuffer, 0, outBuffer.Length)) > 0)
                {
                    var pcm16 = new short[bytesRead / 2];
                    Buffer.BlockCopy(outBuffer, 0, pcm16, 0, bytesRead);

                    // Encode to stateless IMA ADPCM (4:1)
                    var adpcm = encoder.Encode(pcm16);

                    // Build Type 3 packet: [Type:1][Data:N]
                    var payload = new byte[1 + adpcm.Length];
                    payload[0] = 3;
                    adpcm.CopyTo(payload, 1);

                    // Pulse to channel for sending
                    _audioChannel!.Writer.TryWrite(payload);
                }
            };

            capture.StartRecording();
            
            while (!ct.IsCancellationRequested)
            {
                // Parallel Send Loop for Audio
                await foreach (var payload in _audioChannel!.Reader.ReadAllAsync(ct))
                {
                    if (Clients.IsEmpty) continue;

                    var sendTasks = new List<Task>();
                    foreach (var (id, client) in Clients)
                    {
                        if (client.Socket.State == WebSocketState.Open)
                        {
                            sendTasks.Add(SendToClientAsync(client, payload, -1)); // -1 means no video frame number
                        }
                    }

                    if (sendTasks.Count > 0)
                    {
                        _audioSentCount++;
                        await Task.WhenAll(sendTasks);
                    }
                }
            }

            capture.StopRecording();
        }
        catch (Exception ex)
        {
            Console.WriteLine("[Audio] FATAL ERROR: Audio capture could not start.");
            Console.WriteLine($"[Audio] Error Details: {ex.Message}");
            if (ex.Message.Contains("0x88890004")) // AUDCLNT_E_DEVICE_INVALIDATED
            {
                Console.WriteLine("[Audio] ADVICE: No active playback device found. Please plug in a speaker/headphone or enable a Virtual Audio Cable.");
            }
            else
            {
                Console.WriteLine("[Audio] ADVICE: Ensure a default playback device is active in Windows Sound Settings.");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IMA ADPCM ENCODER
    // ═══════════════════════════════════════════════════════════════════════════
    public class ImaAdpcmEncoder
    {
        private static readonly int[] IndexTable = {
            -1, -1, -1, -1, 2, 4, 6, 8,
            -1, -1, -1, -1, 2, 4, 6, 8
        };

        private static readonly int[] StepTable = {
            7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
            50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
            337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
            2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
            15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
        };

        private int _lastSampleL = 0;
        private int _lastIndexL = 0;
        private int _lastSampleR = 0;
        private int _lastIndexR = 0;

        public byte[] Encode(short[] pcm)
        {
            // Stateless Header (6 bytes): [SampleL:2][IndexL:1][SampleR:2][IndexR:1]
            // Followed by interleaved nibbles
            var output = new byte[6 + pcm.Length / 2];
            
            // Write Header
            BitConverter.GetBytes((short)_lastSampleL).CopyTo(output, 0);
            output[2] = (byte)_lastIndexL;
            BitConverter.GetBytes((short)_lastSampleR).CopyTo(output, 3);
            output[5] = (byte)_lastIndexR;

            for (int i = 0; i < pcm.Length; i += 2)
            {
                byte nibbleL = EncodeSample(pcm[i], ref _lastSampleL, ref _lastIndexL);
                byte nibbleR = EncodeSample(pcm[i + 1], ref _lastSampleR, ref _lastIndexR);
                output[6 + i / 2] = (byte)((nibbleL << 4) | (nibbleR & 0x0F));
            }
            return output;
        }

        private byte EncodeSample(int sample, ref int predictedSample, ref int index)
        {
            int diff = sample - predictedSample;
            int step = StepTable[index];
            int nibble = 0;

            if (diff < 0) { nibble = 8; diff = -diff; }
            if (diff >= step) { nibble |= 4; diff -= step; }
            step >>= 1;
            if (diff >= step) { nibble |= 2; diff -= step; }
            step >>= 1;
            if (diff >= step) { nibble |= 1; }

            // Decoder logic to sync predictor
            int diffq = StepTable[index] >> 3;
            if ((nibble & 4) != 0) diffq += StepTable[index];
            if ((nibble & 2) != 0) diffq += StepTable[index] >> 1;
            if ((nibble & 1) != 0) diffq += StepTable[index] >> 2;

            if ((nibble & 8) != 0) predictedSample -= diffq;
            else predictedSample += diffq;

            predictedSample = Math.Clamp(predictedSample, -32768, 32767);
            index = Math.Clamp(index + IndexTable[nibble], 0, 88);

            return (byte)nibble;
        }
    }
}
