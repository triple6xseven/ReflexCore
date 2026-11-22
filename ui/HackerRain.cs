using System;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace ReflexCore.Studio;

sealed class HackerRain : Grid
{
    const int TileWidth = 420, TileHeight = 360;
    readonly TranslateTransform motion = new();
    readonly Rectangle sheet;

    public HackerRain()
    {
        IsHitTestVisible = false;
        ClipToBounds = true;
        Visibility = Visibility.Collapsed;
        sheet = new Rectangle { Margin = new Thickness(0, -TileHeight, 0, 0), RenderTransform = motion };
        Children.Add(sheet);
    }

    internal void SetRunning(bool running)
    {
        if (running == (Visibility == Visibility.Visible)) return;
        if (running)
        {
            sheet.Fill ??= CreateTile();
            Visibility = Visibility.Visible;
            motion.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, TileHeight, TimeSpan.FromSeconds(10))
                { RepeatBehavior = RepeatBehavior.Forever });
        }
        else
        {
            Visibility = Visibility.Collapsed;
            motion.BeginAnimation(TranslateTransform.YProperty, null);
        }
    }

    static ImageBrush CreateTile()
    {
        const string alphabet = "01アイウエオ";
        var random = new Random(7043);
        var font = new Typeface("Cascadia Mono, Segoe UI");
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            for (int column = 0; column < 13; column++)
            {
                int start = random.Next(TileHeight / 15) * 15;
                int length = random.Next(4, 10);
                for (int row = 0; row < length; row++)
                {
                    var color = Color.FromArgb((byte)(25 + 12 * row), 67, 244, 144);
                    var text = new FormattedText(alphabet[random.Next(alphabet.Length)].ToString(), CultureInfo.InvariantCulture,
                        FlowDirection.LeftToRight, font, 12, new SolidColorBrush(color), 1);
                    dc.DrawText(text, new Point(10 + column * 32, (start + row * 15) % TileHeight));
                }
            }
        }
        var bitmap = new RenderTargetBitmap(TileWidth, TileHeight, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        bitmap.Freeze();
        var brush = new ImageBrush(bitmap) { TileMode = TileMode.Tile, ViewportUnits = BrushMappingMode.Absolute,
            Viewport = new Rect(0, 0, TileWidth, TileHeight), Stretch = Stretch.Fill };
        brush.Freeze();
        return brush;
    }
}
