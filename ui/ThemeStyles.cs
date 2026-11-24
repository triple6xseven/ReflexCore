using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;

namespace ReflexCore.Studio;

public sealed partial class StudioWindow
{
    void InitSurfaceStyles()
    {
        const string ns = "xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'";
        void Style(Type type, string body) => Resources[type] = XamlReader.Parse("<Style " + ns + " TargetType='{x:Type " + type.Name + "}'>" + body + "</Style>");
        string palette = "<Setter Property='Foreground' Value='{DynamicResource Text}'/><Setter Property='Background' Value='{DynamicResource Card}'/><Setter Property='BorderBrush' Value='{DynamicResource Track}'/>";
        Style(typeof(Slider), """
            <Setter Property='Height' Value='24'/>
            <Setter Property='Template'><Setter.Value>
              <ControlTemplate TargetType='Slider'>
                <Grid Background='Transparent'>
                  <Border Height='4' VerticalAlignment='Center' CornerRadius='2' Background='{DynamicResource Track}'/>
                  <Track x:Name='PART_Track' Minimum='{TemplateBinding Minimum}' Maximum='{TemplateBinding Maximum}' Value='{Binding Value, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}'>
                    <Track.DecreaseRepeatButton>
                      <RepeatButton Command='Slider.DecreaseLarge' Focusable='False'>
                        <RepeatButton.Template><ControlTemplate TargetType='RepeatButton'>
                          <Grid Background='Transparent'><Border Height='4' VerticalAlignment='Center' CornerRadius='2' Background='{DynamicResource Accent}'/></Grid>
                        </ControlTemplate></RepeatButton.Template>
                      </RepeatButton>
                    </Track.DecreaseRepeatButton>
                    <Track.IncreaseRepeatButton>
                      <RepeatButton Command='Slider.IncreaseLarge' Focusable='False'>
                        <RepeatButton.Template><ControlTemplate TargetType='RepeatButton'><Border Background='Transparent'/></ControlTemplate></RepeatButton.Template>
                      </RepeatButton>
                    </Track.IncreaseRepeatButton>
                    <Track.Thumb>
                      <Thumb Width='16' Height='18'>
                        <Thumb.Template><ControlTemplate TargetType='Thumb'>
                          <Border Background='{DynamicResource Accent}' BorderBrush='{DynamicResource PanelOutline}' BorderThickness='1' CornerRadius='4'/>
                        </ControlTemplate></Thumb.Template>
                      </Thumb>
                    </Track.Thumb>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value></Setter>
            """);
        Resources["ScrollPageButton"]=XamlReader.Parse("<ControlTemplate "+ns+
            " TargetType='RepeatButton'><Border Background='Transparent'/></ControlTemplate>");
        Style(typeof(System.Windows.Controls.Primitives.ToggleButton),palette + """
            <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ToggleButton'>
              <Border x:Name='surface' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}'
                      BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='{DynamicResource ButtonCorner}'
                      Padding='{TemplateBinding Padding}'>
                <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property='IsChecked' Value='True'><Setter TargetName='surface' Property='BorderBrush' Value='{DynamicResource Accent}'/></Trigger>
                <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='surface' Property='Background' Value='{DynamicResource SurfaceInset}'/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate></Setter.Value></Setter>
            """);
        Style(typeof(System.Windows.Controls.Primitives.ScrollBar), """
            <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ScrollBar'>
              <Grid Background='{DynamicResource Card}'>
                <Track x:Name='PART_Track' Orientation='{TemplateBinding Orientation}'
                       IsDirectionReversed='True'>
                  <Track.DecreaseRepeatButton><RepeatButton x:Name='pageBack' Focusable='False' Command='ScrollBar.PageUpCommand'
                      Template='{DynamicResource ScrollPageButton}'/></Track.DecreaseRepeatButton>
                  <Track.IncreaseRepeatButton><RepeatButton x:Name='pageForward' Focusable='False' Command='ScrollBar.PageDownCommand'
                      Template='{DynamicResource ScrollPageButton}'/></Track.IncreaseRepeatButton>
                  <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType='Thumb'>
                    <Border Background='{DynamicResource Track}' BorderBrush='{DynamicResource Sub}'
                            BorderThickness='1' CornerRadius='4' Margin='2'/>
                  </ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
                </Track>
              </Grid>
              <ControlTemplate.Triggers>
                <Trigger Property='Orientation' Value='Horizontal'>
                  <Setter TargetName='PART_Track' Property='IsDirectionReversed' Value='False'/>
                  <Setter TargetName='pageBack' Property='Command' Value='ScrollBar.PageLeftCommand'/>
                  <Setter TargetName='pageForward' Property='Command' Value='ScrollBar.PageRightCommand'/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate></Setter.Value></Setter>
            """);
        Style(typeof(ListBox), palette + "<Setter Property='BorderThickness' Value='1'/><Setter Property='Padding' Value='4'/><Setter Property='ScrollViewer.HorizontalScrollBarVisibility' Value='Disabled'/><Setter Property='ScrollViewer.CanContentScroll' Value='True'/>");
        Style(typeof(ListBoxItem), "<Setter Property='Foreground' Value='{DynamicResource Text}'/><Setter Property='Padding' Value='9,8'/><Setter Property='HorizontalContentAlignment' Value='Stretch'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ListBoxItem'><Border x:Name='row' Background='Transparent' BorderBrush='Transparent' BorderThickness='1' CornerRadius='5' Padding='{TemplateBinding Padding}'><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='row' Property='Background' Value='{DynamicResource Track}'/></Trigger><Trigger Property='IsSelected' Value='True'><Setter TargetName='row' Property='Background' Value='{DynamicResource Track}'/><Setter TargetName='row' Property='BorderBrush' Value='{DynamicResource Accent}'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>");
        Style(typeof(ComboBoxItem), """
            <Setter Property='Foreground' Value='{DynamicResource Text}'/>
            <Setter Property='Padding' Value='10,7'/>
            <Setter Property='HorizontalContentAlignment' Value='Stretch'/>
            <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ComboBoxItem'>
              <Border x:Name='item' Margin='0,1' BorderThickness='1' CornerRadius='{DynamicResource SurfaceCorner}'
                      BorderBrush='{DynamicResource SurfaceInset}' Background='{DynamicResource SurfaceFill}' Padding='{TemplateBinding Padding}'>
                <ContentPresenter/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property='IsSelected' Value='True'>
                  <Setter TargetName='item' Property='BorderBrush' Value='{DynamicResource SurfaceOutline}'/>
                </Trigger>
                <Trigger Property='IsHighlighted' Value='True'>
                  <Setter TargetName='item' Property='Background' Value='{DynamicResource Track}'/>
                  <Setter TargetName='item' Property='BorderBrush' Value='{DynamicResource Accent}'/>
                </Trigger>
                <Trigger Property='IsEnabled' Value='False'><Setter TargetName='item' Property='Opacity' Value='.45'/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate></Setter.Value></Setter>
            """);
        Style(typeof(ComboBox), palette + """
            <Setter Property='MinHeight' Value='32'/>
            <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ComboBox'>
              <Grid>
                <Border x:Name='edge' Background='{DynamicResource SurfaceFill}' BorderBrush='{DynamicResource SurfaceOutline}'
                        BorderThickness='1' CornerRadius='{DynamicResource SurfaceCorner}'/>
                <Border Margin='3' BorderBrush='{DynamicResource SurfaceInset}' BorderThickness='1'
                        CornerRadius='{DynamicResource SurfaceCorner}' IsHitTestVisible='False'/>
                <ToggleButton Focusable='False' IsChecked='{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}'>
                  <ToggleButton.Template><ControlTemplate TargetType='ToggleButton'><Border Background='Transparent'/></ControlTemplate></ToggleButton.Template>
                </ToggleButton>
                <ContentPresenter Margin='10,6,30,6' VerticalAlignment='Center' IsHitTestVisible='False'
                                  Content='{TemplateBinding SelectionBoxItem}' ContentTemplate='{TemplateBinding SelectionBoxItemTemplate}'/>
                <TextBlock Text='⌄' Margin='0,0,10,0' HorizontalAlignment='Right' VerticalAlignment='Center'
                           Foreground='{DynamicResource Text}' IsHitTestVisible='False'/>
                <Popup x:Name='PART_Popup' Placement='Bottom' IsOpen='{TemplateBinding IsDropDownOpen}' AllowsTransparency='True' Focusable='False'>
                  <Border MinWidth='{Binding ActualWidth,RelativeSource={RelativeSource TemplatedParent}}' Background='{DynamicResource PopupSurface}'
                          BorderBrush='{DynamicResource SurfaceOutline}' BorderThickness='1' Padding='5' CornerRadius='{DynamicResource SurfaceCorner}'>
                    <ScrollViewer MaxHeight='300' CanContentScroll='True'><ItemsPresenter/></ScrollViewer>
                  </Border>
                </Popup>
              </Grid>
              <ControlTemplate.Triggers>
                <Trigger Property='IsKeyboardFocusWithin' Value='True'>
                  <Setter TargetName='edge' Property='BorderBrush' Value='{DynamicResource Accent}'/>
                  <Setter TargetName='edge' Property='BorderThickness' Value='2'/>
                </Trigger>
                <Trigger Property='IsEnabled' Value='False'><Setter TargetName='edge' Property='Opacity' Value='.45'/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate></Setter.Value></Setter>
            """);
        Style(typeof(Expander), "<Setter Property='Foreground' Value='{DynamicResource Text}'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Expander'><StackPanel><ToggleButton x:Name='toggle' IsChecked='{Binding IsExpanded,RelativeSource={RelativeSource TemplatedParent},Mode=TwoWay}' Foreground='{DynamicResource Text}' HorizontalContentAlignment='Left'><ToggleButton.Template><ControlTemplate TargetType='ToggleButton'><Border Background='{DynamicResource Track}' Padding='9,8' CornerRadius='5'><DockPanel><TextBlock x:Name='arrow' Text='›' Margin='0,0,8,0'/><ContentPresenter/></DockPanel></Border><ControlTemplate.Triggers><Trigger Property='IsChecked' Value='True'><Setter TargetName='arrow' Property='Text' Value='⌄'/></Trigger></ControlTemplate.Triggers></ControlTemplate></ToggleButton.Template><ContentPresenter Content='{TemplateBinding Header}'/></ToggleButton><ContentPresenter x:Name='body' Visibility='Collapsed' Margin='2,8,2,8'/></StackPanel><ControlTemplate.Triggers><Trigger Property='IsExpanded' Value='True'><Setter TargetName='body' Property='Visibility' Value='Visible'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>");
        Resources["TransparentBrush"] = Brushes.Transparent;
        Resources["XPCheck"] = new SolidColorBrush(Color.FromRgb(30, 122, 40));
        Resources["FrameThickness"] = new Thickness(1);
    }
}
