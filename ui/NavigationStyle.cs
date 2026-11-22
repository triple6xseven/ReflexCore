using System.Windows.Controls;
using System.Windows.Markup;
namespace ReflexCore.Studio;
public sealed partial class StudioWindow {
    private ControlTemplate NavigationTemplate() {
        const string ns = "xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'";
        var navTemplate = (ControlTemplate)XamlReader.Parse("<ControlTemplate " + ns + " TargetType='Button'><Border x:Name='face' CornerRadius='7' Background='{TemplateBinding Background}' Padding='{TemplateBinding Padding}'><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='face' Property='BorderBrush' Value='{DynamicResource PanelOutline}'/><Setter TargetName='face' Property='BorderThickness' Value='1'/></Trigger></ControlTemplate.Triggers></ControlTemplate>");
        return navTemplate;
    }
}
