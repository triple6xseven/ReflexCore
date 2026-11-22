using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;

namespace ReflexCore.Studio;

public sealed partial class StudioWindow
{
    void InitStudioButtons()
    {
        const string ns = "xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'";
        const string triggers = "<ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='face' Property='Opacity' Value='0.85'/></Trigger><Trigger Property='IsPressed' Value='True'><Setter TargetName='face' Property='Opacity' Value='0.65'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter TargetName='face' Property='Opacity' Value='0.4'/></Trigger></ControlTemplate.Triggers>";
        void Template(string key, string content) => Resources[key] = XamlReader.Parse("<ControlTemplate " + ns + " TargetType='Button'>" + content + triggers + "</ControlTemplate>");
        Template("ModernButtonTemplate", "<Border x:Name='face' CornerRadius='{DynamicResource ButtonCorner}' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}'><Grid><Border Background='White' Opacity='{DynamicResource ButtonGloss}' VerticalAlignment='Top' Height='10' IsHitTestVisible='False'/><ContentPresenter Margin='{TemplateBinding Padding}' HorizontalAlignment='Center' VerticalAlignment='Center'/></Grid></Border>");
        Template("AlienButtonTemplate", "<Grid x:Name='face' Background='Transparent'><Canvas IsHitTestVisible='False'><Path Width='{Binding ActualWidth,RelativeSource={RelativeSource TemplatedParent}}' Height='{Binding ActualHeight,RelativeSource={RelativeSource TemplatedParent}}' Data='M0,7 L7,0 100,0 100,23 93,30 0,30 Z' Stretch='Fill' Fill='{TemplateBinding Background}' Stroke='{DynamicResource PanelOutline}' StrokeThickness='1'/><Path Data='M0,7 L7,0 38,0' Stretch='Fill' Width='22' Height='7' HorizontalAlignment='Left' VerticalAlignment='Top' Stroke='{DynamicResource Accent}' StrokeThickness='1.5'/></Canvas><ContentPresenter Margin='{TemplateBinding Padding}' HorizontalAlignment='Center' VerticalAlignment='Center'/></Grid>");
        Template("FantasyButtonTemplate", "<Border x:Name='face' CornerRadius='3' Background='{TemplateBinding Background}' BorderBrush='{DynamicResource Accent}' BorderThickness='1'><Grid><Border Background='{DynamicResource ThemeTexture}' Opacity='0.16' IsHitTestVisible='False'/><Border Margin='3' BorderBrush='{DynamicResource PanelOutline}' BorderThickness='1' IsHitTestVisible='False'/><TextBlock Text='◆' FontSize='5' Margin='5,0' HorizontalAlignment='Left' VerticalAlignment='Center' Foreground='{DynamicResource Accent}'/><TextBlock Text='◆' FontSize='5' Margin='5,0' HorizontalAlignment='Right' VerticalAlignment='Center' Foreground='{DynamicResource Accent}'/><ContentPresenter Margin='{TemplateBinding Padding}' HorizontalAlignment='Center' VerticalAlignment='Center'/></Grid></Border>");
        Template("ZxcButtonTemplate", "<Border x:Name='face' CornerRadius='16,3,16,3' Background='{TemplateBinding Background}' BorderBrush='{DynamicResource Accent2}' BorderThickness='1' ClipToBounds='True'><Grid><Border Background='{DynamicResource ThemeTexture}' Opacity='.38' IsHitTestVisible='False'/><Border Height='9' VerticalAlignment='Top' Margin='5,2,5,0' Background='#45FFFFFF' CornerRadius='10,1,12,1' IsHitTestVisible='False'/><ContentPresenter Margin='{TemplateBinding Padding}' HorizontalAlignment='Center' VerticalAlignment='Center'/></Grid></Border>");
        const string overdriveShape = "M0,8 L8,0 H100 V22 L92,30 H0 Z";
        const string overdriveSize = "Width='{Binding ActualWidth,RelativeSource={RelativeSource TemplatedParent}}' Height='{Binding ActualHeight,RelativeSource={RelativeSource TemplatedParent}}'";
        Template("OverdriveButtonTemplate", "<Grid x:Name='face' Background='Transparent'><Canvas IsHitTestVisible='False'>" +
            $"<Path {overdriveSize} Data='{overdriveShape}' Stretch='Fill' Fill='{{TemplateBinding Background}}' Stroke='{{DynamicResource Accent}}' StrokeThickness='1'/>" +
            $"<Path {overdriveSize} Data='{overdriveShape}' Stretch='Fill' Fill='{{DynamicResource ThemeTexture}}' Opacity='.30'/></Canvas>" +
            "<Border Width='13' Height='2' Margin='0,3,7,0' HorizontalAlignment='Right' VerticalAlignment='Top' Background='{DynamicResource Accent2}' IsHitTestVisible='False'/><ContentPresenter Margin='{TemplateBinding Padding}' HorizontalAlignment='Center' VerticalAlignment='Center'/></Grid>");
        Resources["MaterialButtonTemplate"] = Resources["ModernButtonTemplate"];
        Resources[typeof(Button)] = XamlReader.Parse("<Style " + ns + " TargetType='Button'><Setter Property='Background' Value='{DynamicResource ButtonSurface}'/><Setter Property='Foreground' Value='{DynamicResource ButtonText}'/><Setter Property='BorderBrush' Value='{DynamicResource PanelOutline}'/><Setter Property='BorderThickness' Value='1'/><Setter Property='Padding' Value='13,8'/><Setter Property='Cursor' Value='Hand'/><Setter Property='Template' Value='{DynamicResource MaterialButtonTemplate}'/></Style>");
    }
}
