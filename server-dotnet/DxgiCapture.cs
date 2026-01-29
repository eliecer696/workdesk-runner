using System.Runtime.InteropServices;
using SharpDX;
using SharpDX.Direct3D;
using SharpDX.Direct3D11;
using SharpDX.DXGI;

namespace WorkdeskServer;

/// <summary>
/// High-performance screen capture using DXGI Desktop Duplication API.
/// Captures frames directly from GPU memory (~1-3ms vs 30ms with GDI+).
/// </summary>
public sealed class DxgiCapture : IDisposable
{
    private readonly SharpDX.Direct3D11.Device _device;
    private readonly OutputDuplication _duplication;
    private readonly Texture2D _stagingTexture;
    
    private readonly int _width;
    private readonly int _height;
    private bool _frameAcquired;
    private bool _disposed;

    public int Width => _width;
    public int Height => _height;

    public DxgiCapture(int adapterIndex = 0, int outputIndex = 0)
    {
        // Create D3D11 device
        _device = new SharpDX.Direct3D11.Device(DriverType.Hardware, DeviceCreationFlags.BgraSupport);

        // Get DXGI adapter and output
        using var dxgiDevice = _device.QueryInterface<SharpDX.DXGI.Device>();
        using var adapter = dxgiDevice.Adapter;
        using var output = adapter.GetOutput(outputIndex);
        using var output1 = output.QueryInterface<Output1>();

        // Get output description for dimensions
        var outputDesc = output.Description;
        _width = outputDesc.DesktopBounds.Right - outputDesc.DesktopBounds.Left;
        _height = outputDesc.DesktopBounds.Bottom - outputDesc.DesktopBounds.Top;

        // Create desktop duplication
        _duplication = output1.DuplicateOutput(_device);

        // Create staging texture for CPU readback
        var stagingDesc = new Texture2DDescription
        {
            Width = _width,
            Height = _height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Staging,
            BindFlags = BindFlags.None,
            CpuAccessFlags = CpuAccessFlags.Read,
            OptionFlags = ResourceOptionFlags.None
        };
        _stagingTexture = new Texture2D(_device, stagingDesc);

        Console.WriteLine($"[DxgiCapture] Initialized: {_width}x{_height}");
    }

    /// <summary>
    /// Attempts to acquire the next frame from the desktop.
    /// Returns true if a new frame is available.
    /// </summary>
    public bool TryAcquireFrame(int timeoutMs = 0)
    {
        if (_frameAcquired)
        {
            ReleaseFrame();
        }

        try
        {
            var result = _duplication.TryAcquireNextFrame(timeoutMs, out var frameInfo, out var resource);
            
            if (result.Failure)
            {
                resource?.Dispose();
                return false;
            }

            // Only process if there's actual content
            if (frameInfo.LastPresentTime == 0 && frameInfo.AccumulatedFrames == 0)
            {
                resource?.Dispose();
                _duplication.ReleaseFrame();
                return false;
            }

            // Copy to staging texture
            using var texture = resource.QueryInterface<Texture2D>();
            _device.ImmediateContext.CopyResource(texture, _stagingTexture);
            resource.Dispose();

            _frameAcquired = true;
            return true;
        }
        catch (SharpDXException)
        {
            return false;
        }
    }

    /// <summary>
    /// Gets the captured frame data as a byte array (BGRA format).
    /// </summary>
    public byte[] GetFrameData()
    {
        if (!_frameAcquired)
        {
            throw new InvalidOperationException("No frame acquired. Call TryAcquireFrame first.");
        }

        var dataBox = _device.ImmediateContext.MapSubresource(_stagingTexture, 0, MapMode.Read, SharpDX.Direct3D11.MapFlags.None);
        try
        {
            var data = new byte[_width * _height * 4];
            var rowPitch = dataBox.RowPitch;
            
            // Copy row by row to handle pitch differences
            for (int y = 0; y < _height; y++)
            {
                Marshal.Copy(dataBox.DataPointer + y * rowPitch, data, y * _width * 4, _width * 4);
            }
            
            return data;
        }
        finally
        {
            _device.ImmediateContext.UnmapSubresource(_stagingTexture, 0);
        }
    }

    /// <summary>
    /// Gets the captured frame directly into an existing buffer (BGRA format).
    /// More efficient than GetFrameData() as it avoids allocation.
    /// </summary>
    public void GetFrameDataInto(byte[] buffer)
    {
        if (!_frameAcquired)
        {
            throw new InvalidOperationException("No frame acquired. Call TryAcquireFrame first.");
        }

        if (buffer.Length < _width * _height * 4)
        {
            throw new ArgumentException($"Buffer too small. Need {_width * _height * 4} bytes.");
        }

        var dataBox = _device.ImmediateContext.MapSubresource(_stagingTexture, 0, MapMode.Read, SharpDX.Direct3D11.MapFlags.None);
        try
        {
            var rowPitch = dataBox.RowPitch;
            for (int y = 0; y < _height; y++)
            {
                Marshal.Copy(dataBox.DataPointer + y * rowPitch, buffer, y * _width * 4, _width * 4);
            }
        }
        finally
        {
            _device.ImmediateContext.UnmapSubresource(_stagingTexture, 0);
        }
    }

    /// <summary>
    /// Releases the currently acquired frame.
    /// </summary>
    public void ReleaseFrame()
    {
        if (_frameAcquired)
        {
            try
            {
                _duplication.ReleaseFrame();
            }
            catch { }
            _frameAcquired = false;
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        ReleaseFrame();
        _stagingTexture?.Dispose();
        _duplication?.Dispose();
        _device?.Dispose();
    }
}
