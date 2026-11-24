using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using Forms = System.Windows.Forms;

namespace ReflexCore.Studio;

public sealed partial class StudioWindow
{
    Window mcpSettingsWindow;

    void ShowMcpSettings(string settingsPath)
    {
        if(mcpSettingsWindow!=null){mcpSettingsWindow.Activate();return;}
        var registry=Path.Combine(settingsPath,"mcp-projects.json");
        var legacy=Path.Combine(settingsPath,"mcp-scope.txt");
        var serializer=new JavaScriptSerializer {MaxJsonLength=16384};
        var projects=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            if(File.Exists(registry))
            {
                foreach(var item in serializer.Deserialize<Dictionary<string,string>>(File.ReadAllText(registry)))
                    projects.Add(item.Key,item.Value);
            }
            else if(File.Exists(legacy))projects.Add("default",File.ReadAllText(legacy));
        }
        catch(Exception error) when(error is IOException || error is UnauthorizedAccessException ||
            error is InvalidOperationException || error is ArgumentException)
        {
            MessageBox.Show(this,"Could not read the project registry.","MCP settings");
            return;
        }

        var window=new Window {Title="MCP settings",Owner=this,WindowStartupLocation=WindowStartupLocation.CenterOwner,
            Width=690,Height=450,MinWidth=530,MinHeight=390,ShowInTaskbar=false,FontFamily=FontFamily};
        window.Resources.MergedDictionaries.Add(Resources);
        window.Background=Brush(current.Bg);
        window.Foreground=Brush(current.Text);

        var content=new DockPanel {Margin=new Thickness(20)};
        var header=new StackPanel {Margin=new Thickness(0,0,0,12)};
        header.Children.Add(Label("Connected projects",21));
        header.Children.Add(new TextBlock {Text="Select a project to see its folder. Each file check requires Studio approval.",
            TextWrapping=TextWrapping.Wrap,Foreground=Brush(current.Sub),Margin=new Thickness(0,6,0,0)});
        DockPanel.SetDock(header,Dock.Top);
        content.Children.Add(header);

        var list=new ListBox {Background=Brush(current.Card),Foreground=Brush(current.Text),
            BorderBrush=Brush(current.Track),Padding=new Thickness(6)};
        var path=new TextBox {IsReadOnly=true,TextWrapping=TextWrapping.Wrap,Background=Brush(current.Card),
            Foreground=Brush(current.Text),BorderBrush=Brush(current.Track),Padding=new Thickness(8),
            Margin=new Thickness(0,5,0,8),MinHeight=45};
        AutomationProperties.SetName(path,"Selected project folder");
        var status=new TextBlock {Foreground=Brush(current.Sub),TextWrapping=TextWrapping.Wrap,
            Margin=new Thickness(0,6,0,0)};
        var footer=new StackPanel {Margin=new Thickness(0,12,0,0)};
        footer.Children.Add(Label("Project folder",13));
        footer.Children.Add(path);
        var actions=new WrapPanel();
        footer.Children.Add(actions);
        footer.Children.Add(status);
        DockPanel.SetDock(footer,Dock.Bottom);
        content.Children.Add(footer);
        content.Children.Add(list);

        Button AddAction(string title,Action handler)
        {
            var button=Command(title,handler);
            button.Padding=new Thickness(13,6,13,6);
            button.Margin=new Thickness(0,0,7,5);
            button.SetResourceReference(Control.TemplateProperty,"MaterialButtonTemplate");
            actions.Children.Add(button);
            return button;
        }

        void Refresh(string selection)
        {
            list.ItemsSource=projects.Keys.OrderBy(key=>key,StringComparer.OrdinalIgnoreCase).ToArray();
            list.SelectedItem=selection;
            if(list.SelectedIndex<0 && list.Items.Count>0)list.SelectedIndex=0;
            status.Text=projects.Count==0?"No projects connected. Select Add project to get started.":"";
        }

        bool Save(Dictionary<string,string> next)
        {
            string temporary=registry+"."+Guid.NewGuid().ToString("N")+".tmp";
            try
            {
                var data=serializer.Serialize(next);
                if(data.Length>16384)throw new InvalidOperationException();
                Directory.CreateDirectory(settingsPath);
                File.WriteAllText(temporary,data);
                if(File.Exists(registry))File.Replace(temporary,registry,null);
                else File.Move(temporary,registry);
                projects=next;
                return true;
            }
            catch(Exception error) when(error is IOException || error is UnauthorizedAccessException ||
                error is InvalidOperationException)
            {
                status.Text="Could not save projects. The current list is unchanged.";
                return false;
            }
            finally {try{File.Delete(temporary);}catch(IOException){}catch(UnauthorizedAccessException){}}
        }

        void PickFolder(string selected)
        {
            using var picker=new Forms.FolderBrowserDialog {Description="Choose an existing local project folder.",
                ShowNewFolderButton=false,SelectedPath=selected==null?"":projects[selected]};
            if(picker.ShowDialog()!=Forms.DialogResult.OK)return;
            var chosen=picker.SelectedPath;
            var name=selected??Regex.Replace(new DirectoryInfo(chosen).Name,"[^A-Za-z0-9_-]","-").Trim('-');
            if(name.Length==0 || name.Length>48 || !Regex.IsMatch(chosen,@"\A[A-Za-z]:\\") ||
                String.Equals(Path.GetPathRoot(chosen),chosen,StringComparison.OrdinalIgnoreCase))
            {
                status.Text="Choose a named project folder on a local drive.";
                return;
            }
            if(selected==null && projects.ContainsKey(name))
            {
                Refresh(name);
                status.Text="That name is already connected. Use Change folder to update it.";
                return;
            }
            var next=new Dictionary<string,string>(projects,StringComparer.OrdinalIgnoreCase) {[name]=chosen};
            if(Save(next)){Refresh(name);status.Text="Project folder saved.";}
        }

        AddAction("Add project",()=>PickFolder(null));
        var change=AddAction("Change folder",()=>PickFolder(list.SelectedItem as string));
        var remove=AddAction("Disconnect",()=>{
            if(!(list.SelectedItem is string name))return;
            if(MessageBox.Show(window,"Disconnect "+name+" from MCP? Its files will stay in place.",
                "Disconnect project",MessageBoxButton.YesNo)!=MessageBoxResult.Yes)return;
            var next=new Dictionary<string,string>(projects,StringComparer.OrdinalIgnoreCase);
            next.Remove(name);
            if(Save(next))Refresh(null);
        });
        AddAction("Close",()=>window.Close());
        list.SelectionChanged+=(_,_)=>{
            var key=list.SelectedItem as string;
            change.IsEnabled=remove.IsEnabled=key!=null;
            path.Text=key==null?"":projects[key];
        };
        window.PreviewKeyDown+=(_,args)=>{if(args.Key==System.Windows.Input.Key.Escape){args.Handled=true;window.Close();}};
        window.Closed+=(_,_)=>mcpSettingsWindow=null;
        window.Content=content;
        change.IsEnabled=remove.IsEnabled=false;
        Refresh(null);
        mcpSettingsWindow=window;
        window.Show();
    }
}
