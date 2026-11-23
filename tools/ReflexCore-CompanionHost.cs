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
        private WindowSurfaces surfaces;
        private DateTime settingsTime;
        private long settingsLength=-1;
        private long nextUpdate,stopDeadline;
        private bool restart,started,classicPreferred=true,companionPreferred,appStart;
        private int watchedGesture;
        private long gestureCheck;
        internal bool ClassicPreferred {get{return classicPreferred;}}
        private string statusSnapshot;
        private string message="Stopped";
        private string mode="taskbar";
        private bool physics=true;
        internal bool Running {get{return child!=null && !child.HasExited;}}

        internal void Show3D(bool showClassic,Action<bool> applyClassic)
        {
            try
            {
                applyClassic(showClassic);
                RememberCompanion(true);
                Start();
            }
            catch(IOException){message="Could not start Godot.";}
            catch(UnauthorizedAccessException){message="Could not start Godot.";}
            catch(System.ComponentModel.Win32Exception){message="Could not start Godot.";}
        }

        internal void Hide3D()
        {
            try{RememberCompanion(false);restart=false;Stop();}
            catch(IOException){message="Could not control the 3D renderer.";}
            catch(UnauthorizedAccessException){message="Could not control the 3D renderer.";}
        }

        internal CompanionHost(string project,string bridge,ActivityHud widget)
        {
            root=project;hud=widget;commandPath=Path.Combine(bridge,"widget-command.txt");
            var settings=ReadSettings("settings.json");
            appStart=Boolean(settings,"app_start",false);
            var saved=ReadSettings("widget-visibility.json");
            var previous=ReadSettings("host-status.json");
            object messageValue;
            bool previousSession=previous.TryGetValue("message",out messageValue) && !Object.Equals(messageValue,"Tray stopped");
            classicPreferred=Boolean(saved,"classic",!previousSession||Boolean(previous,"classic_visible",true));
            companionPreferred=Boolean(saved,"companion",appStart || previousSession && Boolean(previous,"running",false));
            if(Boolean(saved,"app_start",appStart)!=appStart)companionPreferred=appStart;
        }

        private string InBridge(string name){return Path.Combine(DirectoryPath,name);}
        private static bool Boolean(Dictionary<string,object> settings,string key,bool fallback)
        {
            object value;
            return settings.TryGetValue(key,out value) && value is bool?(bool)value:fallback;
        }
        private Dictionary<string,object> ReadSettings(string name)
        {
            var file=new FileInfo(InBridge(name));
            try
            {
                if(file.Exists && file.Length<=16384)
                    return json.Deserialize<Dictionary<string,object>>(File.ReadAllText(file.FullName)) ?? new Dictionary<string,object>();
            }
            catch(IOException){} catch(UnauthorizedAccessException){} catch(ArgumentException){} catch(InvalidOperationException){}
            return new Dictionary<string,object>();
        }
        internal void RememberClassic(bool visible)
        {
            classicPreferred=visible;
            SaveVisibility();
        }
        private void RememberCompanion(bool visible)
        {
            companionPreferred=visible;
            SaveVisibility();
        }
        private void SaveVisibility()
        {
            try{WriteText("widget-visibility.json",json.Serialize(new{classic=classicPreferred,companion=companionPreferred,app_start=appStart}));}
            catch(IOException){} catch(UnauthorizedAccessException){}
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
            bool revised=Boolean(settings,"app_start",false);
            if(revised!=appStart){appStart=revised;RememberCompanion(appStart);}
        }

        internal void Update(int pending,string queueState,bool capture,Action<bool> classicVisibility)
        {
            try
            {
                RefreshSettings();
                if(!started)
                {
                    started=true;
                    SaveVisibility();
                    if(companionPreferred)Start();
                }
                if(child!=null && child.HasExited)
                {
                    if(stopDeadline==0)
                    {
                        if(child.ExitCode==0)RememberCompanion(false);
                        message=child.ExitCode==0?"Stopped":"3D renderer exited. See runtime status.";
                    }
                    else message="Stopped";
                    child.Dispose();child=null;stopDeadline=0;
                    if(surfaces!=null){surfaces.Dispose();surfaces=null;}
                    if(restart){restart=false;Start();}
                }
                ReadCommand(classicVisibility);
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
                bool pause=capture||WindowSurfaces.ForegroundFullscreen(child.Id);
                WriteText("live.json",json.Serialize(hud.CompanionSnapshot(pending,queueState,!classic,pause,
                    new int[0][],null)));
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
                    RememberCompanion(true);Start();break;
                case "restart-3d":
                    Restart3D();break;
                case "stop-3d":Hide3D();break;
                case "show-classic":classicVisibility(true);break;
                case "hide-classic":classicVisibility(false);break;
                case "reset-classic-position":hud.ResetWidgetPosition();break;
                case "reset-3d-position":
                    if(Running)WriteText("reset-position.flag","1");
                    else if(File.Exists(InBridge("position.json")))File.Delete(InBridge("position.json"));
                    break;
            }
        }

        internal void Restart3D()
        {
            RememberCompanion(true);
            if(Running){restart=true;Stop();}
            else Start();
        }

        internal bool MouseInteractionEnabled()
        {
            return !Boolean(ReadSettings("settings.json"),"clickthrough",false);
        }
        internal bool ToggleMouseInteraction()
        {
            var settings=new Dictionary<string,object>();
            var file=new FileInfo(InBridge("settings.json"));
            if(file.Exists)
            {
                if(file.Length>16384)throw new IOException("Companion settings are too large.");
                try {settings=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(file.FullName));}
                catch(ArgumentException error){throw new IOException("Companion settings are invalid.",error);}
                catch(InvalidOperationException error){throw new IOException("Companion settings are invalid.",error);}
                if(settings==null)throw new IOException("Companion settings are invalid.");
            }
            bool enabled=Boolean(settings,"clickthrough",false);
            settings["clickthrough"]=!enabled;
            WriteText("settings.json",json.Serialize(settings));
            return enabled;
        }

        private void Start()
        {
            if(child!=null)
            {
                // Studio can request a preview before the previous child has exited.
                if(stopDeadline!=0||child.HasExited)restart=true;
                return;
            }
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
                FileName=executable,Arguments="--resolution 1x1 --position -32000,-32000 --path \""+project+"\" -- \""+DirectoryPath+"\"",
                WorkingDirectory=project,UseShellExecute=false,CreateNoWindow=true
            };
            child=Process.Start(start);
            message=child==null?"Could not start Godot.":"3D renderer started.";
            if(child!=null)
            {
                WriteText("surfaces.json","{\"edges\":[]}");
                watchedGesture=0;
                surfaces=new WindowSurfaces(child.Id,snapshot=>WriteText("surfaces.json",json.Serialize(snapshot)),
                    ()=>physics||mode=="windows"||mode=="roam",CheckGesture);
            }
        }

        [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);

        private void CheckGesture()
        {
            long now=Stopwatch.GetTimestamp();
            if(now<gestureCheck)return;
            gestureCheck=now+Stopwatch.Frequency/12;
            try
            {
                string active=InBridge("drag-active.txt");
                if(!File.Exists(active)||new FileInfo(active).Length>24)return;
                int token;
                if(!Int32.TryParse(File.ReadAllText(active),out token)||token<=0||token==watchedGesture)return;
                int primary=GetSystemMetrics(23)!=0?2:1;
                if((GetAsyncKeyState(primary)&0x8000)!=0)return;
                WriteText("drag-release.txt",token.ToString(System.Globalization.CultureInfo.InvariantCulture));
                watchedGesture=token;
            }
            catch(IOException){} catch(UnauthorizedAccessException){}
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
            if(surfaces!=null){surfaces.Dispose();surfaces=null;}
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
    // DWM geometry and transient support IDs. It does not read caption text or emit handles.
    internal sealed class WindowSurfaces : IDisposable
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

        private const uint LocationChange=0x800B, Show=0x8002, Reorder=0x8004;
        private const int ExStyle=-20, ToolWindow=0x80, AppWindow=0x40000, NoActivate=0x08000000;
        private delegate void WinEvent(IntPtr hook,uint kind,IntPtr hwnd,int objectId,int childId,uint thread,uint time);
        [DllImport("user32.dll")] private static extern IntPtr SetWinEventHook(uint first,uint last,IntPtr module,WinEvent callback,uint process,uint thread,uint flags);
        [DllImport("user32.dll")] private static extern bool UnhookWinEvent(IntPtr hook);
        [DllImport("user32.dll")] private static extern bool IsZoomed(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hwnd,int index);
        [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr hwnd,int index,int value);
        [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hwnd,IntPtr after,int x,int y,int width,int height,uint flags);

        private readonly int renderer;
        private readonly uint host;
        private readonly Action<object> publish;
        private readonly Func<bool> enabled;
        private readonly Timer timer=new Timer{Interval=40};
        private readonly WinEvent callback;
        private readonly List<IntPtr> hooks=new List<IntPtr>();
        private readonly Dictionary<IntPtr,int> ids=new Dictionary<IntPtr,int>();
        private int nextId;
        private bool dirty=true;
        private int ticks;
        private string lastGeometry;
        private IntPtr styled;

        internal WindowSurfaces(int renderer,Action<object> publish,Func<bool> enabled,Action gesture=null)
        {
            this.renderer=renderer;this.publish=publish;this.enabled=enabled;
            using(var own=Process.GetCurrentProcess())host=(uint)own.Id;
            callback=OnEvent;
            hooks.Add(SetWinEventHook(3,3,IntPtr.Zero,callback,0,0,2)); // foreground
            hooks.Add(SetWinEventHook(Show,Reorder,IntPtr.Zero,callback,0,0,2));
            hooks.Add(SetWinEventHook(LocationChange,LocationChange,IntPtr.Zero,callback,0,0,2));
            timer.Tick+=(sender,args)=>{if(gesture!=null)gesture();Refresh();};
            timer.Start();
        }

        private void OnEvent(IntPtr hook,uint kind,IntPtr hwnd,int objectId,int childId,uint thread,uint time)
        {
            if(objectId!=0||childId!=0||hwnd==IntPtr.Zero)return;
            uint pid;
            GetWindowThreadProcessId(hwnd,out pid);
            if(pid!=renderer)dirty=true;
        }

        private void Refresh()
        {
            if(!dirty && ++ticks<16)return;
            dirty=false;ticks=0;
            try
            {
                var edges=Scan(enabled());
                var key=String.Join(";",edges.ConvertAll(edge=>String.Join(",",edge)));
                if(key!=lastGeometry){publish(new{edges=edges});lastGeometry=key;}
            }
            catch(IOException){dirty=true;}
            catch(UnauthorizedAccessException){}
        }

        [ComImport,Guid("56FDF344-FD6D-11D0-958A-006097C9A090")]
        private class ShellTaskbar {}
        [ComImport,Guid("56FDF342-FD6D-11D0-958A-006097C9A090"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface ITaskbarList
        {
            void HrInit();
            void AddTab(IntPtr hwnd);
            void DeleteTab(IntPtr hwnd);
        }

        private void StyleOverlay(IntPtr hwnd)
        {
            int current=GetWindowLong(hwnd,ExStyle);
            int desired=(current|ToolWindow|NoActivate)&~AppWindow;
            if(desired!=current)
            {
                SetWindowLong(hwnd,ExStyle,desired);
                SetWindowPos(hwnd,IntPtr.Zero,0,0,0,0,0x37); // frame changed without moving or activating the overlay
            }
            if(styled!=hwnd||desired!=current)
            {
                try
                {
                    var shell=(ITaskbarList)new ShellTaskbar();
                    try {shell.HrInit();shell.DeleteTab(hwnd);styled=hwnd;}
                    finally {Marshal.ReleaseComObject(shell);}
                }
                catch(COMException){}
            }
        }

        private List<int[]> Scan(bool collect)
        {
            var edges=new List<int[]>(48);
            var covers=new List<System.Drawing.Rectangle>(64);
            var present=new HashSet<IntPtr>();
            var active=GetForegroundWindow();
            var monitors=Screen.AllScreens;
            int visited=0;
            EnumWindows((hwnd,ignored)=>{
                uint pid,cloaked;Rect frame;
                if(++visited>160)return false;
                GetWindowThreadProcessId(hwnd,out pid);
                if(!IsWindowVisible(hwnd)||IsIconic(hwnd))return true;
                if(pid==renderer)
                {
                    if(GetWindowTextLength(hwnd)>0 && DwmRect(hwnd,9,out frame,16)==0 && frame.Bottom-frame.Top>=250)
                        StyleOverlay(hwnd);
                    return true;
                }
                if(!collect || pid==host || (GetWindowLong(hwnd,ExStyle)&0x20)!=0 ||
                    (DwmInt(hwnd,14,out cloaked,4)==0&&cloaked!=0) ||
                    DwmRect(hwnd,9,out frame,16)!=0)return true;

                var bounds=System.Drawing.Rectangle.FromLTRB(frame.Left,frame.Top,frame.Right,frame.Bottom);
                if(bounds.Width<1||bounds.Height<1)return true;
                if(bounds.Width>=140 && bounds.Height>=90 && GetWindowTextLength(hwnd)>0 && !IsZoomed(hwnd))
                {
                    int id;
                    if(!ids.TryGetValue(hwnd,out id)){id=++nextId;ids.Add(hwnd,id);}
                    present.Add(hwnd);
                    foreach(var monitor in monitors)
                    {
                        var area=monitor.WorkingArea;
                        if(bounds.Top<=area.Top+12||bounds.Top>=area.Bottom-25)continue;
                        int left=Math.Max(bounds.Left,area.Left),right=Math.Min(bounds.Right,area.Right);
                        if(right-left<94)continue;
                        foreach(var segment in Exposed(left,right,bounds.Top,covers))
                        {
                            if(edges.Count==48)break;
                            edges.Add(new[]{segment[0],bounds.Top,segment[1]-segment[0],
                                Math.Min(bounds.Height,area.Bottom-bounds.Top),id,bounds.Left,bounds.Top,hwnd==active?1:0});
                        }
                    }
                }
                covers.Add(bounds);
                return true;
            },IntPtr.Zero);
            foreach(var hwnd in new List<IntPtr>(ids.Keys))
                if(!present.Contains(hwnd))ids.Remove(hwnd);
            return edges;
        }

        internal static List<int[]> Exposed(int left,int right,int y,List<System.Drawing.Rectangle> covers)
        {
            var segments=new List<int[]>{new[]{left,right}};
            foreach(var other in covers)
            {
                // Keep the edge and a small title/seat clearance strip visible.
                if(other.Top>y+10||other.Bottom<=y-65)continue;
                for(int i=segments.Count-1;i>=0;i--)
                {
                    var range=segments[i];
                    if(other.Right<=range[0]||other.Left>=range[1])continue;
                    segments.RemoveAt(i);
                    if(other.Left-range[0]>=94)segments.Add(new[]{range[0],other.Left});
                    if(range[1]-other.Right>=94)segments.Add(new[]{other.Right,range[1]});
                }
            }
            return segments;
        }

        internal static void SelfTest()
        {
            var covers=new List<System.Drawing.Rectangle>{new System.Drawing.Rectangle(320,20,200,200)};
            var edges=Exposed(100,900,150,covers);
            if(edges.Count!=2 || !edges.Exists(edge=>edge[0]==100&&edge[1]==320) ||
                !edges.Exists(edge=>edge[0]==520&&edge[1]==900))
                throw new InvalidOperationException("Companion partial occlusion failed.");
            covers.Add(new System.Drawing.Rectangle(90,140,840,180));
            if(Exposed(100,900,150,covers).Count!=0)
                throw new InvalidOperationException("Companion complete occlusion failed.");
        }

        public void Dispose()
        {
            timer.Dispose();
            foreach(var hook in hooks)if(hook!=IntPtr.Zero)UnhookWinEvent(hook);
        }
    }
}
