using System;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace ReflexCore.Vision
{
    // A reusable top-down DIB. GDI writes straight to the CPU detector's pixel memory.
    internal sealed class Surface : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct BitmapHeader
        {
            internal uint Size;
            internal int Width, Height;
            internal ushort Planes, BitCount;
            internal uint Compression, SizeImage;
            internal int XResolution, YResolution;
            internal uint ColorsUsed, ColorsImportant;
        }

        [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] private static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapHeader header, uint usage, out IntPtr pixels, IntPtr section, uint offset);
        [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr dc, IntPtr bitmap);
        [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr bitmap);
        [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] private static extern int SetStretchBltMode(IntPtr dc, int mode);
        [DllImport("gdi32.dll", SetLastError=true)] private static extern bool StretchBlt(IntPtr dest, int x, int y, int width, int height, IntPtr source, int sx, int sy, int sw, int sh, uint op);
        [DllImport("gdi32.dll", SetLastError=true)] private static extern bool BitBlt(IntPtr dest, int x, int y, int width, int height, IntPtr source, int sx, int sy, uint op);

        private const uint SourceCopy = 0x00CC0020;
        private IntPtr dc, bitmap, previous;
        internal readonly IntPtr Pixels;
        internal readonly int Width, Height;
        internal Bitmap Image { get; private set; }

        internal Surface(int width, int height)
        {
            Width = width; Height = height;
            var header = new BitmapHeader { Size = 40, Width = width, Height = -height, Planes = 1, BitCount = 32 };
            try
            {
                dc = CreateCompatibleDC(IntPtr.Zero);
                if (dc == IntPtr.Zero) throw new Win32Exception();
                bitmap = CreateDIBSection(dc, ref header, 0, out Pixels, IntPtr.Zero, 0);
                if (bitmap == IntPtr.Zero || Pixels == IntPtr.Zero) throw new Win32Exception();
                previous = SelectObject(dc, bitmap);
                if (previous == IntPtr.Zero || previous == new IntPtr(-1)) throw new Win32Exception();
                SetStretchBltMode(dc, 3);
                Image = new Bitmap(width, height, width * 4, PixelFormat.Format32bppRgb, Pixels);
            }
            catch { Dispose(); throw; }
        }

        internal bool Copy(IntPtr source, Rectangle bounds, bool scale)
        {
            return scale
                ? StretchBlt(dc, 0, 0, Width, Height, source, bounds.X, bounds.Y, bounds.Width, bounds.Height, SourceCopy)
                : BitBlt(dc, 0, 0, Width, Height, source, bounds.X, bounds.Y, SourceCopy);
        }

        internal unsafe void ScaleFrom(Surface source)
        {
            var input = (uint*)source.Pixels;
            var output = (uint*)Pixels;
            for (int y = 0; y < Height; y++)
            {
                var row = input + (y * source.Height / Height) * source.Width;
                for (int x = 0; x < Width; x++)
                    *output++ = row[x * source.Width / Width];
            }
        }

        internal unsafe bool IsBlack()
        {
            var pixels = (uint*)Pixels;
            for (int y = 8; y < Height; y += 16)
                for (int x = 8; x < Width; x += 16)
                    if ((pixels[y * Width + x] & 0x00f8f8f8) != 0) return false;
            return true;
        }

        public void Dispose()
        {
            if (Image != null) { Image.Dispose(); Image = null; }
            if (previous != IntPtr.Zero && previous != new IntPtr(-1)) SelectObject(dc, previous);
            if (bitmap != IntPtr.Zero) { DeleteObject(bitmap); bitmap = IntPtr.Zero; }
            if (dc != IntPtr.Zero) { DeleteDC(dc); dc = IntPtr.Zero; }
        }
    }

    internal sealed class GameCapture : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct ClientRect { internal int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        private struct Point { internal int X, Y; }
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr hwnd, out ClientRect rect);
        [DllImport("user32.dll")] private static extern bool ClientToScreen(IntPtr hwnd, ref Point pt);
        [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
        [DllImport("gdi32.dll")] private static extern bool GdiFlush();

        private readonly uint pid;
        private readonly IntPtr hwnd;
        private readonly int maxWidth;
        private readonly bool cpuScale;
        private readonly bool fixture;
        private Surface output, fullFrame;

        internal GameCapture(IntPtr window, uint process, int width, bool cpu, bool benchmarkFixture)
        {
            hwnd = window; pid = process; maxWidth = width; cpuScale = cpu; fixture = benchmarkFixture;
        }

        private bool ForegroundOwned()
        {
            uint owner;
            return (fixture || GetForegroundWindow() == hwnd) &&
                GetWindowThreadProcessId(hwnd, out owner) != 0 && owner == pid;
        }

        internal Rectangle Bounds()
        {
            ClientRect rect;
            var pt = new Point();
            if (!GetClientRect(hwnd, out rect) || !ClientToScreen(hwnd, ref pt)) return Rectangle.Empty;
            return new Rectangle(pt.X, pt.Y, rect.Right, rect.Bottom);
        }

        internal Surface Grab()
        {
            Rectangle bounds = Bounds();
            if (!ForegroundOwned() || bounds.Width < 160 || bounds.Height < 120 ||
                bounds.Width > 3840 || bounds.Height > 2160 ||
                !System.Windows.Forms.SystemInformation.VirtualScreen.Contains(bounds))
                return null;
            int width = Math.Min(bounds.Width, maxWidth);
            int height = Math.Max(72, bounds.Height * width / bounds.Width);
            if (height > 640) return null;
            Resize(ref output, width, height);
            if (cpuScale) Resize(ref fullFrame, bounds.Width, bounds.Height);
            var sourceWindow = fixture ? hwnd : IntPtr.Zero;
            var source = GetDC(sourceWindow);
            if (source == IntPtr.Zero) return null;
            bool captured;
            try
            {
                var sourceBounds = fixture ? new Rectangle(0, 0, bounds.Width, bounds.Height) : bounds;
                captured = (cpuScale ? fullFrame : output).Copy(source, sourceBounds, !cpuScale);
                GdiFlush();
            }
            finally { ReleaseDC(sourceWindow, source); }
            if (!captured || !ForegroundOwned() || Bounds() != bounds) return null;
            if (cpuScale) output.ScaleFrom(fullFrame);
            return output.IsBlack() ? null : output;
        }

        private static void Resize(ref Surface image, int width, int height)
        {
            if (image != null && image.Width == width && image.Height == height) return;
            var next = new Surface(width, height);
            if (image != null) image.Dispose();
            image = next;
        }

        public void Dispose()
        {
            if (output != null) output.Dispose();
            if (fullFrame != null) fullFrame.Dispose();
        }
    }
}
