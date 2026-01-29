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

namespace WorkdeskServer;

internal static class Program
{
    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION - Optimized for Virtual Desktop-like performance
    // ═══════════════════════════════════════════════════════════════════════════
    private const int Port = 9000;
    private const int TargetFps = 72;           // Match Quest 3 refresh rate
    private const int BitrateMbps = 50;         // H.264 bitrate (adjustable 20-150)
    private const int MaxClients = 4;
    private const bool UseHardwareCapture = true;   // DXGI vs GDI+
    private const bool UseH264Encoding = true;      // H.264 vs JPEG fallback

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════
    private static readonly ConcurrentDictionary<Guid, ClientState> Clients = new();
    private static Channel<CapturedFrame>? _captureChannel;
    private static Channel<EncodedFrame>? _encodeChannel;
    private static DxgiCapture? _dxgiCapture;
    private static H264Encoder? _h264Encoder;
    private static bool _requestKeyframe = false;
    private static int _frameCount = 0;

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
        _captureChannel = Channel.CreateBounded<CapturedFrame>(new BoundedChannelOptions(3)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = true
        });

        _encodeChannel = Channel.CreateBounded<EncodedFrame>(new BoundedChannelOptions(3)
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
        Console.WriteLine("[Server] Listening on ports 80, 9000");

        await app.RunAsync();
        
        cts.Cancel();
        await Task.WhenAll(captureTask, encodeTask, sendTask);
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

        // Allocate reusable buffer
        var bufferSize = (_dxgiCapture?.Width ?? screenBounds.Width) * 
                        (_dxgiCapture?.Height ?? screenBounds.Height) * 4;
        var frameBuffer = new byte[bufferSize];

        Console.WriteLine("[Capture] Loop started");

        while (!ct.IsCancellationRequested)
        {
            stopwatch.Restart();

            if (Clients.Count > 0)
            {
                try
                {
                    // Get cursor position
                    GetCursorPos(out POINT cursor);
                    float cursorU = (float)cursor.X / screenBounds.Width;
                    float cursorV = (float)cursor.Y / screenBounds.Height;

                    byte[]? capturedData = null;
                    int width, height;

                    // Capture frame
                    if (_dxgiCapture != null && _dxgiCapture.TryAcquireFrame(1))
                    {
                        _dxgiCapture.GetFrameDataInto(frameBuffer);
                        _dxgiCapture.ReleaseFrame();
                        capturedData = frameBuffer;
                        width = _dxgiCapture.Width;
                        height = _dxgiCapture.Height;
                    }
                    else
                    {
                        // Fallback to GDI+
                        (capturedData, width, height) = CaptureGdiPlus(screenBounds);
                    }

                    if (capturedData != null)
                    {
                        var frame = new CapturedFrame(capturedData, width, height, cursorU, cursorV, frameNumber++);
                        await _captureChannel!.Writer.WriteAsync(frame, ct);
                    }
                }
                catch (Exception ex)
                {
                    if (frameNumber < 5) Console.WriteLine($"[Capture] Error: {ex.Message}");
                }
            }

            var elapsed = stopwatch.Elapsed.TotalMilliseconds;
            var delay = Math.Max(1, frameIntervalMs - elapsed);
            await Task.Delay((int)delay, ct);
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
                        _requestKeyframe = false;
                        
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
                    await _encodeChannel!.Writer.WriteAsync(encoded, ct);

                    _frameCount++;
                    if (_frameCount % 300 == 1)
                    {
                        Console.WriteLine($"[Encode] Frame #{_frameCount}, size: {encodedData.Length} bytes, " +
                            $"key: {isKeyFrame}, time: {stopwatch.ElapsedMilliseconds}ms");
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
            var payload = new byte[9 + frame.Data.Length];
            payload[0] = (byte)(frame.IsKeyFrame ? 1 : 0);
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
                await Task.WhenAll(sendTasks);
            }
        }
    }

    private static async Task SendToClientAsync(ClientState client, byte[] payload, long frameNumber)
    {
        try
        {
            await client.Socket.SendAsync(payload, WebSocketMessageType.Binary, true, CancellationToken.None);
            client.LastFrameSent = frameNumber;
        }
        catch
        {
            // Client will be removed when receive loop detects disconnect
        }
    }
}
