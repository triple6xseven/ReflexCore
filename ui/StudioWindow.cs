using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Forms.Integration;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace ReflexCore.Studio;

public sealed partial class StudioWindow : Window
{
    readonly Forms.TabControl pages;
    readonly Action stop;
    readonly Action<string> save;
    readonly Func<string> readStage;
    readonly ColumnDefinition railWidth = new();
    readonly StackPanel rail = new(), nav = new();
    readonly Grid layout = new(), body = new();
    readonly TextBlock title = new(), brand = new(), stage = new();
    readonly Border sidebar = new(), pageHead = new();
    readonly WindowsFormsHost native = new();
    readonly ScrollViewer appearance = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    readonly Grid background = new();
    readonly Border wallpaper = new() { IsHitTestVisible = false };
    readonly HackerRain rain = new();
    readonly Dictionary<string,ImageBrush> artwork = new();
    readonly List<Button> navButtons = new();
    readonly List<TextBlock> navLabels = new();
    readonly List<int> history = new();
    readonly DispatcherTimer pulse = new() { Interval = TimeSpan.FromSeconds(1) };
    readonly string[] names = { "Agent", "Models", "Diagnostics", "Shared Control", "Citadel Lab", "OpenAI API", "Appearance", "Companion & Widgets" };
    readonly string[] glyphs = { "\uE80F", "\uE950", "\uE9D9", "\uE7FC", "\uE7FC", "\uE774", "\uE790", "\uE790" };
    readonly string projectRoot;
    Theme current;
    int active = -1, historyIndex = -1;
    bool smooth = true, animate, showWallpaper = true;
    double tint = 88;
    string typeface;
    readonly WrapPanel gallery = new();
    readonly ComboBox category = new();
    readonly Sw motionSwitch = new(false);
    readonly Sw captionSwitch = new(false);
    readonly Sw wallpaperSwitch = new(true);

    public StudioWindow(Forms.TabControl pages, string initialTheme, Action<string> save, Action stop, Func<string> readStage)
        : this(pages, initialTheme, save, stop, readStage, null) { }

