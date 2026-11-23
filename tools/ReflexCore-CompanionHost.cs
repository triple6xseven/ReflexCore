using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace ReflexCore.Bridge
{
    internal sealed class CompanionHost : IDisposable
    {
        internal static readonly string DirectoryPath=Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ReflexCore","companion3d");
        private readonly string root, commandPath;
        private readonly ActivityHud hud;
        private readonly JavaScriptSerializer json=new JavaScriptSerializer{MaxJsonLength=16384,RecursionLimit=10};
        private Process child;
        private DateTime settingsTime;
        private long settingsLength=-1;
        private long nextUpdate,stopDeadline;
        private bool restart,started;
        private string statusSnapshot;
        private string message="Stopped";
        private string mode="taskbar";
        private bool physics=true;
        internal bool Running {get{return child!=null && !child.HasExited;}}

        internal void Show3D(bool showClassic,Action<bool> applyClassic)
        {
            try
            {
                hud.ShowClassicOnly();
                applyClassic(showClassic);
                Start();
            }
            catch(IOException){message="Could not start Godot.";}
            catch(UnauthorizedAccessException){message="Could not start Godot.";}
            catch(System.ComponentModel.Win32Exception){message="Could not start Godot.";}
        }

        internal void Hide3D()
        {
            try{restart=false;Stop();}
            catch(IOException){message="Could not control the 3D renderer.";}
            catch(UnauthorizedAccessException){message="Could not control the 3D renderer.";}
        }

        internal CompanionHost(string project,string bridge,ActivityHud widget)
        {
            root=project;hud=widget;commandPath=Path.Combine(bridge,"widget-command.txt");
        }

        private string InBridge(string name){return Path.Combine(DirectoryPath,name);}
        private static bool Boolean(Dictionary<string,object> settings,string key,bool fallback)
        {
            object value;
            return settings.TryGetValue(key,out value) && value is bool?(bool)value:fallback;
        }
        private void RefreshSettings()
        {
            var file=new FileInfo(InBridge("settings.json"));
            if(!file.Exists || file.Length>16384 || (file.LastWriteTimeUtc==settingsTime && file.Length==settingsLength))return;
            var settings=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(file.FullName));
            if(settings==null)return;
            settingsTime=file.LastWriteTimeUtc;
            settingsLength=file.Length;
            object opacityValue, behavior;
            double opacity=.94;
            if(settings.TryGetValue("classic_opacity",out opacityValue) &&
                (opacityValue is double || opacityValue is decimal || opacityValue is int))
                opacity=Math.Max(.4,Math.Min(1,Convert.ToDouble(opacityValue)));
            if(settings.TryGetValue("mode",out behavior) && behavior is string)mode=(string)behavior;
            physics=Boolean(settings,"physics",true);
            hud.ConfigureClassic(opacity,Boolean(settings,"classic_host",true),
                Boolean(settings,"classic_gpu",true),Boolean(settings,"classic_ollama",true));
            if(!started && Boolean(settings,"app_start",false))Start();
        }

        internal void Update(int pending,string queueState,bool capture,Action<bool> classicVisibility)
        {
            try
            {
                RefreshSettings();
                started=true;
                ReadCommand(classicVisibility);
                if(child!=null && child.HasExited)
                {
                    if(stopDeadline==0)message=child.ExitCode==0?"Stopped":"3D renderer exited. See runtime status.";
                    else message="Stopped";
                    child.Dispose();child=null;stopDeadline=0;
                    if(restart){restart=false;Start();}
                }
                long now=Stopwatch.GetTimestamp();
                if(Running && stopDeadline!=0 && now>=stopDeadline)
                {
                    // This is the exact renderer started by the tray. Its PNG/VRM assets stay intact.
                    child.Kill();
                    message="Stopping 3D renderer";
                }
                hud.feedWhenHidden=Running && !capture;
                if(now<nextUpdate)return;
                nextUpdate=now+Stopwatch.Frequency/2;
                var classic=hud.ClassicVisible;
                string status=json.Serialize(new {
                    schema="reflexcore.companion.host.v1",classic_visible=classic,running=Running,
                    message=message
                });
                if(status!=statusSnapshot || !File.Exists(InBridge("host-status.json")))
                {
                    WriteText("host-status.json",status);
                    statusSnapshot=status;
                }
                if(!Running)return;
                bool geometry=physics||mode=="windows"||mode=="roam";
                bool pause=capture||WindowSurfaces.ForegroundFullscreen(child.Id);
                WriteText("live.json",json.Serialize(hud.CompanionSnapshot(pending,queueState,!classic,pause,
                    geometry&&!pause?WindowSurfaces.Scan(child.Id):new int[0][])));
            }
            catch(IOException){} catch(UnauthorizedAccessException){}
            catch(ArgumentException){} catch(InvalidOperationException){}
            catch(System.ComponentModel.Win32Exception){message="Could not control the 3D renderer.";}
        }

        private void ReadCommand(Action<bool> classicVisibility)
        {
            if(!File.Exists(commandPath))return;
            string claimed=commandPath+".claimed-"+Guid.NewGuid().ToString("N");
            File.Move(commandPath,claimed);
            string action;
            try
            {
                using(var file=File.OpenRead(claimed))
                using(var reader=new StreamReader(file))
                    action=file.Length<=128?reader.ReadToEnd().Trim():"";
            }
            finally{File.Delete(claimed);}
            switch(action)
            {
                case "start-3d":
                    NormalizeLegacy(classicVisibility);Start();break;
                case "restart-3d":
                    NormalizeLegacy(classicVisibility);
                    if(Running){restart=true;Stop();}else Start();
                    break;
                case "stop-3d":restart=false;Stop();break;
                case "show-classic":hud.ShowClassicOnly();classicVisibility(true);break;
                case "hide-classic":classicVisibility(false);break;
                case "reset-classic-position":hud.ResetWidgetPosition();break;
            }
        }

        private void NormalizeLegacy(Action<bool> classicVisibility)
        {
            if(hud.LegacyOnly)classicVisibility(false);
            hud.ShowClassicOnly();
        }

        private void Start()
        {
            if(child!=null)return;
            string project=Path.Combine(root,"companion3d");
            string configured=InBridge("runtime-exe.txt");
            if(!File.Exists(configured)||new FileInfo(configured).Length>2048 ||
                !File.Exists(Path.Combine(project,"project.godot")))
            {message="Godot runtime is not configured.";return;}
            string executable=File.ReadAllText(configured).Trim();
            if(executable.IndexOf('"')>=0 || !Path.IsPathRooted(executable) ||
                !Path.GetFileName(executable).StartsWith("Godot",StringComparison.OrdinalIgnoreCase) ||
                !Path.GetExtension(executable).Equals(".exe",StringComparison.OrdinalIgnoreCase) ||
                !File.Exists(executable)){message="Godot executable is unavailable.";return;}
            foreach(string name in new[]{"stop.flag","status.json"})if(File.Exists(InBridge(name)))File.Delete(InBridge(name));
            var start=new ProcessStartInfo {
                FileName=executable,Arguments="--path \""+project+"\" -- \""+DirectoryPath+"\"",
                WorkingDirectory=project,UseShellExecute=false,CreateNoWindow=true
            };
            child=Process.Start(start);
            message=child==null?"Could not start Godot.":"3D renderer started.";
        }

        private void Stop()
        {
            if(!Running)return;
            File.WriteAllText(InBridge("stop.flag"),"stop");
            stopDeadline=Stopwatch.GetTimestamp()+4*Stopwatch.Frequency;
            message="Stopping 3D renderer";
        }

        private void WriteText(string name,string contents)
        {
            Directory.CreateDirectory(DirectoryPath);
            string path=InBridge(name),temporary=path+".next";
            File.WriteAllText(temporary,contents);
            if(File.Exists(path))File.Replace(temporary,path,null);
            else File.Move(temporary,path);
        }

        public void Dispose()
        {
            try
            {
                if(child!=null){Stop();if(!child.WaitForExit(900))child.Kill();}
                WriteText("host-status.json",json.Serialize(new {
                    schema="reflexcore.companion.host.v1",classic_visible=false,running=false,message="Tray stopped"
                }));
            }
            catch(InvalidOperationException){} catch(IOException){} catch(UnauthorizedAccessException){}
            catch(System.ComponentModel.Win32Exception){}
            finally{if(child!=null)child.Dispose();child=null;}
        }
    }

    // Same visible / non-cloaked filter as the existing Rust observer. This boundary returns
    // only DWM geometry and does not read captions or emit window identifiers.
    internal static class WindowSurfaces
    {
        [StructLayout(LayoutKind.Sequential)] private struct Rect {public int Left,Top,Right,Bottom;}
        private delegate bool Visit(IntPtr hwnd,IntPtr ignored);
        [DllImport("user32.dll")] private static extern bool EnumWindows(Visit visit,IntPtr ignored);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
        [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetWindowTextLength(IntPtr hwnd);
        [DllImport("dwmapi.dll",EntryPoint="DwmGetWindowAttribute")]
        private static extern int DwmInt(IntPtr hwnd,uint attribute,out uint value,uint length);
        [DllImport("dwmapi.dll",EntryPoint="DwmGetWindowAttribute")]
        private static extern int DwmRect(IntPtr hwnd,uint attribute,out Rect value,uint length);

        internal static bool ForegroundFullscreen(int excludedPid)
        {
            var active=GetForegroundWindow();
            uint pid;Rect frame;
            if(GetWindowThreadProcessId(active,out pid)==0 || pid==excludedPid ||
                GetWindowTextLength(active)==0 || DwmRect(active,9,out frame,16)!=0)return false;
            var bounds=System.Drawing.Rectangle.FromLTRB(frame.Left,frame.Top,frame.Right,frame.Bottom);
            var screen=Screen.FromRectangle(bounds).Bounds;
            return bounds.Left<=screen.Left+1 && bounds.Top<=screen.Top+1 &&
                bounds.Right>=screen.Right-1 && bounds.Bottom>=screen.Bottom-1;
        }

        internal static int[][] Scan(int renderer)
        {
            var list=new List<int[]>(24);
            var foreground=GetForegroundWindow();
            uint host;
            using(var own=Process.GetCurrentProcess())host=(uint)own.Id;
            EnumWindows((hwnd,ignored)=>{
                uint pid,cloaked;Rect frame;
                GetWindowThreadProcessId(hwnd,out pid);
                if(pid==host || pid==renderer || !IsWindowVisible(hwnd) || IsIconic(hwnd) || GetWindowTextLength(hwnd)==0 ||
                    (DwmInt(hwnd,14,out cloaked,4)==0&&cloaked!=0) ||
                    DwmRect(hwnd,9,out frame,16)!=0)return true;
                int width=frame.Right-frame.Left,height=frame.Bottom-frame.Top;
                if(width<180||height<100)return true;
                var bounds=new[]{frame.Left,frame.Top,width,height};
                if(hwnd==foreground)list.Insert(0,bounds);else list.Add(bounds);
                return list.Count<24;
            },IntPtr.Zero);
            return list.ToArray();
        }
    }
}
