using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace ReflexCore.Practice
{
    internal sealed class PracticeSettings
    {
        public string schema { get; set; }
        public string runner_exe { get; set; }
        public string mailbox { get; set; }
        public string route { get; set; }
        public string server_exe { get; set; }
        public int port { get; set; }
        public bool stationary_opponent { get; set; }

        internal static PracticeSettings Load(string root)
        {
            var path=Path.Combine(root,"data","settings","cs16-practice.json");
            var settings=PracticePanel.Decode<PracticeSettings>(PracticePanel.ReadText(path,4096),4096);
            if(settings.schema!="reflexcore.cs16.practice.launcher.v1") throw new InvalidDataException("Unsupported practice settings.");
            settings.runner_exe=LocalPath(root,settings.runner_exe);
            if(!settings.runner_exe.StartsWith(root.TrimEnd('\\')+"\\",StringComparison.OrdinalIgnoreCase) ||
                !Path.GetFileName(settings.runner_exe).Equals("reflexcore.exe",StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Set runner_exe to the built ReflexCore executable inside this project.");
            for(string part=settings.runner_exe;part.Length>root.Length;part=Path.GetDirectoryName(part))
                if((File.GetAttributes(part)&FileAttributes.ReparsePoint)!=0)
                    throw new InvalidDataException("Runner path must stay inside the project.");
            settings.mailbox=LocalPath(root,settings.mailbox);
            const string suffix=@"\cstrike\addons\amxmodx\data\reflexcore";
            if(!settings.mailbox.EndsWith(suffix,StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Select the AMX Mod X practice mailbox.");
            settings.route=LocalPath(root,settings.route);
            string expectedServer=Path.Combine(settings.mailbox.Substring(0,settings.mailbox.Length-suffix.Length),"hlds.exe");
            bool startServer=!String.IsNullOrWhiteSpace(settings.server_exe);
            settings.server_exe=startServer?LocalPath(root,settings.server_exe):expectedServer;
            if(!settings.server_exe.Equals(expectedServer,StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The server executable must belong to the configured practice mailbox.");
            settings.MayStartServer=startServer;
            if(settings.port==0)settings.port=27125;
            if(settings.port<1024 || settings.port>65535)throw new InvalidDataException("Practice port is out of range.");
            return settings;
        }

        internal bool MayStartServer { get; private set; }

        private static string LocalPath(string root,string value)
        {
            if(String.IsNullOrWhiteSpace(value))throw new InvalidDataException("Practice settings are incomplete.");
            string path=Path.GetFullPath(Path.IsPathRooted(value)?value:Path.Combine(root,value)).TrimEnd('\\');
            if(!Regex.IsMatch(path,@"^[A-Za-z]:\\") || path.IndexOf(':',2)>=0)
                throw new InvalidDataException("Practice paths must be local files or directories.");
            return path;
        }
    }

    internal sealed class PracticeRoute
    {
        public sealed class Waypoint
        {
            public double x { get; set; }
            public double y { get; set; }
            public double z { get; set; }
        }
        public string schema { get; set; }
        public string map { get; set; }
        public string site { get; set; }
        public Waypoint[] waypoints { get; set; }

        internal static PracticeRoute Load(string path)
        {
            const int limit=32*1024;
            var route=PracticePanel.Decode<PracticeRoute>(PracticePanel.ReadText(path,limit),limit);
            if(route.schema!="reflexcore.cs16.route.v1" || !Regex.IsMatch(route.map??"", @"\A[a-z0-9_]{1,32}\z") ||
               (route.site!="A" && route.site!="B") || route.waypoints==null || route.waypoints.Length<2 || route.waypoints.Length>128)
                throw new InvalidDataException("Practice route is invalid.");
            foreach(var point in route.waypoints)
                if(point==null || !PracticeState.Coordinate(point.x) || !PracticeState.Coordinate(point.y) || !PracticeState.Coordinate(point.z))
                    throw new InvalidDataException("Practice route contains invalid positions.");
            return route;
        }
    }

    internal sealed class PracticeState
    {
        private static readonly char[] Separator={' ','\t','\r','\n'};
        internal uint Sequence, Actor;
        internal double Tick, X, Y;
        internal bool Alive, C4, InZone, Equipped, Planted, Won;
        internal string Map, Status;

        internal static bool Coordinate(double number) { return Math.Abs(number)<=32768; }

        internal static PracticeState Parse(string text)
        {
            if(text.Length>512 || !text.EndsWith("\n",StringComparison.Ordinal))
                throw new InvalidDataException("Incomplete engine observation.");
            string[] fields=text.Split(Separator,StringSplitOptions.RemoveEmptyEntries);
            var state=new PracticeState();
            if(fields.Length!=18 || fields[0]!="reflexcore_cs16_practice_v1" ||
               !Regex.IsMatch(fields[1],@"\A[a-z0-9_]{1,32}\z") ||
               !UInt32.TryParse(fields[2],NumberStyles.None,CultureInfo.InvariantCulture,out state.Sequence) ||
               !Double.TryParse(fields[3],NumberStyles.Float,CultureInfo.InvariantCulture,out state.Tick) ||
               state.Tick<0 || !Coordinate(state.Tick/1000) ||
               !UInt32.TryParse(fields[4],NumberStyles.None,CultureInfo.InvariantCulture,out state.Actor) ||
               !Double.TryParse(fields[7],NumberStyles.Float,CultureInfo.InvariantCulture,out state.X) || !Coordinate(state.X) ||
               !Double.TryParse(fields[8],NumberStyles.Float,CultureInfo.InvariantCulture,out state.Y) || !Coordinate(state.Y) ||
               !Regex.IsMatch(fields[17],@"\A(ready|added|moved|stopped|rejected|unavailable|equipped|restarting|passive_ct|match_ct|fired)\z"))
                throw new InvalidDataException("Engine observation is invalid.");
            state.Map=fields[1];
            state.Status=fields[17];
            state.Alive=Flag(fields[5]);
            state.C4=Flag(fields[11]);
            state.InZone=Flag(fields[12]);
            state.Equipped=Flag(fields[13]);
            state.Planted=Flag(fields[14]);
            state.Won=Flag(fields[15]);
            return state;
        }

        private static bool Flag(string value)
        {
            if(value=="1")return true;
            if(value=="0")return false;
            throw new InvalidDataException("Engine observation flag is invalid.");
        }
    }

    internal sealed class PracticeReport
    {
        public string schema { get; set; }
        public string map { get; set; }
        public uint engine_subject_id { get; set; }
        public bool verified_plant { get; set; }
        public bool match_mode { get; set; }
        public bool verified_bot_defeat { get; set; }
        public bool verified_round_win { get; set; }
        public string outcome { get; set; }
        public int total_ms { get; set; }
        public int navigation_ms { get; set; }
        public int plant_ms { get; set; }
    }

    internal sealed class MatchBenchmark
    {
        public string schema { get; set; }
        public int verified_plant_bot_round_wins { get; set; }
    }

    internal static class PracticeEndpoint
    {
        [DllImport("iphlpapi.dll")]
        private static extern uint GetExtendedUdpTable(IntPtr table,ref uint size,bool order,int family,int tableClass,uint reserved);

        internal static int Owner(int port)
        {
            uint size=0;
            uint result=GetExtendedUdpTable(IntPtr.Zero,ref size,false,2,1,0);
            if(result!=122 || size<4 || size>1024*1024)throw new InvalidOperationException("Cannot verify the practice listener.");
            var table=Marshal.AllocHGlobal((int)size);
            try
            {
                result=GetExtendedUdpTable(table,ref size,false,2,1,0);
                if(result!=0)throw new InvalidOperationException("Cannot verify the practice listener.");
                int count=Marshal.ReadInt32(table);
                if(count<0 || count>(size-4)/12)throw new InvalidOperationException("Invalid listener table.");
                int owner=0;
                for(int row=0;row<count;row++)
                {
                    int offset=4+row*12;
                    int encoded=Marshal.ReadInt32(table,offset+4);
                    int localPort=((encoded&0xff)<<8)|((encoded>>8)&0xff);
                    if(localPort!=port)continue;
                    if(Marshal.ReadInt32(table,offset)!=0x0100007f || owner!=0)
                        throw new InvalidOperationException("Practice port must belong to one loopback listener.");
                    owner=Marshal.ReadInt32(table,offset+8);
                }
                return owner;
            }
            finally { Marshal.FreeHGlobal(table); }
        }
    }

    internal sealed class RoutePlot : System.Windows.Forms.Control
    {
        private PracticeRoute route;
        private PracticeState actor;
        private double left,bottom,right,top;

        internal RoutePlot()
        {
            DoubleBuffered=true;
            ResizeRedraw=true;
            BackColor=Color.FromArgb(18,28,43);
            Dock=DockStyle.Fill;
            AccessibleName="Practice route and live actor coordinates";
        }

        internal void SetRoute(PracticeRoute value)
        {
            route=value;
            actor=null;
            if(value==null){Invalidate();return;}
            left=right=value.waypoints[0].x;
            bottom=top=value.waypoints[0].y;
            foreach(var point in value.waypoints)
            {
                left=Math.Min(left,point.x); right=Math.Max(right,point.x);
                bottom=Math.Min(bottom,point.y); top=Math.Max(top,point.y);
            }
            Invalidate();
        }

        internal void SetActor(PracticeState value)
        {
            var previous=actor;
            actor=value;
            if(previous==null || value==null || previous.X!=value.X || previous.Y!=value.Y || previous.Planted!=value.Planted)Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            if(ClientSize.Width<90 || ClientSize.Height<90)return;
            if(route==null)
            {
                if(actor!=null)
                    e.Graphics.DrawString(actor.Planted?"Engine confirmed C4":"Tracking engine position",
                                          Font,Brushes.WhiteSmoke,18,18);
                return;
            }
            float scale=(float)Math.Min((ClientSize.Width-82)/Math.Max(64,right-left),(ClientSize.Height-82)/Math.Max(64,top-bottom));
            Func<double,double,PointF> project=delegate(double x,double y) {
                return new PointF(ClientSize.Width/2f+(float)(x-(left+right)/2)*scale,
                                  ClientSize.Height/2f-(float)(y-(top+bottom)/2)*scale);
            };
            var points=new PointF[route.waypoints.Length];
            for(int i=0;i<points.Length;i++)points[i]=project(route.waypoints[i].x,route.waypoints[i].y);
            e.Graphics.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using(var line=new Pen(Color.FromArgb(103,144,189),2))
                e.Graphics.DrawLines(line,points);
            foreach(PointF point in points)e.Graphics.FillEllipse(Brushes.SlateGray,point.X-3,point.Y-3,6,6);
            var spawn=points[0];
            var plant=points[points.Length-1];
            e.Graphics.FillEllipse(Brushes.DeepSkyBlue,spawn.X-5,spawn.Y-5,10,10);
            e.Graphics.FillEllipse(Brushes.Orange,plant.X-6,plant.Y-6,12,12);
            e.Graphics.DrawString("Spawn",Font,Brushes.WhiteSmoke,spawn.X+8,spawn.Y-20);
            e.Graphics.DrawString("Site "+route.site,Font,Brushes.WhiteSmoke,plant.X+8,plant.Y-20);
            if(actor!=null)
            {
                var p=project(actor.X,actor.Y);
                e.Graphics.FillEllipse(actor.Planted?Brushes.PaleGreen:Brushes.White,p.X-6,p.Y-6,12,12);
                e.Graphics.DrawEllipse(Pens.Black,p.X-6,p.Y-6,12,12);
            }
        }
    }

    public sealed class PracticePanel : Form
    {
        private readonly string root;
        private readonly bool autoStart, matchMode;
        private readonly Button spectate=new Button(), replays=new Button();
        private Process recorder;
        private string recordStem, consoleLog;
        private string[] recorderControl = new string[0];
        private long consoleOffset;
        private int spectatorPort;
        private string replayFolder;
        private readonly RoutePlot plot=new RoutePlot();
        private readonly Label status=new Label(), evidence=new Label();
        private readonly Button start=new Button(), stop=new Button();
        private readonly System.Windows.Forms.Timer timer=new System.Windows.Forms.Timer();
        private readonly StringBuilder stdout=new StringBuilder();
        private readonly Stopwatch phaseClock=new Stopwatch(), recorderClock=new Stopwatch();
        private PracticeSettings settings;
        private PracticeRoute route;
        private readonly ComboBox mapSelection=new ComboBox {DropDownStyle=ComboBoxStyle.DropDownList,Width=180,AccessibleName="Offline demolition map"};
        private bool autoRoute;
        private Process controller, ownedServer;
        private string cancelFile;
        private DateTime runStartedUtc;
        private double? readyTick;
        private uint startSequence;
        private bool waiting, cancellation, closeAfter, outputOverflow, startAttempted;

        private PracticePanel(string rootPath,bool run,bool match)
        {
            root=rootPath; autoStart=run; matchMode=match;
            replayFolder=Path.Combine(root,"data","replays","cs16");
            Text=matchMode?"ReflexCore | CS 1.6 Offline Match":"ReflexCore | CS 1.6 Offline Practice";
            BackColor=Color.FromArgb(22,33,50);
            ForeColor=Color.WhiteSmoke;
            Font=new Font("Segoe UI",10);
            ClientSize=new Size(640,426);
            MinimumSize=new Size(480,340);
            StartPosition=FormStartPosition.CenterScreen;
            var top=new FlowLayoutPanel {Dock=DockStyle.Top,Height=60,Padding=new Padding(11,10,0,0)};
            start.Text=matchMode?"Run match again":"Start offline plant"; start.AutoSize=true; start.Click+=delegate { BeginRun(); };
            stop.Text="Stop"; stop.AutoSize=true; stop.Enabled=false; stop.Click+=delegate { RequestStop(); };
            spectate.Text="Copy spectate command"; spectate.AutoSize=true; spectate.Enabled=false;
            spectate.Click+=delegate {
                try { Clipboard.SetText("connect 127.0.0.1:"+spectatorPort.ToString(CultureInfo.InvariantCulture)); }
                catch(System.Runtime.InteropServices.ExternalException) { evidence.Text="Clipboard busy. Try again."; }
            };
            replays.Text="Recordings"; replays.AutoSize=true;
            replays.Click+=delegate {
                Directory.CreateDirectory(replayFolder);
                Process.Start("explorer.exe",Quote(replayFolder));
            };
            foreach(var button in new[] {start,stop,spectate,replays})
            {
                button.FlatStyle=FlatStyle.Flat;
                button.BackColor=Color.FromArgb(42,61,87);
                button.ForeColor=Color.WhiteSmoke;
                button.Padding=new Padding(6,2,6,2);
            }
            top.Controls.Add(start); top.Controls.Add(stop);
            if(matchMode){ top.Controls.Add(spectate); top.Controls.Add(replays); }
            else { top.Controls.Add(mapSelection); }
            ConfigureLabel(status,FontStyle.Bold);
            ConfigureLabel(evidence,FontStyle.Regular);
            status.Text="Ready for an isolated server";
            evidence.Text="No live actor sample";
            var bottom=new Panel {Dock=DockStyle.Bottom,Height=70,Padding=new Padding(11,0,8,0)};
            bottom.Controls.Add(evidence); bottom.Controls.Add(status);
            Controls.Add(plot); Controls.Add(bottom); Controls.Add(top);
            timer.Interval=120;
            timer.Tick+=delegate { UpdateRun(); };
        }

        private static void ConfigureLabel(Label label,FontStyle style)
        {
            label.Dock=DockStyle.Top;
            label.Height=33;
            label.AutoEllipsis=true;
            label.Font=new Font("Segoe UI",10,style);
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            if(!matchMode)
            {
                mapSelection.Items.Add("Saved route");
                mapSelection.SelectedIndex=0;
                try
                {
                    var config=PracticeSettings.Load(root);
                    if(config.MayStartServer)
                    {
                        string maps=Path.Combine(Path.GetDirectoryName(config.server_exe),"cstrike","maps");
                        var files=Directory.GetFiles(maps,"de_*.bsp");
                        Array.Sort(files,StringComparer.OrdinalIgnoreCase);
                        foreach(string file in files)
                        {
                            string name=Path.GetFileNameWithoutExtension(file);
                            if(Regex.IsMatch(name,@"\Ade_[a-z0-9_]{1,29}\z"))mapSelection.Items.Add(name);
                            if(mapSelection.Items.Count>=257)break;
                        }
                    }
                }
                catch(InvalidDataException) {}
                catch(ArgumentException) {}
                catch(IOException) {}
                catch(UnauthorizedAccessException) {}
            }
            if(autoStart)BeginRun();
        }

        internal static string ReadText(string path,int limit)
        {
            using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
            using(var reader=new StreamReader(stream,Encoding.UTF8,true))
            {
                if(stream.Length>limit)throw new InvalidDataException("Practice record exceeds its size limit.");
                var data=new char[limit+1];
                int count=reader.ReadBlock(data,0,data.Length);
                if(count>limit)throw new InvalidDataException("Practice record exceeds its size limit.");
                return new String(data,0,count);
            }
        }

        internal static T Decode<T>(string document,int limit) where T : class
        {
            var json=new JavaScriptSerializer {MaxJsonLength=limit,RecursionLimit=16};
            T value=json.Deserialize<T>(document);
            if(value==null)throw new InvalidDataException("Practice record is missing.");
            return value;
        }

        private void BeginRun()
        {
            if(waiting || controller!=null)return;
            try
            {
                runStartedUtc=DateTime.UtcNow;
                settings=PracticeSettings.Load(root);
                autoRoute=!matchMode && mapSelection.SelectedIndex>0;
                route=autoRoute
                    ? new PracticeRoute {map=(string)mapSelection.SelectedItem,site="automatic"}
                    : PracticeRoute.Load(settings.route);
                if(autoRoute && !settings.MayStartServer)
                    throw new InvalidOperationException("Automatic maps require the owned local practice server.");
                if(matchMode && (route.map!="de_reflex_lab" || !settings.MayStartServer || settings.port>=65535))
                    throw new InvalidOperationException("An owned local lab is required for a match.");
                recordStem=null;
                consoleLog=null;
                spectatorPort=settings.port+1;
                plot.SetRoute(autoRoute?null:route);
                mapSelection.Enabled=false;
                readyTick=null;
                cancellation=false;
                startAttempted=false;
                waiting=true;
                start.Enabled=false;
                stop.Enabled=true;
                status.Text="Waiting for isolated server";
                evidence.Text=route.map+" | Site "+route.site;
                phaseClock.Restart();
                timer.Start();
            }
            catch(Exception)
            {
                Finish("Practice configuration unavailable","Review data/settings/cs16-practice.json and the referenced local files.");
            }
        }

        private void UpdateRun()
        {
            try
            {
                if ((waiting || (controller != null && !cancellation)) &&
                    File.GetLastWriteTimeUtc(Path.Combine(root,"data","bridge","global-stop.signal")) >= runStartedUtc)
                {
                    RequestStop();
                    return;
                }
                if(waiting){ EnsureLiveServer(); return; }
                if(controller==null)return;
                if(controller.HasExited){ ControllerFinished(); return; }
                if(cancellation)return;
                var state=ReadState();
                if(state==null || state.Sequence<=startSequence || !state.Alive || state.Actor==0)
                {
                    plot.SetActor(null);
                    status.Text="Waiting for a fresh live spawn";
                    return;
                }
                plot.SetActor(state);
                status.Text=state.Won && matchMode?"Round win observed; checking server log":
                    state.Planted?(matchMode?"Plant confirmed; facing the defender":"Plant event observed; verifying result"):
                    state.InZone?(state.Equipped?"C4 equipped in plant volume":"Entering plant volume"):
                    state.C4?"Navigating from spawn":"Preparing C4 carrier";
                evidence.Text=String.Format(CultureInfo.InvariantCulture,"X {0:0.0}  Y {1:0.0}  |  Server sequence {2}  |  {3} s",
                    state.X,state.Y,state.Sequence,phaseClock.Elapsed.TotalSeconds.ToString("0.0",CultureInfo.InvariantCulture));
            }
            catch(Exception)
            {
                if(controller!=null) RequestStop();
                else Finish("Practice server unavailable","Check the configured isolated server, port, route and mailbox.");
            }
        }

        private void EnsureLiveServer()
        {
            if(phaseClock.Elapsed.TotalSeconds>25)
            {
                Finish("Isolated server did not become ready","The loopback server must publish fresh state for the selected route.");
                return;
            }
            if(ownedServer!=null && ownedServer.HasExited){ownedServer.Dispose();ownedServer=null;}
            int owner=PracticeEndpoint.Owner(settings.port);
            if(owner==0)
            {
                if(!startAttempted && ownedServer==null && settings.MayStartServer)
                {
                    startAttempted=true;
                    StartServer();
                }
                return;
            }
            using(var process=Process.GetProcessById(owner))
            {
                if(!process.MainModule.FileName.Equals(settings.server_exe,StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Listener is not the configured practice server.");
            }
            if(matchMode && (ownedServer==null || owner!=ownedServer.Id))
                throw new InvalidOperationException("Match requires a server owned by this panel.");
            var state=ReadState();
            if(state==null || state.Status=="unavailable")return;
            if(!readyTick.HasValue || state.Tick<=readyTick.Value)
            {
                readyTick=state.Tick;
                return;
            }
            if(matchMode && !EnsureRecorder()) return;
            StartController(state);
        }

        private static ProcessStartInfo ProcessInfo(string path,string arguments,string cwd)
        {
            return new ProcessStartInfo(path,arguments) {WorkingDirectory=cwd,UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden};
        }

        private void StartServer()
        {
            string directory=Path.GetDirectoryName(settings.server_exe);
            string cstrike=Path.Combine(directory,"cstrike");
            if(!File.Exists(Path.Combine(cstrike,"rc-practice.cfg")) ||
               !File.Exists(Path.Combine(cstrike,"maps",route.map+".bsp")) ||
               !File.Exists(Path.Combine(cstrike,"addons","metamod","dlls","metamod.dll")))
                throw new InvalidOperationException("The isolated server fixture is incomplete.");
            if(matchMode)
            {
                consoleLog=Path.Combine(directory,"qconsole.log");
                consoleOffset=File.Exists(consoleLog)?new FileInfo(consoleLog).Length:0;
            }
            string args="-console -game cstrike -nomaster -insecure -condebug -dll addons/metamod/dlls/metamod.dll "+
                "+ip 127.0.0.1 +sv_lan 1 +maxplayers 4 +log on +servercfgfile rc-practice.cfg -port "+
                settings.port.ToString(CultureInfo.InvariantCulture)+" +map "+route.map;
            var psi=ProcessInfo(settings.server_exe,args,directory);
            psi.EnvironmentVariables["SteamAppId"]="10";
            psi.EnvironmentVariables["SteamGameId"]="10";
            ownedServer=Process.Start(psi);
            if(ownedServer==null)throw new InvalidOperationException("Could not start the isolated server.");
        }

        private bool EnsureRecorder()
        {
            string directory=Path.GetDirectoryName(settings.server_exe);
            if(recorder==null)
            {
                if(PracticeEndpoint.Owner(spectatorPort)!=0)
                    throw new InvalidOperationException("The local spectator port is already in use.");
                string exe=Path.Combine(directory,"hltv.exe");
                if(!File.Exists(exe))throw new InvalidOperationException("Local HLTV recorder is unavailable.");
                recordStem="match-"+Guid.NewGuid().ToString("N").Substring(0,10);
                string filename=recordStem+"-stop.cfg";
                recorderControl=new[] {Path.Combine(directory,filename),Path.Combine(directory,"cstrike",filename)};
                foreach(string path in recorderControl)
                    using(var empty=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.Read)) {}
                string args="-ip 127.0.0.1 -nomaster -noipx -condebug -port "+
                    spectatorPort.ToString(CultureInfo.InvariantCulture)+
                    " +delay 0 +name ReflexCoreRecorder +connect 127.0.0.1:"+
                    settings.port.ToString(CultureInfo.InvariantCulture)+" +record "+recordStem+
                    " +loopcmd 2 1 exec "+filename;
                var launch=ProcessInfo(exe,args,directory);
                // HLTV reads its startup command line from a console context.
                launch.CreateNoWindow=false;
                launch.EnvironmentVariables["SteamAppId"]="10";
                launch.EnvironmentVariables["SteamGameId"]="10";
                recorder=Process.Start(launch);
                recorderClock.Restart();
                if(recorder==null)throw new InvalidOperationException("Could not start the local HLTV recorder.");
                status.Text="Waiting for local spectator recording";
                return false;
            }
            if(recorder.HasExited)throw new InvalidOperationException("HLTV recorder exited before the start.");
            int owner=PracticeEndpoint.Owner(spectatorPort);
            if(owner!=0 && owner!=recorder.Id)throw new InvalidOperationException("HLTV endpoint was replaced.");
            bool ready=owner==recorder.Id && (FindRecording()!=null || recorderClock.ElapsedMilliseconds>=3200);
            spectate.Enabled=ready;
            return ready;
        }

        private string FindRecording()
        {
            if(recordStem==null)return null;
            string cstrike=Path.Combine(Path.GetDirectoryName(settings.server_exe),"cstrike");
            string[] demos=Directory.GetFiles(cstrike,recordStem+"-*-"+route.map+".dem");
            return demos.Length==1?demos[0]:null;
        }

        private bool VerifyMatchLog(PracticeReport result)
        {
            string capture=Path.Combine(Path.GetTempPath(),recordStem+".log");
            try
            {
                using(var log=new FileStream(consoleLog,FileMode.Open,FileAccess.Read,FileShare.ReadWrite))
                {
                    long fresh=log.Length-consoleOffset;
                    if(fresh<=0 || fresh>512*1024)return false;
                    log.Position=consoleOffset;
                    byte[] bytes=new byte[(int)fresh];
                    int received=0;
                    while(received<bytes.Length)
                    {
                        int count=log.Read(bytes,received,bytes.Length-received);
                        if(count==0)return false;
                        received+=count;
                    }
                    File.WriteAllBytes(capture,bytes);
                }
                string options="cs16 benchmark "+Quote(capture)+" --player "+
                    result.engine_subject_id.ToString(CultureInfo.InvariantCulture)+" --require-plant-kill-win";
                var psi=ProcessInfo(settings.runner_exe,options,root);
                psi.RedirectStandardOutput=true;
                using(var benchmark=Process.Start(psi))
                {
                    var output=benchmark.StandardOutput.ReadToEndAsync();
                    if(!benchmark.WaitForExit(3500)){benchmark.Kill();return false;}
                    if(benchmark.ExitCode!=0 || !output.Wait(500))return false;
                    var evidence=Decode<MatchBenchmark>(output.Result,512*1024);
                    if(evidence.schema!="reflexcore.cs16.benchmark.v1" || evidence.verified_plant_bot_round_wins!=1)return false;
                    Directory.CreateDirectory(replayFolder);
                    File.WriteAllText(Path.Combine(replayFolder,recordStem+".json"),output.Result);
                    return true;
                }
            }
            catch(IOException){return false;}
            catch(ArgumentException){return false;}
            catch(InvalidOperationException){return false;}
            finally{if(File.Exists(capture))File.Delete(capture);}
        }

        private void RequestRecorderExit()
        {
            if(recorder==null || recorder.HasExited)return;
            foreach(string path in recorderControl)
            {
                string temporary=path+".next";
                try
                {
                    using(var stream=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None))
                    using(var writer=new StreamWriter(stream,Encoding.ASCII))
                        writer.Write("stoprecording\nquit\n");
                    File.Replace(temporary,path,null);
                }
                catch(IOException) {}
                finally{if(File.Exists(temporary))File.Delete(temporary);}
            }
        }

        private bool SaveRecording()
        {
            RequestRecorderExit();
            var timeout=Stopwatch.StartNew();
            do
            {
                string source=FindRecording();
                if(source!=null)
                {
                    try
                    {
                        if(HasClosedDemo(source))
                        {
                            Directory.CreateDirectory(replayFolder);
                            File.Copy(source,Path.Combine(replayFolder,Path.GetFileName(source)),false);
                            return true;
                        }
                    }
                    catch(IOException) {}
                }
                Thread.Sleep(75);
            }while(timeout.ElapsedMilliseconds<2400);
            return false;
        }

        private static bool HasClosedDemo(string path)
        {
            using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite))
            using(var reader=new BinaryReader(stream))
            {
                if(stream.Length<544 || stream.Length>32*1024*1024)return false;
                if(Encoding.ASCII.GetString(reader.ReadBytes(8))!="HLDEMO\0\0")return false;
                stream.Position=540;
                int directory=reader.ReadInt32();
                return directory>=544 && directory<stream.Length;
            }
        }

        private PracticeState ReadState()
        {
            string path=Path.Combine(settings.mailbox,"state.txt");
            try
            {
                if(!File.Exists(path) || Math.Abs((DateTime.UtcNow-File.GetLastWriteTimeUtc(path)).TotalSeconds)>3)return null;
                var state=PracticeState.Parse(ReadText(path,512));
                return state.Map==route.map?state:null;
            }
            catch(IOException) { return null; }
            catch(InvalidDataException) { return null; }
        }

        private static string Quote(string path) { return "\""+path+"\""; }

        private void StartController(PracticeState initial)
        {
            cancelFile=Path.Combine(Path.GetTempPath(),"rc-practice-"+Guid.NewGuid().ToString("N")+".cancel");
            string arguments="cs16 practice "+Quote(settings.mailbox)+" "+(autoRoute?"auto":Quote(settings.route))+" --allow-offline --cancel-file "+Quote(cancelFile);
            if(matchMode)arguments+=" --match";
            else if(settings.stationary_opponent)arguments+=" --stationary-opponent";
            var psi=ProcessInfo(settings.runner_exe,arguments,root);
            psi.RedirectStandardOutput=true;
            psi.RedirectStandardError=true;
            lock(stdout){stdout.Clear(); outputOverflow=false;}
            var worker=new Process {StartInfo=psi};
            worker.OutputDataReceived+=delegate(object sender,DataReceivedEventArgs e)
            {
                if(e.Data==null)return;
                lock(stdout)
                {
                    outputOverflow=outputOverflow || stdout.Length+e.Data.Length+2>4096;
                    if(!outputOverflow)stdout.AppendLine(e.Data);
                }
            };
            worker.ErrorDataReceived+=delegate { }; // Drain private error details without rendering paths.
            try
            {
                if(!worker.Start())throw new InvalidOperationException("Could not start the practice controller.");
            }
            catch
            {
                worker.Dispose();
                throw;
            }
            controller=worker;
            startSequence=initial.Sequence;
            waiting=false;
            phaseClock.Restart();
            status.Text="Waiting for a fresh live spawn";
            worker.BeginOutputReadLine(); worker.BeginErrorReadLine();
        }

        private void ControllerFinished()
        {
            controller.WaitForExit();
            int code=controller.ExitCode;
            controller.Dispose();
            controller=null;
            if(cancelFile!=null && File.Exists(cancelFile))File.Delete(cancelFile);
            cancelFile=null;
            PracticeReport report=null;
            try
            {
                lock(stdout)if(!outputOverflow)report=Decode<PracticeReport>(stdout.ToString(),4096);
            }
            catch(ArgumentException) {}
            catch(InvalidOperationException) {}
            var latest=ReadState();
            bool verified=code==0 && report!=null && report.schema=="reflexcore.cs16.practice.result.v1" &&
                report.map==route.map && report.verified_plant && report.outcome=="verified" && report.engine_subject_id!=0 &&
                report.total_ms>=0 && report.total_ms<=130000 && report.navigation_ms>=0 && report.navigation_ms<=report.total_ms &&
                report.plant_ms>=0 && report.plant_ms<=report.total_ms;
            if(matchMode && verified)
            {
                bool win=report.match_mode && report.verified_bot_defeat && report.verified_round_win && VerifyMatchLog(report);
                bool replay=win && SaveRecording();
                Finish(win?"Plant, bot defeat and round win verified":"Match result not independently verified",
                    win?(replay?"HLTV replay saved. Open Recordings to view the demo.":"Engine log verified the win; HLTV did not finalize a replay."):
                    "The fresh game log must confirm all three events in the same round.");
                return;
            }
            if(verified && latest!=null && latest.Actor==report.engine_subject_id && latest.Alive)plot.SetActor(latest);
            if(verified)
                Finish("Plant verified by the game engine",String.Format(CultureInfo.InvariantCulture,
                    "{0} | Site {1} | {2:0.0}s total | {3:0.0}s navigation | {4:0.0}s planting",
                    report.map,route.site,report.total_ms/1000.0,report.navigation_ms/1000.0,report.plant_ms/1000.0));
            else if(cancellation)Finish("Practice stopped","The controller released the attempt.");
            else if(matchMode)Finish("Match not verified","The controller did not confirm the plant, bot defeat and round outcome.");
            else if(report!=null && report.outcome=="route_planning_failed")
                Finish("No standing route found","Try another map. Automatic mode needs Python 3 and a walkable brush bombsite.");
            else Finish("Plant not verified","The controller completed without confirmed planting evidence.");
        }

        private void RequestStop()
        {
            if(waiting){Finish("Practice stopped","No controller was started.");return;}
            if(controller==null || cancellation)return;
            try
            {
                using(var signal=new FileStream(cancelFile,FileMode.CreateNew,FileAccess.Write,FileShare.Read)) {}
                cancellation=true;
                stop.Enabled=false;
                status.Text="Stopping practice";
            }
            catch(IOException){status.Text="Could not send the stop signal";}
        }

        private void Finish(string message,string detail)
        {
            waiting=false;
            timer.Stop();
            EndRecorder();
            EndOwnedServer();
            spectate.Enabled=false;
            status.Text=message;
            evidence.Text=detail;
            start.Enabled=true;
            mapSelection.Enabled=true;
            stop.Enabled=false;
            if(closeAfter)BeginInvoke(new Action(Close));
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if(controller!=null)
            {
                e.Cancel=true;
                closeAfter=true;
                RequestStop();
            }
            base.OnFormClosing(e);
            if(!e.Cancel)
            {
                timer.Dispose();
                EndRecorder();
                EndOwnedServer();
            }
        }

        private void EndRecorder()
        {
            try
            {
                if(recorder!=null && !recorder.HasExited)
                {
                    RequestRecorderExit();
                    if(!recorder.WaitForExit(1300))recorder.Kill();
                }
            }
            catch(InvalidOperationException) {}
            catch(System.ComponentModel.Win32Exception) {}
            finally
            {
                if(recorder!=null)recorder.Dispose();
                recorder=null;
                foreach(string path in recorderControl)
                    try { File.Delete(path); } catch(IOException) {} catch(UnauthorizedAccessException) {}
                recorderControl=new string[0];
            }
        }

        private void EndOwnedServer()
        {
            if(ownedServer==null)return;
            try
            {
                if(!ownedServer.HasExited && !File.Exists(Path.Combine(settings.mailbox,"controller.lock")))
                {
                    ownedServer.Kill();
                    ownedServer.WaitForExit(300);
                }
            }
            catch(InvalidOperationException) {}
            catch(System.ComponentModel.Win32Exception) {}
            finally {ownedServer.Dispose(); ownedServer=null;}
        }

        public static void Run(string root,bool autoStart,bool matchMode)
        {
            bool first;
            using(var one=new Mutex(true,matchMode?@"Local\ReflexCoreCs16Match":@"Local\ReflexCoreCs16Practice",out first))
            {
                if(!first)return;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new PracticePanel(root,autoStart,matchMode));
            }
        }

        public static void SelfTest()
        {
            var ready=PracticeState.Parse("reflexcore_cs16_practice_v1 de_reflex_lab 54 12.5 12 1 1 -12.25 80.0 36 180 1 1 1 0 0 0 equipped\n");
            if(ready.Sequence!=54 || ready.X!=-12.25 || ready.Y!=80 || ready.Planted || !ready.InZone)
                throw new Exception("Practice observation parser regression.");
            try { PracticeState.Parse("unverified\n"); throw new Exception("Invalid observation accepted."); }
            catch(InvalidDataException) {}
            var report=Decode<PracticeReport>("{\"schema\":\"reflexcore.cs16.practice.result.v1\",\"verified_plant\":true}",4096);
            if(!report.verified_plant)throw new Exception("Practice result parser regression.");
            string project=Path.Combine(Path.GetTempPath(),"ReflexCore-PracticeStop-"+Guid.NewGuid().ToString("N"));
            string signal=Path.Combine(project,"data","bridge","global-stop.signal");
            Directory.CreateDirectory(Path.GetDirectoryName(signal));
            try {
                using(var panel=new PracticePanel(project,false,false)){
                    panel.waiting=true;
                    panel.runStartedUtc=DateTime.UtcNow.AddSeconds(-1);
                    File.WriteAllText(signal,"test");
                    panel.UpdateRun();
                    if(panel.waiting || !panel.start.Enabled || panel.status.Text!="Practice stopped")
                        throw new InvalidOperationException("Emergency signal did not abort before spawning the controller.");
                    panel.timer.Dispose();
                }
            } finally {
                File.Delete(signal);
                Directory.Delete(Path.GetDirectoryName(signal));
                Directory.Delete(Path.Combine(project,"data"));
                Directory.Delete(project);
            }
            Console.WriteLine("[ReflexCore] CS 1.6 practice parser and emergency stop before server launch passed.");
        }
    }
}
