using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace ReflexCore.Studio;

public sealed partial class StudioWindow
{
    string chosenWall;
    void BuildAppearance()
    {
        var page=new StackPanel{Margin=new Thickness(22,18,22,26)};
        appearance.Content=page;new SmoothWheel(appearance,()=>smooth,()=>210);
        var filters=new WrapPanel{Margin=new Thickness(0,0,0,12)};
        category.ItemsSource=new[]{"All themes","Studio","Retro","Dark","Light","With artwork"};
        category.SelectedIndex=0;category.MinWidth=140;System.Windows.Automation.AutomationProperties.SetName(category,"Theme category");
        filters.Children.Add(category);page.Children.Add(filters);
        page.Children.Add(gallery);category.SelectionChanged+=(_,_)=>FillGallery();
        var detail=new Flow{MinW=310,MaxCols=2,Gap=14,Anim=animate,Margin=new Thickness(0,16,0,0)};
        page.Children.Add(detail);
        var material=Section(detail,"Material and background");
        AddSwitch(material,"Show theme artwork",wallpaperSwitch,v=>{showWallpaper=v;RefreshBackground();});
        var wall=Choice(material,"Background",new[]{"Use theme default","Alienwave","Dark Fantasy","zxc 2003","Overdrive"});
        wall.SelectionChanged+=(_,_)=>{chosenWall=new[]{null,"alien-studio.png","gothic-studio.png","zxc-2003-studio.png","zxc-overdrive-rain.png"}[wall.SelectedIndex];RefreshBackground();};
        var tintLabel=Label("",12,"Sub");material.Children.Add(tintLabel);
        var slider=new Sld(0,100,tint);material.Children.Add(slider);
        System.Windows.Automation.AutomationProperties.SetName(slider,"Material opacity");
        void PaintTint(){tintLabel.Text="Material opacity · "+tint.ToString("0")+"%";}
        slider.Changed+=v=>{tint=v;PaintTint();RefreshBackground();};PaintTint();
        var behaviour=Section(detail,"Motion and type");
        AddSwitch(behaviour,"Smooth scrolling",new Sw(true),v=>smooth=v);
        var appearanceFeedback = WidgetHint("");
        void SaveAppearance(string key, bool value)
        {
            try
            {
                WidgetSettings.Save(new System.Collections.Generic.Dictionary<string,object> { [key]=value },
                    new[] { key }, "studio-appearance.json");
                appearanceFeedback.Text = "";
            }
            catch (System.IO.IOException) { appearanceFeedback.Text = "Couldn't save appearance settings."; }
            catch (UnauthorizedAccessException) { appearanceFeedback.Text = "Appearance settings folder is unavailable."; }
        }
        AddSwitch(behaviour,"Theme animations",motionSwitch,v=>{
            animate=Fx.Fun=v;detail.Anim=v;RefreshBackground();
            SaveAppearance("theme_animations",v);
        });
        AddSwitch(behaviour,"Themed title bar",captionSwitch,v=>{
            ApplyCaption(v);
            SaveAppearance("themed_title_bar",v);
        });
        behaviour.Children.Add(appearanceFeedback);
        var fonts=Choice(behaviour,"Studio font",new[]{"Use theme default","Segoe UI","Consolas","Cambria","Tahoma"});
        fonts.SelectionChanged+=(_,_)=>{typeface=fonts.SelectedIndex==0?null:(string)fonts.SelectedItem;FontFamily=new FontFamily(typeface??current.Font);};
        FillGallery();
    }
    static StackPanel Section(Panel parent,string text)
    {
        var content=new StackPanel{Margin=new Thickness(12)};
        var name=Label(text,16);name.FontWeight=FontWeights.SemiBold;name.Margin=new Thickness(0,0,0,8);content.Children.Add(name);
        var surface=new Border{Child=content,CornerRadius=new CornerRadius(7),BorderThickness=new Thickness(1)};
        surface.SetResourceReference(Border.BackgroundProperty,"SurfaceFill");surface.SetResourceReference(Border.BorderBrushProperty,"PanelOutline");
        parent.Children.Add(surface);return content;
    }
    static void AddSwitch(Panel parent,string text,Sw control,Action<bool> change)
    {
        var row=new DockPanel{Margin=new Thickness(0,4,0,4)};control.Changed+=change;
        System.Windows.Automation.AutomationProperties.SetName(control,text);
        DockPanel.SetDock(control,Dock.Right);row.Children.Add(control);row.Children.Add(Label(text,13));parent.Children.Add(row);
    }
    static ComboBox Choice(Panel panel,string text,string[] options){
        var label=Label(text,12,"Sub");label.Margin=new Thickness(0,6,0,3);panel.Children.Add(label);
        var box=new ComboBox{ItemsSource=options,SelectedIndex=0,Padding=new Thickness(7,4,7,4)};
        System.Windows.Automation.AutomationProperties.SetName(box,text);panel.Children.Add(box);return box;
    }
    void FillGallery()
    {
        gallery.Children.Clear();
        foreach(var theme in Theme.All){
            bool studio=theme.Glass||theme.ControlKind>=3;
            bool retro=theme.Pixel||theme.ControlKind==1||theme.ControlKind==2||theme.Name=="zxc 2003";
            if(category.SelectedIndex==1&&!studio || category.SelectedIndex==2&&!retro ||
                category.SelectedIndex==3&&!theme.Dark || category.SelectedIndex==4&&theme.Dark ||
                category.SelectedIndex==5&&theme.Artwork==null)continue;
            var tile=ThemeTile(theme,true);tile.Click+=(_,_)=>ApplyTheme(theme,true);gallery.Children.Add(tile);
        }
        PaintTiles();
    }
    void PaintTiles(){
        foreach(Button b in gallery.Children)b.SetResourceReference(Control.BorderBrushProperty,
            (string)b.Tag==current.Name?"Accent":"TransparentBrush");
    }
    // Exercise the same view and dispatch paths as an operator, without writing preferences.
    public void VerifyView()
    {
        for(int i=0;i<6;i++){
            SelectPage(i);UpdateLayout();Forms.Application.DoEvents();
            if(pages.SelectedIndex!=i || !native.IsVisible || !pages.TabPages[i].Visible)
                throw new InvalidOperationException("An operator page did not become visible");
        }
        SelectPage(6);UpdateLayout();
        if(gallery.Children.Count!=45||!appearance.IsVisible)throw new InvalidOperationException("Appearance gallery incomplete");
        category.SelectedIndex=3;
        if(gallery.Children.Count!=Theme.All.Count(theme=>theme.Dark))throw new InvalidOperationException("Theme category filter failed");
        category.SelectedIndex=0;
        SelectPage(7);UpdateLayout();
        if(!widgets.IsVisible || native.IsVisible || widgets.Content==null)throw new InvalidOperationException("Widget settings page unavailable");
        SelectPage(6);
        foreach(var theme in Theme.All){ApplyTheme(theme,false);UpdateLayout();}
        Width=900;UpdateLayout();if(railWidth.Width.Value!=72)throw new InvalidOperationException("Compact navigation failed");
        Width=1180;UpdateLayout();ApplyCaption(true);ApplyCaption(false);
        SelectPage(0);VisitHistory(-1);
        if(active!=6)throw new InvalidOperationException("Navigation history failed");
    }
}

