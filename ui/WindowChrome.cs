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
        PopulateCaption(this,caption,"ReflexCore Studio");
        StateChanged+=(_,_)=>UpdateChromeInset();
        ApplyCaption(captionSwitch.On);
    }
    static void PopulateCaption(Window window,DockPanel bar,string windowTitle)
    {
        bar.SetResourceReference(Panel.BackgroundProperty,"Card");
        foreach(var item in new (string symbol,string name,Action click)[]{
            ("×","Close",window.Close),("□","Maximize or restore",()=>window.WindowState=window.WindowState==WindowState.Maximized?WindowState.Normal:WindowState.Maximized),
            ("−","Minimize",()=>window.WindowState=WindowState.Minimized)}){
            var button=Command(item.symbol,item.click);button.ToolTip=item.name;button.Width=42;button.Padding=new Thickness(0);
            System.Windows.Automation.AutomationProperties.SetName(button,item.name);WindowChrome.SetIsHitTestVisibleInChrome(button,true);
            DockPanel.SetDock(button,Dock.Right);bar.Children.Add(button);
        }
        var name=Label(windowTitle,13);name.Margin=new Thickness(12,0,0,0);bar.Children.Add(name);
    }

    static void SetThemedDialogContent(Window window,UIElement content)
    {
        var frame=new DockPanel();
        var bar=new DockPanel {Height=34};
        PopulateCaption(window,bar,window.Title);
        DockPanel.SetDock(bar,Dock.Top);
        frame.Children.Add(bar);
        frame.Children.Add(content);
        window.Content=frame;
        WindowChrome.SetWindowChrome(window,CreateCaptionChrome());
        window.StateChanged+=(_,_)=>frame.Margin=CaptionInset(window.WindowState==WindowState.Maximized);
    }

    static Thickness CaptionInset(bool maximized)
    {
        var border=SystemParameters.WindowResizeBorderThickness;
        return maximized ? new Thickness(border.Left+4,border.Top+4,border.Right+4,border.Bottom+4) : new Thickness(0);
    }

    static WindowChrome CreateCaptionChrome()=>new WindowChrome {CaptionHeight=34,
        ResizeBorderThickness=new Thickness(6),GlassFrameThickness=new Thickness(0),
        CornerRadius=new CornerRadius(0),UseAeroCaptionButtons=false};

    void UpdateChromeInset()
    {
        chromeRoot.Margin=CaptionInset(caption.Visibility==Visibility.Visible && WindowState==WindowState.Maximized);
    }
    void ApplyCaption(bool custom)
    {
        caption.Visibility=custom?Visibility.Visible:Visibility.Collapsed;
        WindowChrome.SetWindowChrome(this,custom?CreateCaptionChrome():null);
        UpdateChromeInset();
    }
}

