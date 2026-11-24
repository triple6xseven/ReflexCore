using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shell;

namespace ReflexCore.Studio;

public sealed partial class StudioWindow
{
    readonly DockPanel chromeRoot=new();
    readonly DockPanel caption=new(){Height=34};
    void InitCaption()
    {
        Content=chromeRoot;DockPanel.SetDock(caption,Dock.Top);chromeRoot.Children.Add(caption);chromeRoot.Children.Add(background);
        caption.SetResourceReference(Panel.BackgroundProperty,"Card");
        foreach(var item in new (string symbol,string name,Action click)[]{
            ("×","Close",Close),("□","Maximize or restore",()=>WindowState=WindowState==WindowState.Maximized?WindowState.Normal:WindowState.Maximized),
            ("−","Minimize",()=>WindowState=WindowState.Minimized)}){
            var button=Command(item.symbol,item.click);button.ToolTip=item.name;button.Width=42;button.Padding=new Thickness(0);
            System.Windows.Automation.AutomationProperties.SetName(button,item.name);WindowChrome.SetIsHitTestVisibleInChrome(button,true);
            DockPanel.SetDock(button,Dock.Right);caption.Children.Add(button);
        }
        var name=Label("ReflexCore Studio",13);name.Margin=new Thickness(12,0,0,0);caption.Children.Add(name);
        StateChanged+=(_,_)=>UpdateChromeInset();
        ApplyCaption(captionSwitch.On);
    }
    void UpdateChromeInset()
    {
        var border=SystemParameters.WindowResizeBorderThickness;
        chromeRoot.Margin=caption.Visibility==Visibility.Visible && WindowState==WindowState.Maximized
            ? new Thickness(border.Left+4,border.Top+4,border.Right+4,border.Bottom+4)
            : new Thickness(0);
    }
    void ApplyCaption(bool custom)
    {
        caption.Visibility=custom?Visibility.Visible:Visibility.Collapsed;
        WindowChrome.SetWindowChrome(this,custom?new WindowChrome{CaptionHeight=34,ResizeBorderThickness=new Thickness(6),
            GlassFrameThickness=new Thickness(0),CornerRadius=new CornerRadius(0),UseAeroCaptionButtons=false}:null);
        UpdateChromeInset();
    }
}