    public StudioWindow(Forms.TabControl pages, string initialTheme, Action<string> save, Action stop, Func<string> readStage, string projectRoot)
    {
        this.pages=pages; this.save=save; this.stop=stop; this.readStage=readStage; this.projectRoot=projectRoot;
        Title="ReflexCore Studio";
        var iconPath = System.IO.Path.Combine(projectRoot ?? "", "assets", "reflexcore.ico");
        if (System.IO.File.Exists(iconPath))
            Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri(System.IO.Path.GetFullPath(iconPath)));
        Width=1180; Height=790; MinWidth=820; MinHeight=590;
        WindowStartupLocation=WindowStartupLocation.CenterScreen;
        current=Theme.All.FirstOrDefault(t=>t.Name==initialTheme) ?? Theme.All[0];
        var appearanceSettings = WidgetSettings.Read(Path.Combine(WidgetSettings.Folder, "studio-appearance.json"));
        animate = Fx.Fun = WidgetSettings.Bool(appearanceSettings, "theme_animations");
        motionSwitch.Put(animate);
        captionSwitch.Put(WidgetSettings.Bool(appearanceSettings, "themed_title_bar"));
        InitStudioButtons(); InitSurfaceStyles();
        BuildShell(); ApplyTheme(current,false);
        native.Child=pages;
        var hostedWheel=new HostedWheel(pages,()=>smooth);
        SelectPage(Math.Max(0,pages.SelectedIndex));
        pulse.Tick+=(_,_)=>{stage.Text=readStage();if(active==7)RefreshWidgetStatus();};
        SourceInitialized+=(_,_)=>StudioTaskbar.Register(new System.Windows.Interop.WindowInteropHelper(this).Handle,projectRoot);
        ContentRendered+=(_,_)=>{ stage.Text=readStage(); if(WindowState!=WindowState.Minimized)pulse.Start(); };
        StateChanged+=(_,_)=>{ pulse.IsEnabled=WindowState!=WindowState.Minimized; RefreshBackground(); };
        SizeChanged+=(_,_)=>SizeRail();
        MouseDown+=(_,e)=>{
            if(e.ChangedButton==MouseButton.XButton1 || e.ChangedButton==MouseButton.XButton2){
                VisitHistory(e.ChangedButton==MouseButton.XButton1?-1:1);e.Handled=true;
            }
        };
        Closing+=(_,e)=>{if(changedWidgetKeys.Count>0 && !ApplyWidgetChanges())e.Cancel=true;};
        Closed+=(_,_)=>{hostedWheel.Dispose();widgetSave.Stop();pulse.Stop();rain.SetRunning(false);native.Child=null;native.Dispose();};
    }
    static Color Col(string hex)=>(Color)ColorConverter.ConvertFromString(hex);
    static SolidColorBrush Brush(string hex) { var b=new SolidColorBrush(Col(hex));b.Freeze();return b; }
    ImageBrush Artwork(string name,int width)
    {
        string key=name+"|"+width;
        if(artwork.TryGetValue(key,out var existing))return existing;
        var image=new BitmapImage();
        image.BeginInit();image.CacheOption=BitmapCacheOption.OnLoad;image.DecodePixelWidth=width;
        image.UriSource=new Uri("pack://application:,,,/ReflexCore.Studio;component/Art/"+name,UriKind.Absolute);
        image.EndInit();image.Freeze();
        var brush=new ImageBrush(image){Stretch=Stretch.UniformToFill};brush.Freeze();
        return artwork[key]=brush;
    }
    static TextBlock Label(string value,double size,string key="Text")
    {
        var label=new TextBlock{Text=value,FontSize=size,VerticalAlignment=VerticalAlignment.Center};
        label.SetResourceReference(TextBlock.ForegroundProperty,key);return label;
    }
    static Button Command(string text,Action handler)
    {
        var b=new Button{Content=text};b.Click+=(_,_)=>handler();AutomationProperties.SetName(b,text);return b;
    }
    void BuildShell()
    {
        InitCaption();background.Children.Add(wallpaper);background.Children.Add(rain);background.Children.Add(layout);
        layout.ColumnDefinitions.Add(railWidth);layout.ColumnDefinitions.Add(new ColumnDefinition());
        sidebar.BorderThickness=new Thickness(0,0,1,0);sidebar.SetResourceReference(Border.BorderBrushProperty,"PanelOutline");
        var sidebarLayout=new DockPanel();
        var support=Command("GitHub Support",()=>System.Diagnostics.Process.Start(
            new System.Diagnostics.ProcessStartInfo("https://github.com/sponsors/triple6xseven"){UseShellExecute=true}));
        support.ToolTip="GitHub Support";
        support.Margin=new Thickness(8,8,8,10);
        DockPanel.SetDock(support,Dock.Bottom);
        sidebarLayout.Children.Add(support);
        SizeChanged+=(_,_)=>support.Content=ActualWidth<1000?"♥":"GitHub Support";
        sidebarLayout.Children.Add(new ScrollViewer{Content=rail,VerticalScrollBarVisibility=ScrollBarVisibility.Auto});
        sidebar.Child=sidebarLayout;layout.Children.Add(sidebar);
        brand.Text="ReflexCore";brand.FontSize=23;brand.FontWeight=FontWeights.SemiBold;brand.Margin=new Thickness(16,24,10,26);
        brand.SetResourceReference(TextBlock.ForegroundProperty,"Text");rail.Children.Add(brand);
        nav.Margin=new Thickness(8,0,8,0);rail.Children.Add(nav);
        var tpl=NavigationTemplate();
        for(int index=0;index<names.Length;index++){
            int page=index;
            var row=new StackPanel{Orientation=Orientation.Horizontal};
            var icon=Label(glyphs[index],16);icon.FontFamily=new FontFamily("Segoe MDL2 Assets");icon.Width=34;row.Children.Add(icon);
            var caption=Label(names[index],14);row.Children.Add(caption);navLabels.Add(caption);
            var button=new Button{Template=tpl,Content=row,ToolTip=names[index],HorizontalContentAlignment=HorizontalAlignment.Left,
                Padding=new Thickness(12,10,8,10),Margin=new Thickness(0,0,0,3),Cursor=Cursors.Hand};
            AutomationProperties.SetName(button,names[index]);button.Click+=(_,_)=>SelectPage(page);nav.Children.Add(button);navButtons.Add(button);
        }
        var back=Command("←",()=>VisitHistory(-1));back.ToolTip="Previous page";back.Margin=new Thickness(10,16,10,0);
        back.HorizontalAlignment=HorizontalAlignment.Left;rail.Children.Add(back);
        var main=new DockPanel();Grid.SetColumn(main,1);layout.Children.Add(main);
        var head=new DockPanel{Margin=new Thickness(19,12,16,12)};
        var stopper=Command("■  Stop task",stop);stopper.ToolTip="Stop the current agent task";DockPanel.SetDock(stopper,Dock.Right);head.Children.Add(stopper);
        stage.FontSize=12;stage.Margin=new Thickness(12,0,16,0);stage.VerticalAlignment=VerticalAlignment.Center;stage.SetResourceReference(TextBlock.ForegroundProperty,"Sub");
        DockPanel.SetDock(stage,Dock.Right);head.Children.Add(stage);
        title.FontSize=24;title.FontWeight=FontWeights.SemiBold;title.VerticalAlignment=VerticalAlignment.Center;title.SetResourceReference(TextBlock.ForegroundProperty,"Text");head.Children.Add(title);
        pageHead.Child=head;DockPanel.SetDock(pageHead,Dock.Top);main.Children.Add(pageHead);
        body.Children.Add(native);body.Children.Add(appearance);body.Children.Add(widgets);main.Children.Add(body);
    }
    void SizeRail()
    {
        bool compact=ActualWidth<1000;railWidth.Width=new GridLength(compact?72:220);brand.Text=compact?"RC":"ReflexCore";
        foreach(var label in navLabels)label.Visibility=compact?Visibility.Collapsed:Visibility.Visible;
    }
    public void SelectPage(int index)=>SwitchPage(index,true);
    void VisitHistory(int delta){
        int next=historyIndex+delta;
        if(next>=0 && next<history.Count){historyIndex=next;SwitchPage(history[next],false);}
    }
    void SwitchPage(int index,bool remember)
    {
        if(index<0||index>=names.Length)return;
        if(remember && active!=index){
            history.RemoveRange(historyIndex+1,history.Count-historyIndex-1);
            if(history.Count==64)history.RemoveAt(0);
            history.Add(index);historyIndex=history.Count-1;
        }
        active=index;title.Text=names[index];
        bool showAppearance=index==6, showWidgets=index==7;
        if(showAppearance && appearance.Content==null)BuildAppearance();
        if(showWidgets && widgets.Content==null)BuildWidgets();
        appearance.Visibility=showAppearance?Visibility.Visible:Visibility.Collapsed;
        widgets.Visibility=showWidgets?Visibility.Visible:Visibility.Collapsed;
        native.Visibility=showAppearance||showWidgets?Visibility.Collapsed:Visibility.Visible;
        if(!showAppearance && !showWidgets)pages.SelectedIndex=index;
        for(int i=0;i<navButtons.Count;i++)navButtons[i].SetResourceReference(Control.BackgroundProperty,i==index?"Track":"TransparentBrush");
        SizeRail();RefreshBackground();
    }
    void ApplyTheme(Theme theme,bool persist)
    {
        current=theme;
        foreach(var item in new Dictionary<string,string>{
            {"Text",theme.Text},{"Sub",theme.Sub},{"Accent",theme.Accent},{"Accent2",theme.Accent2},{"OnAccent",theme.OnAccent},
            {"Track",theme.Track},{"Card",theme.Card},{"SurfaceFill",theme.Card},{"SurfaceInset",theme.Track},{"SurfaceOutline",theme.Track},
            {"PanelOutline",theme.Track},{"PopupSurface",theme.Card},{"ButtonSurface",theme.Track},{"ButtonText",theme.Text}})
            Resources[item.Key]=Brush(item.Value);
        int k=theme.ControlKind;Resources["ControlKind"]=k;
        Resources["ButtonCorner"]=Resources["SurfaceCorner"]=new CornerRadius(k==1||theme.Pixel?1:7);
        Resources["ThumbCorner"]=new CornerRadius(k==1?1:12);Resources["ButtonGloss"]=theme.Glass?.18:0d;
        string texture=k==3?"alien-alloy.png":k==4?"dark-forged.png":k==6?"zxc-overdrive-rain.png":null;
        Resources["ThemeTexture"]=texture==null?Brushes.Transparent:(System.Windows.Media.Brush)Artwork(texture,600);
        Resources["MaterialButtonTemplate"]=Resources[k==3?"AlienButtonTemplate":k==4?"FantasyButtonTemplate":k==5?"ZxcButtonTemplate":k==6?"OverdriveButtonTemplate":"ModernButtonTemplate"];
        FontFamily=new FontFamily(typeface??theme.Font);Background=background.Background=Brush(theme.Bg);
        sidebar.Background=Brush(theme.Card);pageHead.Background=Brush(theme.Card);
        motionSwitch.RefreshSkin();captionSwitch.RefreshSkin();wallpaperSwitch.RefreshSkin();
        PaintPages(pages,theme);PaintTiles();RefreshBackground();
        if(persist)save(theme.Name);
    }
    void RefreshBackground()
    {
        string asset=chosenWall ?? current.Artwork ?? (current.Name=="zxc"?"zxc-overdrive-rain.png":null);
        wallpaper.Background=asset!=null && showWallpaper?Artwork(asset,960):null;
        wallpaper.Opacity=1-tint/125; var ink=Col(current.Card);ink.A=(byte)(100+tint*1.55);sidebar.Background=pageHead.Background=new SolidColorBrush(ink);
        rain.SetRunning(animate && current.Name=="Hacker" && active==6 && WindowState!=WindowState.Minimized);
    }
    static void PaintPages(Forms.Control c,Theme theme)
    {
        var bg=System.Drawing.ColorTranslator.FromHtml(theme.Bg);
        var card=System.Drawing.ColorTranslator.FromHtml(theme.Card);
        var ink=System.Drawing.ColorTranslator.FromHtml(theme.Text);
        var track=System.Drawing.ColorTranslator.FromHtml(theme.Track);
        var accent=System.Drawing.ColorTranslator.FromHtml(theme.Accent);
        if(c is Forms.DataGridView grid){
            grid.BackgroundColor=bg;grid.GridColor=track;grid.DefaultCellStyle.BackColor=card;grid.DefaultCellStyle.ForeColor=ink;
            grid.DefaultCellStyle.SelectionBackColor=track;grid.DefaultCellStyle.SelectionForeColor=ink;
            grid.ColumnHeadersDefaultCellStyle.BackColor=track;grid.ColumnHeadersDefaultCellStyle.ForeColor=accent;
        }else if(c is Forms.ListView list){
            list.BackColor=card;list.ForeColor=ink;list.Invalidate();
        }else if(c is Forms.TabControl tab){
            tab.BackColor=bg;tab.ForeColor=ink;tab.Invalidate();
        }else if(c is Forms.Button b){
            b.BackColor=track;b.ForeColor=ink;b.FlatAppearance.BorderColor=accent;
        }else if(c is Forms.TextBoxBase || c is Forms.ComboBox || c is Forms.NumericUpDown){
            c.BackColor=card;c.ForeColor=ink;
        }else if(c is Forms.Label || c is Forms.Panel || c is Forms.TabPage || c is Forms.Form || c is Forms.UserControl){
            if(c.BackColor.A!=0)c.BackColor=bg;c.ForeColor=ink;
        }
        foreach(Forms.Control child in c.Controls)PaintPages(child,theme);
        if(c.Tag is Action<System.Drawing.Color,System.Drawing.Color,System.Drawing.Color> paintChart)paintChart(card,ink,accent);
    }
    public void RestorePage(int page){SelectPage(page);if(WindowState==WindowState.Minimized)WindowState=WindowState.Normal;Activate();}
}

