using System;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace ReflexCore.Studio;

public sealed partial class StudioWindow
{
    ControlTemplate themeTileTemplate;
    Button ThemeTile(Theme theme, bool artwork)
    {
        var content = new StackPanel();
        content.Children.Add(artwork && theme.Artwork is string art
            ? new Border { Background = Artwork(art, 160), Height = 30 }
            : new ThemeSample { Theme = theme, Height = artwork ? 30 : 24 });
        var name = new TextBlock { Text = theme.Name, FontSize = 11.5, Margin = new Thickness(8, 5, 5, 6), Foreground = new SolidColorBrush(Col(theme.Text)), TextTrimming = TextTrimming.CharacterEllipsis };
        content.Children.Add(name);
        themeTileTemplate ??= (ControlTemplate)System.Windows.Markup.XamlReader.Parse("<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='Button'><Border x:Name='face' CornerRadius='8' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' ClipToBounds='True'><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='face' Property='Opacity' Value='0.85'/></Trigger></ControlTemplate.Triggers></ControlTemplate>");
        var tile = new Button { Content = content, Tag = theme.Name, Width = 126, Padding = new Thickness(0), Margin = new Thickness(0, 0, 8, 8),
            Background = new SolidColorBrush(Col(theme.Card)), BorderThickness = new Thickness(2), ToolTip = theme.Name, Cursor = System.Windows.Input.Cursors.Hand, Template = themeTileTemplate };
        System.Windows.Automation.AutomationProperties.SetName(tile, theme.Name);
        return tile;
    }
}

class ThemeSample : FrameworkElement
{
    public Theme Theme;
    protected override void OnRender(DrawingContext dc)
    {
        var t = Theme; if (t == null || ActualWidth < 1 || ActualHeight < 1) return;
        Brush B(string h) { var b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(h)); b.Freeze(); return b; }
        double w = ActualWidth, h = ActualHeight; dc.PushClip(new RectangleGeometry(new Rect(0, 0, w, h), 5, 5));
        dc.DrawRectangle(new LinearGradientBrush(((SolidColorBrush)B(t.Bg)).Color, ((SolidColorBrush)B(t.Track)).Color, 35), null, new Rect(0, 0, w, h));
        if (t.Name == "Prism Glass") { dc.DrawEllipse(B("#EEC5DD"), null, new Point(w * .2, h * .1), w * .45, h * .7); dc.DrawEllipse(B("#CCDDF2"), null, new Point(w * .8, h * .9), w * .5, h * .9); }
        dc.DrawRoundedRectangle(B(t.Card), null, new Rect(w * .08, h * .15, w * .84, h * .72), 5, 5);
        for(int row=0;row<4;row++) dc.DrawRoundedRectangle(B(row==0?t.Accent:t.Track),null,new Rect(w*.12,h*(.25+row*.12),w*.16,h*.065),2,2);
        var text = new FormattedText("Reflex", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI Semibold"), Bounds.Clamp(h * .12, 8, 18), B(t.Accent), VisualTreeHelper.GetDpi(this).PixelsPerDip); dc.DrawText(text, new Point(w * .34, h * .22));
        dc.DrawRoundedRectangle(B(t.Accent), null, new Rect(w * .69, h * .25, w * .16, h * .1), t.ControlKind is 1 or 3 ? 1 : 4, 4);
        for (int i = 0; i < 3; i++) { dc.DrawRoundedRectangle(B(t.Track), null, new Rect(w * .34, h * (.45 + i * .1), w * .3, h * .04), 1, 1); dc.DrawRoundedRectangle(B(i == 0 ? t.Accent : t.Track), null, new Rect(w * .72, h * (.43 + i * .1), w * .12, h * .065), t.ControlKind == 3 ? 0 : 3, 3); }
        dc.Pop();
    }
}
