using System;
using System.IO;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using System.Threading;
using System.Text.RegularExpressions;
using System.Globalization;
using System.Collections.Generic;
using System.Management;

namespace ReflexCore.Bridge
{
    public static class TrayHost
    {
        public static void SelfTest(string root)
        {
            if(CompanionStateMachine.Resolve("Vision thinking")!=CompanionMood.Thinking ||
               CompanionStateMachine.Resolve("Step verified")!=CompanionMood.Success ||
               CompanionStateMachine.Resolve("Error")!=CompanionMood.Warning)
                throw new InvalidOperationException("Companion state mapping failed.");
            WindowSurfaces.SelfTest();
            if (!File.Exists(Path.Combine(root, "Cargo.toml")))
                throw new Exception("Cargo.toml missing");
            if (!File.Exists(Path.Combine(root, "tools", "ReflexCore-Tray.cs")))
                throw new Exception("Tray source missing");
            if (!Directory.Exists(Path.Combine(root, "tasks")))
                throw new Exception("Tasks directory missing");
            if (TrayWindow.Value("{\"schema\":\"reflexcore.activity.v1\"}", "schema") != "reflexcore.activity.v1")
                throw new Exception("Tray activity schema parser regression");
            if (TrayWindow.Value("{\"source\":\"shared_control\"}", "source") != "shared_control")
                throw new Exception("Tray activity source parser regression");
            if (TrayWindow.Value("{\"source\":\"vision_loop\"}", "source") != "vision_loop")
                throw new Exception("Tray VisionLoop source parser regression");
            if(TrayWindow.TokensPerSecond("{\"last_tps\":31.2}")!=31.2) throw new Exception("Tray throughput parse regression");
            if(TrayWindow.TokensPerSecond("{\"last_tps\":100000}")!=0) throw new Exception("Tray throughput bounds regression");
            if(TrayWindow.TokensPerSecond("{\"last_tps\":1000}")!=1000 ||
               TrayWindow.TokensPerSecond("{\"last_tps\":10e2}")!=0)
                throw new Exception("Tray throughput numeric regression");
            DateTime at=new DateTime(2026,1,1,0,0,3,DateTimeKind.Utc);
            if(!TrayWindow.ActivityVisible("citadel_rust",at,at.AddSeconds(5)) ||
               TrayWindow.ActivityVisible("citadel_rust",at,at.AddSeconds(7)) ||
               !TrayWindow.ActivityVisible("vision_loop",at,at.AddSeconds(7)))
                throw new Exception("Activity display expiry regression");
            bool precise;
            DateTime legacy=TrayWindow.ModelSampleTime("{}",at,out precise);
            if(legacy!=at || precise || !ActivityHud.ThroughputText(31.2,legacy,at,false).Contains("activity 0s ago"))
                throw new Exception("Legacy throughput timestamp regression");
            DateTime measured=TrayWindow.ModelSampleTime("{\"last_tps_utc\":\"2026-01-01T00:00:01Z\"}",at,out precise);
            if(!precise || measured!=at.AddSeconds(-2) ||
               !ActivityHud.ThroughputText(31.2,measured,at,true).Contains("last reply 2s ago"))
                throw new Exception("Precise throughput timestamp regression");
            if(!ActivityHud.ThroughputText(31.2,at.AddSeconds(-66),at,true).Contains("no recent sample") ||
               !ActivityHud.ThroughputText(31.2,at.AddSeconds(11),at,true).Contains("no recent sample"))
                throw new Exception("Throughput age bounds regression");
            if(!TrayWindow.CaptureSignalActive(at.AddSeconds(-1),at) ||
               TrayWindow.CaptureSignalActive(at.AddSeconds(-16),at) ||
               TrayWindow.CaptureSignalActive(at.AddSeconds(1),at))
                throw new Exception("HUD capture marker age bounds regression");
            Console.WriteLine("[ReflexCore] Tray/HUD C# compiled and self-test passed.");
        }

        [STAThread]
        public static void Run(string root)
        {
            bool restart=false;
            bool created;
            using (Mutex mutex = new Mutex(true, @"Local\ReflexCoreAgentTray", out created))
            {
                if (!created) return;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                using(var tray=new TrayWindow(root))
                {
                    Application.Run(tray);
                    restart=tray.RestartRequested;
                }
            }
            if(restart)
            {
                string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe");
                string entry=Path.Combine(root,"tools","Start-ReflexCore.ps1");
                using(var launch=Process.Start(new ProcessStartInfo{
                    FileName=ps,Arguments="-NoProfile -ExecutionPolicy Bypass -File \""+entry+"\"",
                    WorkingDirectory=root,UseShellExecute=false,CreateNoWindow=true})){}
            }
        }
    }

    internal sealed class SilentToast : Form
    {
        private Label label;
        private System.Windows.Forms.Timer hideTimer;

        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000 | 0x00000080; // NOACTIVATE, TOOLWINDOW
                return cp;
            }
        }

        public SilentToast()
        {
            Width = 320;
            Height = 77;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = true;
            BackColor = Color.FromArgb(20, 25, 20);
            label = new Label();
            label.Dock = DockStyle.Fill;
            label.TextAlign = ContentAlignment.MiddleCenter;
            label.ForeColor = Color.LimeGreen;
            label.BackColor = BackColor;
            label.Font = new Font("Segoe UI", 10, FontStyle.Bold);
            Controls.Add(label);
            hideTimer = new System.Windows.Forms.Timer();
            hideTimer.Interval = 3700;
            hideTimer.Tick += delegate(object sender, EventArgs e) { hideTimer.Stop(); Hide(); };
        }

        public void Display(string message)
        {
            label.Text = "ReflexCore\n" + message;
            Rectangle area = Screen.PrimaryScreen.WorkingArea;
            Location = new Point(area.Right - Width - 14, area.Bottom - Height - 14);
            Show();
            hideTimer.Stop();
            hideTimer.Start();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (hideTimer != null) hideTimer.Dispose();
            }
            base.Dispose(disposing);
        }
    }

    // Host counters use the same Windows APIs as the diagnostics panel and zxcLagLab.
    // NVIDIA sampling loads only the library supplied by the installed driver.
    public sealed class ResourceCounters : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct MemoryStatus
        {
            public uint Length, Load;
            public ulong Total, Available, PageTotal, PageFree, VirtualTotal, VirtualFree, ExtendedFree;
        }

        public sealed class MemoryReading
        {
            public ulong UsedBytes { get; internal set; }
            public ulong TotalBytes { get; internal set; }
        }

        public sealed class GpuReading
        {
            public string Name { get; internal set; }
            public uint? UtilizationPercent { get; internal set; }
            public ulong? UsedBytes { get; internal set; }
            public ulong? TotalBytes { get; internal set; }
            public ulong? SharedBytes { get; internal set; }
        }

        [DllImport("kernel32.dll")]
        private static extern bool GetSystemTimes(out ulong idle, out ulong kernel, out ulong user);
        [DllImport("kernel32.dll")]
        private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
        [DllImport("kernel32.dll")]
        private static extern ushort GetActiveProcessorGroupCount();

        private ulong previousIdle, previousTotal;
        private NvmlReader gpu;
        private WindowsGpuReader adapters;
        public bool CpuIsProcessorGroup { get; private set; }

        public ResourceCounters()
        {
            CpuIsProcessorGroup = GetActiveProcessorGroupCount() > 1;
        }

        public double? ReadCpuPercent()
        {
            ulong idle, kernel, user;
            if (!GetSystemTimes(out idle, out kernel, out user)) return null;
            ulong total = kernel + user;
            double? cpu = null;
            if (previousTotal != 0 && total > previousTotal && idle >= previousIdle)
            {
                double busy = 1.0 - (double)(idle - previousIdle) / (total - previousTotal);
                cpu = 100 * Math.Min(1, Math.Max(0, busy));
            }
            previousIdle = idle;
            previousTotal = total;
            return cpu;
        }

        public MemoryReading ReadMemory()
        {
            var status = new MemoryStatus { Length = (uint)Marshal.SizeOf(typeof(MemoryStatus)) };
            if (!GlobalMemoryStatusEx(ref status) || status.Total == 0 || status.Available > status.Total) return null;
            return new MemoryReading { UsedBytes = status.Total - status.Available, TotalBytes = status.Total };
        }

        // Call ReadGpu and Dispose serially on a worker thread. GPU values refer to adapter 0.
        public GpuReading ReadGpu()
        {
            if (gpu == null) gpu = new NvmlReader();
            return gpu.Read();
        }

        public GpuReading[] ReadAdapters()
        {
            if (adapters == null) adapters = new WindowsGpuReader();
            var readings = adapters.Read();
            if (readings.Length != 0) return readings;
            var fallback = ReadGpu();
            if (fallback == null || (!fallback.UtilizationPercent.HasValue && !fallback.TotalBytes.HasValue))
                return readings;
            fallback.Name = "NVIDIA";
            return new[] {fallback};
        }

        private sealed class WindowsGpuReader
        {
            [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
            private struct AdapterDescription
            {
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Name;
                public uint Vendor, Device, Subsystem, Revision;
                public UIntPtr DedicatedVideo, DedicatedSystem, SharedSystem;
                public uint LuidLow, LuidHigh, Flags;
            }
            [DllImport("dxgi.dll")]
            private static extern int CreateDXGIFactory1(ref Guid iid, out IntPtr factory);
            [UnmanagedFunctionPointer(CallingConvention.StdCall)]
            private delegate int EnumAdapter(IntPtr factory, uint index, out IntPtr adapter);
            [UnmanagedFunctionPointer(CallingConvention.StdCall)]
            private delegate int DescribeAdapter(IntPtr adapter, out AdapterDescription description);

            private readonly Dictionary<string,AdapterDescription> devices =
                new Dictionary<string,AdapterDescription>(StringComparer.OrdinalIgnoreCase);
            private static readonly Regex Instance = new Regex(
                @"(luid_0x[0-9a-f]{8}_0x[0-9a-f]{8})_phys_[0-9]+(?:_eng_[0-9]+)?",
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

            private static T Method<T>(IntPtr instance, int slot) where T : class
            {
                IntPtr pointer = Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance),slot * IntPtr.Size);
                return Marshal.GetDelegateForFunctionPointer(pointer,typeof(T)) as T;
            }

            internal WindowsGpuReader()
            {
                var iid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
                IntPtr factory;
                if (CreateDXGIFactory1(ref iid,out factory) < 0) return;
                try
                {
                    var enumerate = Method<EnumAdapter>(factory,12);
                    for (uint index=0; index<32; index++)
                    {
                        IntPtr adapter;
                        if (enumerate(factory,index,out adapter)<0) break;
                        try
                        {
                            AdapterDescription value;
                            if (Method<DescribeAdapter>(adapter,10)(adapter,out value)<0 || (value.Flags&2)!=0) continue;
                            string key=String.Format(CultureInfo.InvariantCulture,"luid_0x{0:X8}_0x{1:X8}",value.LuidHigh,value.LuidLow);
                            devices[key]=value;
                        }
                        finally { Marshal.Release(adapter); }
                    }
                }
                finally { Marshal.Release(factory); }
            }

            internal GpuReading[] Read()
            {
                var result = new Dictionary<string,GpuReading>(StringComparer.OrdinalIgnoreCase);
                foreach (var device in devices)
                {
                    var info=device.Value;
                    string name=info.Name.Replace("GeForce ","").Replace("(TM)","").Replace(" Graphics","").Replace("  "," ").Trim();
                    if (name.Length>23) name=name.Substring(0,23);
                    result.Add(device.Key,new GpuReading {Name=name,TotalBytes=info.DedicatedVideo.ToUInt64()});
                }
                if (result.Count==0) return new GpuReading[0];
                Query("GPUAdapterMemory","Name,DedicatedUsage,SharedUsage",row =>
                {
                    Match match=Instance.Match((string)row["Name"]);
                    GpuReading adapter;
                    if (!match.Success || !result.TryGetValue(match.Groups[1].Value,out adapter)) return;
                    adapter.UsedBytes=(adapter.UsedBytes??0)+Convert.ToUInt64(row["DedicatedUsage"]);
                    adapter.SharedBytes=(adapter.SharedBytes??0)+Convert.ToUInt64(row["SharedUsage"]);
                });
                // The busiest physical engine represents adapter utilization. Processes on
                // the same engine contribute to that engine's utilization, not other engines.
                var engines=new Dictionary<string,ulong>(StringComparer.OrdinalIgnoreCase);
                Query("GPUEngine","Name,UtilizationPercentage",row =>
                {
                    Match match=Instance.Match((string)row["Name"]);
                    if (!match.Success || !result.ContainsKey(match.Groups[1].Value)) return;
                    ulong busy;
                    engines.TryGetValue(match.Value,out busy);
                    engines[match.Value]=Math.Min(100UL,busy+Convert.ToUInt64(row["UtilizationPercentage"]));
                });
                foreach (var engine in engines)
                {
                    var adapter=result[Instance.Match(engine.Key).Groups[1].Value];
                    adapter.UtilizationPercent=Math.Max(adapter.UtilizationPercent??0,(uint)engine.Value);
                }
                var readings=new GpuReading[result.Count];
                result.Values.CopyTo(readings,0);
                Array.Sort(readings,(a,b)=>Nullable.Compare(b.TotalBytes,a.TotalBytes));
                return readings;
            }

            private static void Query(string counter,string columns,Action<ManagementBaseObject> handle)
            {
                try
                {
                    using (var query=new ManagementObjectSearcher("SELECT "+columns+
                        " FROM Win32_PerfFormattedData_GPUPerformanceCounters_"+counter))
                    using (var rows=query.Get())
                    {
                        foreach (ManagementBaseObject row in rows)
                            using (row) { handle(row); }
                    }
                }
                catch (ManagementException) { }
                catch (UnauthorizedAccessException) { }
            }
        }

        public void Dispose()
        {
            if (gpu != null) gpu.Dispose();
        }

        private sealed class NvmlReader : IDisposable
        {
            [StructLayout(LayoutKind.Sequential)]
            private struct Utilization
            {
                public uint Gpu, Memory;
            }
            [StructLayout(LayoutKind.Sequential)]
            private struct Memory
            {
                public ulong Total, Free, Used;
            }
            [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
            private delegate int Simple();
            [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
            private delegate int GetDevice(uint index, out IntPtr device);
            [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
            private delegate int GetUtilization(IntPtr device, out Utilization value);
            [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
            private delegate int GetMemory(IntPtr device, out Memory value);
            [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
            private static extern IntPtr LoadLibraryExW(string path, IntPtr reserved, uint flags);
            [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true)]
            private static extern IntPtr GetProcAddress(IntPtr module, string name);
            [DllImport("kernel32.dll")]
            private static extern bool FreeLibrary(IntPtr module);

            private const uint SearchDllDirectory = 0x100;
            private const uint SearchSystem32 = 0x800;
            private IntPtr module, device;
            private Simple shutdown;
            private GetUtilization utilization;
            private GetMemory memory;
            private bool initialized;

            internal NvmlReader()
            {
                try
                {
                    var paths = new[] {
                        Path.Combine(Environment.SystemDirectory, "nvml.dll"),
                        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "NVIDIA Corporation", "NVSMI", "nvml.dll")
                    };
                    foreach (string path in paths)
                    {
                        if (!Path.IsPathRooted(path) || !File.Exists(path)) continue;
                        module = LoadLibraryExW(path, IntPtr.Zero, SearchDllDirectory | SearchSystem32);
                        if (module != IntPtr.Zero) break;
                    }
                    if (module == IntPtr.Zero) return;

                    var init = Export<Simple>("nvmlInit_v2");
                    shutdown = Export<Simple>("nvmlShutdown");
                    var handle = Export<GetDevice>("nvmlDeviceGetHandleByIndex_v2");
                    utilization = Export<GetUtilization>("nvmlDeviceGetUtilizationRates");
                    memory = Export<GetMemory>("nvmlDeviceGetMemoryInfo");
                    if (init == null || shutdown == null || handle == null || (utilization == null && memory == null)) return;
                    initialized = init() == 0;
                    if (initialized && handle(0, out device) != 0) device = IntPtr.Zero;
                }
                finally
                {
                    if (device == IntPtr.Zero) Dispose();
                }
            }

            private T Export<T>(string name) where T : class
            {
                IntPtr address = GetProcAddress(module, name);
                return address == IntPtr.Zero ? null : Marshal.GetDelegateForFunctionPointer(address, typeof(T)) as T;
            }

            internal GpuReading Read()
            {
                var reading = new GpuReading();
                if (device == IntPtr.Zero) return reading;
                Utilization busy;
                if (utilization != null && utilization(device, out busy) == 0 && busy.Gpu <= 100)
                    reading.UtilizationPercent = busy.Gpu;
                Memory ram;
                if (memory != null && memory(device, out ram) == 0 && ram.Total > 0 && ram.Used <= ram.Total)
                {
                    reading.TotalBytes = ram.Total;
                    reading.UsedBytes = ram.Used;
                }
                return reading;
            }

            public void Dispose()
            {
                if (initialized) shutdown();
                if (module != IntPtr.Zero) FreeLibrary(module);
                initialized = false;
                module = IntPtr.Zero;
                device = IntPtr.Zero;
            }
        }
    }

    // Light WinForms overlay owned by the already running tray process.
    // No browser, GPU renderer, network requests, raw prompt or screenshot data.
    internal sealed partial class ActivityHud : Form
    {
        private readonly Label stageLabel, speedLabel, hostLabel, gpuLabel;
        private readonly ResourceCounters resources = new ResourceCounters();
        private readonly object gpuLock = new object();
        private long nextHostSample, nextGpuSample;
        private bool gpuBusy, releasing;
        private bool hostMetric=true,gpuMetric=true,ollamaMetric=true;
        private bool gpuNames=true;
        private volatile TimestampedGpu gpuSample;
        private TimestampedGpu displayedGpuSample;

        private sealed class TimestampedGpu
        {
            public ResourceCounters.GpuReading[] Readings;
            public long Ticks;
        }

        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams
        {
            get { CreateParams cp=base.CreateParams; cp.ExStyle|=0x08000000|0x00000080; if(clickThrough)cp.ExStyle|=0x20; return cp; }
        }
        public ActivityHud()
        {
            FormBorderStyle=FormBorderStyle.None;
            Text="ReflexCore Live Status";
            ClientSize=new Size(368,132); TopMost=true;
            StartPosition=FormStartPosition.Manual; ShowInTaskbar=false;
            BackColor=Color.FromArgb(14,24,27); Opacity=0.94;
            var header=new Label { Text="REFLEXCORE  /  LIVE STATUS", Left=12, Top=7, Width=344, Height=20,
                ForeColor=Color.FromArgb(94,237,150), Font=new Font("Consolas",9,FontStyle.Bold) };
            stageLabel=new Label { Text="Idle", Left=12, Top=29, Width=344, Height=23, AutoEllipsis=true,
                ForeColor=Color.FromArgb(224,241,228), Font=new Font("Segoe UI",10,FontStyle.Regular) };
            hostLabel=Metric("CPU —    RAM —",55);
            gpuLabel=new GpuColumnsLabel { Text="GPU —  |  VRAM —  |  Shared —", Left=12, Top=79,
                Width=344, Height=22, ForeColor=hostLabel.ForeColor, Font=hostLabel.Font };
            speedLabel=Metric("Ollama — tok/s  \u00b7  no recent sample",103);
            Controls.AddRange(new System.Windows.Forms.Control[] {header,stageLabel,hostLabel,gpuLabel,speedLabel});
            Reposition();
        }

        private sealed class GpuColumnsLabel : Label
        {
            protected override void OnPaint(PaintEventArgs e)
            {
                int firstDivider=ClientSize.Width*43/100;
                int secondDivider=ClientSize.Width*73/100;
                int gap=Math.Max(6,Font.Height/2);
                var flags=TextFormatFlags.NoPadding|TextFormatFlags.SingleLine|
                    TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix;
                int y=0;
                foreach(string row in Text.Split(new[]{Environment.NewLine},StringSplitOptions.None))
                {
                    var fields=row.Split(new[]{"  |  "},3,StringSplitOptions.None);
                    if(fields.Length!=3)continue;
                    TextRenderer.DrawText(e.Graphics,fields[0],Font,new Rectangle(0,y,Math.Max(0,firstDivider-gap),Font.Height),ForeColor,flags);
                    TextRenderer.DrawText(e.Graphics,"|",Font,new Point(firstDivider,y),ForeColor,flags);
                    TextRenderer.DrawText(e.Graphics,fields[1],Font,new Rectangle(firstDivider+gap,y,Math.Max(0,secondDivider-firstDivider-2*gap),Font.Height),ForeColor,flags);
                    TextRenderer.DrawText(e.Graphics,"|",Font,new Point(secondDivider,y),ForeColor,flags);
                    TextRenderer.DrawText(e.Graphics,fields[2],Font,new Rectangle(secondDivider+gap,y,Math.Max(0,ClientSize.Width-secondDivider-gap),Font.Height),ForeColor,flags);
                    y+=Font.Height;
                }
            }
        }

        private static Label Metric(string value,int top)
        {
            return new Label { Text=value, Left=12, Top=top, Width=344, Height=22,
                ForeColor=Color.FromArgb(172,218,205), Font=new Font("Segoe UI",9,FontStyle.Regular) };
        }

        public void Reposition()
        {
            if(positioned)
            {
                Rectangle screen=Screen.FromPoint(Location).WorkingArea;
                Location=new Point(Math.Max(screen.Left,Math.Min(Left,screen.Right-Width)),
                    Math.Max(screen.Top,Math.Min(Top,screen.Bottom-Height)));
                return;
            }
            Rectangle a=Screen.PrimaryScreen.WorkingArea;
            Location=new Point(a.Right-Width-12,a.Top+35);
        }
        public void RefreshStatus(string label) { stageLabel.Text=label; }

        public void RefreshThroughput(double tps,DateTime measuredUtc,DateTime now,bool precise)
        {
            speedLabel.Text=ThroughputText(tps,measuredUtc,now,precise);
        }

        internal static string ThroughputText(double tps,DateTime measuredUtc,DateTime now,bool precise)
        {
            double age=(now-measuredUtc).TotalSeconds;
            return tps>0 && age>=-10 && age<=65
                ? String.Format(CultureInfo.InvariantCulture,"Ollama {0:0.0} tok/s  \u00b7  {1} {2:0}s ago",
                    tps,precise?"last reply":"activity",Math.Max(0,Math.Floor(age)))
                : "Ollama — tok/s  \u00b7  no recent sample";
        }

        public void RefreshResources()
        {
            if (!Visible && !feedWhenHidden) return;
            long now=Stopwatch.GetTimestamp();
            if(now>=nextHostSample)
            {
                nextHostSample=now+Stopwatch.Frequency;
                double? cpu=resources.ReadCpuPercent();
                var ram=resources.ReadMemory();
                string cpuText=cpu.HasValue?cpu.Value.ToString("0",CultureInfo.InvariantCulture)+"%":"—";
                string ramText=ram==null?"—":FormatGib(ram.UsedBytes,ram.TotalBytes);
                hostLabel.Text=(resources.CpuIsProcessorGroup?"CPU group ":"CPU ")+cpuText+"    RAM "+ramText;
            }
            if(now>=nextGpuSample)
            {
                nextGpuSample=now+3*Stopwatch.Frequency;
                RequestGpuSample();
            }
            var current=gpuSample;
            if(current!=null && now-current.Ticks>12*Stopwatch.Frequency) current=null;
            if(current==displayedGpuSample) return;
            displayedGpuSample=current;
            RenderGpuSample();
        }

        private void RenderGpuSample()
        {
            var rows=new List<string>();
            if(displayedGpuSample!=null)
                foreach(var gpu in displayedGpuSample.Readings)
                    rows.Add(GpuText(gpu,gpuNames?gpu.Name:"GPU "+(rows.Count+1).ToString(CultureInfo.InvariantCulture)));
            if(rows.Count==0) rows.Add("GPU —  |  VRAM —  |  Shared —");
            gpuLabel.Text=String.Join(Environment.NewLine,rows.ToArray());
            gpuLabel.Height=22+20*(rows.Count-1);
            LayoutClassic();
        }

        private static string GpuText(ResourceCounters.GpuReading gpu,string name)
        {
            string load=gpu.UtilizationPercent.HasValue?gpu.UtilizationPercent.Value.ToString(CultureInfo.InvariantCulture)+"%":"—";
            string vram=gpu.UsedBytes.HasValue && gpu.TotalBytes.HasValue
                ?String.Format(CultureInfo.InvariantCulture,"{0}/{1} MiB",gpu.UsedBytes.Value>>20,gpu.TotalBytes.Value>>20):"—";
            string shared=gpu.SharedBytes.HasValue?(gpu.SharedBytes.Value>>20).ToString(CultureInfo.InvariantCulture)+" MiB":"—";
            return name+" "+load+"  |  VRAM "+vram+"  |  Shared "+shared;
        }

        private static string FormatGib(ulong used,ulong total)
        {
            const double bytesPerGib=1024*1024*1024;
            return String.Format(CultureInfo.InvariantCulture,"{0:0.0}/{1:0.0} GiB",used/bytesPerGib,total/bytesPerGib);
        }

        private void RequestGpuSample()
        {
            lock(gpuLock)
            {
                if(gpuBusy || releasing) return;
                gpuBusy=true;
            }
            ThreadPool.QueueUserWorkItem(delegate(object unused) {
                try
                {
                    var readings=resources.ReadAdapters();
                    gpuSample=new TimestampedGpu {Readings=readings,Ticks=Stopwatch.GetTimestamp()};
                }
                catch
                {
                    gpuSample=null;
                }
                finally
                {
                    bool dispose;
                    lock(gpuLock)
                    {
                        gpuBusy=false;
                        dispose=releasing;
                    }
                    if(dispose) resources.Dispose();
                }
            });
        }

        protected override void Dispose(bool disposing)
        {
            if(disposing)
            {
                bool dispose=false;
                lock(gpuLock)
                {
                    if(!releasing)
                    {
                        releasing=true;
                        dispose=!gpuBusy;
                    }
                }
                if(dispose) ThreadPool.QueueUserWorkItem(delegate(object unused) {resources.Dispose();});
            }
            base.Dispose(disposing);
        }
    }

    internal sealed class TrayWindow : Form
    {
        private const int HotkeyId = 0x5243;
        private const int WmHotkey = 0x0312;
        private readonly string root;
        private readonly string bridge;
        private readonly string pending;
        private readonly string running;
        private readonly string statusPath;
        private readonly string controlPath;
        private readonly NotifyIcon icon;
        private readonly SilentToast toast;
        private readonly ActivityHud hud;
        private readonly ToolStripMenuItem hudMenu;
        private bool hudEnabled=true;
        private readonly CompanionHost companionHost;
        private readonly string captureSignalPath;
        private static readonly TimeSpan CaptureSignalLifetime=TimeSpan.FromSeconds(15);
        private readonly ContextMenuStrip menu;
        private readonly ToolStripMenuItem statusMenu;
        private readonly ToolStripMenuItem activityMenu;
        private readonly string activityPath;
        private string lastActivityStage="";
        private string lastActivitySource="";
        private DateTime lastActivityWriteUtc, activeStageUtc, modelSampleUtc;
        private double modelRate;
        private bool modelSampleTimePrecise;
        private readonly System.Windows.Forms.Timer tick;
        private Process active;
        private string activeJob;
        private readonly QueueStore queue;
        private bool cooperativeOnly;
        private bool cancelled, forceStopStarted, stopTimedOut;
        private DateTime stopDeadline;
        private Process stopHelper;
        private bool hotkeyRegistered, emergencyHotkeyRegistered;
        private bool exiting, exitAfterWorker;
        private DateTime shutdownUntil, lastEmergencyStopUtc;
        private bool shutdownRestart;
        internal bool RestartRequested {get;private set;}
        private string currentState;
        private int lastPending = -1;
        private readonly DateTime sessionStartedUtc;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
        [DllImport("user32.dll")]
        private static extern bool UnregisterHotKey(IntPtr hwnd, int id);

        private readonly bool isolated;
        public TrayWindow(string rootPath,bool isolated=false)
        {
            this.isolated=isolated;
            root = Path.GetFullPath(rootPath);
            bridge = Path.Combine(root, "data", "bridge");
            pending = Path.Combine(bridge, "pending");
            running = Path.Combine(bridge, "running");
            statusPath = Path.Combine(bridge, "status.json");
            controlPath = Path.Combine(bridge, "control.txt");
            Directory.CreateDirectory(pending);
            Directory.CreateDirectory(running);
            queue=new QueueStore(root);queue.Recover();
            sessionStartedUtc = DateTime.UtcNow;
            activityPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ReflexCore", "runtime", "activity.json");
            currentState = "ready";
            captureSignalPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ReflexCore","runtime","hud-capture.signal");

            ShowInTaskbar = false;
            WindowState = FormWindowState.Minimized;
            FormBorderStyle = FormBorderStyle.FixedToolWindow;
            Text = "ReflexCore Bridge";

            toast = new SilentToast();
            hud = new ActivityHud();
            var menuRenderer=ReflexCore.Presentation.DarkMenuRenderer.ForTray();
            menu = new ContextMenuStrip{Renderer=menuRenderer};
            statusMenu = new ToolStripMenuItem("Status: ready");
            statusMenu.Enabled = false;
            activityMenu = new ToolStripMenuItem("Activity: idle");
            activityMenu.Enabled = false;
            hudMenu=new ToolStripMenuItem("Hide Classic widget");
            hudMenu.Click += delegate { ToggleHud(); };
            menu.Items.Add(hudMenu);
            menu.Items.Add("Open Studio", null, delegate(object s, EventArgs e) {
                string center = Path.Combine(root, "tools", "ReflexCore-ControlCenter.ps1");
                string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
                Process.Start(new ProcessStartInfo { FileName=ps, Arguments="-NoProfile -ExecutionPolicy Bypass -File \"" + center + "\"",WorkingDirectory=root,UseShellExecute=false,CreateNoWindow=true });
            });
            if(!isolated)
            {
                hud.ConfigureClassicWidget();
                companionHost=new CompanionHost(root,bridge,hud);
                var companionMenu=new ToolStripMenuItem("Show ReflexCompanion 3D");
                companionMenu.Click+=delegate {
                    if(companionHost.CompanionRequested)companionHost.Hide3D();
                    else companionHost.Show3D();
                };
                menu.Opening+=delegate {
                    companionMenu.Text=companionHost.CompanionRequested?"Hide ReflexCompanion 3D":"Show ReflexCompanion 3D";
                };
                menu.Items.Insert(1,companionMenu);
                var classicMenu=new ContextMenuStrip{Renderer=menuRenderer};
                var gpuNamesOption=new ToolStripMenuItem("Show graphics card names");
                gpuNamesOption.Click+=delegate{companionHost.SetClassicGpuNames(!hud.ClassicGpuNames);};
                var clickOption=new ToolStripMenuItem("Click through");
                clickOption.Click+=delegate{companionHost.SetClassicClickThrough(!hud.ClassicClickThrough);};
                classicMenu.Items.AddRange(new ToolStripItem[]{gpuNamesOption,clickOption,new ToolStripSeparator(),
                    new ToolStripMenuItem("Hide Classic widget",null,(s,e)=>SetHudVisible(false))});
                classicMenu.Opening+=delegate{
                    gpuNamesOption.Checked=hud.ClassicGpuNames;
                    clickOption.Checked=hud.ClassicClickThrough;
                };
                hud.ContextMenuStrip=classicMenu;
                hud.Disposed+=delegate{classicMenu.Dispose();};
                var widgetOptions=new ToolStripMenuItem("Widget");
                widgetOptions.DropDown.Renderer=menuRenderer;
                widgetOptions.DropDownOpening+=delegate {
                    while(widgetOptions.DropDownItems.Count>0)widgetOptions.DropDownItems[0].Dispose();
                    var entries=widgetOptions.DropDownItems;
                    if(companionHost.Running)
                    {
                        entries.Add("Restart 3D",null,(s,e)=>companionHost.Restart3D());
                    }
                    var input=new ToolStripMenuItem("3D mouse interaction"){Checked=companionHost.MouseInteractionEnabled()};
                    input.Click+=(s,e)=>{
                        try
                        {
                            bool enabled=companionHost.ToggleMouseInteraction();
                            toast.Display(enabled?"3D mouse interaction enabled":"3D mouse interaction disabled");
                        }
                        catch(IOException){toast.Display("Could not save the 3D mouse setting");}
                        catch(UnauthorizedAccessException){toast.Display("Could not save the 3D mouse setting");}
                    };
                    entries.Add(input);
                    var classic=new ToolStripMenuItem("Classic options");
                    classic.DropDown.Renderer=menuRenderer;
                    hud.AddClassicActions(classic.DropDownItems,companionHost.SetClassicClickThrough);
                    entries.Add(classic);
                };
                widgetOptions.DropDownItems.Add("Settings");
                menu.Items.Add(widgetOptions);
            }
            menu.Items.Add("Stop task · Ctrl+Alt+P", null, delegate(object s, EventArgs e) { StopJob(); });
            var toolsMenu=new ToolStripMenuItem("More");
            toolsMenu.DropDown.Renderer=menuRenderer;
            toolsMenu.DropDownItems.Add("Run next pending job", null, delegate(object s, EventArgs e) { StartPending(true); });
            toolsMenu.DropDownItems.Add("Stop all · Reflex + Ollama", null, delegate(object s, EventArgs e) {
                // Immediate local signal for Shared Control, then async unload local Ollama models.
                try{
                    File.WriteAllText(Path.Combine(bridge,"global-stop.signal"),TimeUtc());
                    StopAllJobs();
                    string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe");
                    string manager=Path.Combine(root,"tools","ReflexCore-Models.ps1");
                    Process.Start(new ProcessStartInfo{FileName=ps,Arguments="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \""+manager+"\" -Action StopAll",
                        WorkingDirectory=root,UseShellExecute=false,CreateNoWindow=true});
                }catch{SetState("error",-1,"Stop-all failed; review supervised tasks");}
            });
            toolsMenu.DropDownItems.Add("Open ReflexCore folder", null, delegate(object s, EventArgs e) {
                Process.Start("explorer.exe", root);
            });
            toolsMenu.DropDownItems.Add("Emergency stop · Ctrl+Alt+F10", null, delegate { EmergencyStopAgents(); });
            menu.Items.Add(toolsMenu);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Restart",null,(s,e)=>RequestShutdown(true));
            menu.Items.Add("Exit",null,(s,e)=>RequestShutdown(false));

            icon = new NotifyIcon();
            icon.ContextMenuStrip = menu;
            icon.Icon = SystemIcons.Information;
            icon.Text = "ReflexCore | ready";
            icon.Visible = !isolated;
            string dragonIcon = Path.Combine(root,"assets","reflexcore.ico");
            if(File.Exists(dragonIcon)) { try { icon.Icon = new Icon(dragonIcon); } catch(Exception) {} }
            icon.MouseDoubleClick += delegate(object s, MouseEventArgs e) {
                string center = Path.Combine(root, "tools", "ReflexCore-ControlCenter.ps1");
                string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
                Process.Start(new ProcessStartInfo {
                    FileName = ps,
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + center + "\"",
                    WorkingDirectory = root,
                    UseShellExecute = false,
                    CreateNoWindow = true
                });
            };
icon.MouseClick += delegate(object s, MouseEventArgs e) {
                if (e.Button != MouseButtons.Left) return;
                string center = Path.Combine(root, "tools", "ReflexCore-ControlCenter.ps1");
                string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
                Process.Start(new ProcessStartInfo {
                    FileName = ps,
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + center + "\"",
                    WorkingDirectory = root,
                    UseShellExecute = false,
                    CreateNoWindow = true
                });
            };

            // Force creation of a Win32 handle to receive WM_HOTKEY while hidden.
            IntPtr hwnd = Handle;
            hotkeyRegistered = !isolated && RegisterHotKey(hwnd, HotkeyId, 0x4003u, 0x50u); // ALT+CTRL+NOREPEAT, P
            if(!isolated)RegisterHotKey(hwnd,7814,0x4003u,0x48u); // Ctrl+Alt+H
            emergencyHotkeyRegistered = !isolated && RegisterHotKey(hwnd, 7815, 0x4003u, 0x79u);
            WriteStatus(-1);
            if(!isolated)SetHudVisible(companionHost.ClassicPreferred);

            tick = new System.Windows.Forms.Timer();
            tick.Interval = 450;
            tick.Tick += delegate(object sender, EventArgs args) {
                try { if(!CheckShutdown()){Pump(); if(!exiting)PollActivity();} }
                catch (Exception) { SetState("error", -1, "Bridge error; check local files"); }
            };
            if(!isolated)tick.Start();
            if (!isolated && !hotkeyRegistered) toast.Display("Ctrl+Alt+P unavailable; use tray Stop");
        }

        protected override void SetVisibleCore(bool value)
        {
            base.SetVisibleCore(false);
        }

        protected override void WndProc(ref Message m)
        {
            if(m.Msg==WmHotkey && m.WParam.ToInt32()==7815){EmergencyStopAgents();return;}
            if(m.Msg==WmHotkey && m.WParam.ToInt32()==7814){ToggleHud();return;}
            if (m.Msg == WmHotkey && m.WParam.ToInt32() == HotkeyId)
            {
                StopJob();
                return;
            }
            base.WndProc(ref m);
        }

        private void ToggleHud()
        {
            SetHudVisible(!hudEnabled);
        }

        private void SetHudVisible(bool visible)
        {
            if(companionHost!=null && companionHost.ClassicPreferred!=visible)companionHost.RememberClassic(visible);
            hudEnabled=visible;
            hudMenu.Text=hudEnabled?"Hide Classic widget":"Show Classic widget";
            if(hudEnabled)hud.Show();else hud.Hide();
        }

        private static string TimeUtc()
        {
            return DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", System.Globalization.CultureInfo.InvariantCulture);
        }

        private int PendingCount()
        {
            return Directory.GetFiles(pending, "*.job").Length;
        }

        private void WriteStatus(int code)
        {
            // Privacy: status has no names, selectors, command lines or UI values.
            string json = "{\"schema\":\"reflexcore.bridge.v1\",\"state\":\"" + currentState +
                "\",\"at_utc\":\"" + TimeUtc() + "\",\"exit_code\":" + code.ToString() +
                ",\"pending\":" + PendingCount().ToString() +
                ",\"hotkey_registered\":" + (hotkeyRegistered ? "true" : "false") + "}";
            File.WriteAllText(statusPath, json);
        }

        private void SetState(string state, int code, string notification)
        {
            currentState = state;
            icon.Text = "ReflexCore | " + state;
            statusMenu.Text = "Status: " + state;
            if (state == "running") icon.Icon = SystemIcons.Application;
            else if (state == "failed" || state == "error") icon.Icon = SystemIcons.Error;
            else if (state == "stopped") icon.Icon = SystemIcons.Warning;
            else icon.Icon = SystemIcons.Information;
            WriteStatus(code);
            string dragon = Path.Combine(root,"assets","reflexcore.ico");
            if(File.Exists(dragon)) { try { icon.Icon = new Icon(dragon); } catch(Exception) {} }
            if (!isolated && notification != null && notification.Length > 0) toast.Display(notification);
        }

        // Never render raw strings from another process into the UI.
        // This intentionally accepts ONLY a small finite set of safe status enums.
        private static string StageText(string stage)
        {
            switch(stage)
            {
                case "ready": return "Ready";
                case "observing": return "Observing";
                case "capturing": return "Capturing";
                case "thinking": return "Thinking";
                case "deciding": return "Choosing action";
                case "awaiting_effect": return "Waiting for effect";
                case "executing": return "Executing";
                case "verifying": return "Verifying";
                case "verified": return "Effect verified";
                case "human_override": return "Operator override";
                case "completed": return "Goal completed";
                case "failed": return "Failed or rejected";
                case "stopped": return "Stopped";
                default: return "";
            }
        }
        internal static string Value(string json,string key)
        {
            Match match=Regex.Match(json,"\""+Regex.Escape(key)+"\"\\s*:\\s*\"([a-z0-9_.-]{1,40})\"");
            return match.Success?match.Groups[1].Value:"";
        }
        internal static double TokensPerSecond(string json)
        {
            Match match=Regex.Match(json,"\"last_tps\"\\s*:\\s*(\\d{1,4}(?:\\.\\d{1,2})?)\\s*(?=[,}])");
            if(!match.Success)return 0;
            double v;
            return double.TryParse(match.Groups[1].Value,NumberStyles.AllowDecimalPoint,
                CultureInfo.InvariantCulture,out v)&&v<=1000? v:0;
        }

        private static bool Fresh(DateTime measuredUtc,DateTime now)
        {
            double age=(now-measuredUtc).TotalSeconds;
            return age>=-10 && age<=65;
        }

        internal static bool ActivityVisible(string source,DateTime measuredUtc,DateTime now)
        {
            return Fresh(measuredUtc,now) &&
                (source!="citadel_rust" || now-measuredUtc<=TimeSpan.FromSeconds(6));
        }

        private static DateTime ActivityTime(string json,string field)
        {
            Match stamp=Regex.Match(json,"\""+field+"\"\\s*:\\s*\"(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{1,7})?(?:Z|\\+00:00))\"");
            DateTimeOffset at;
            return stamp.Success && DateTimeOffset.TryParse(stamp.Groups[1].Value,CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal,out at)?at.UtcDateTime:DateTime.MinValue;
        }

        internal static DateTime ModelSampleTime(string json,DateTime activityUtc,out bool precise)
        {
            // Legacy VisionLoop records carry only at_utc. New producers may provide actual measurement time.
            precise=Regex.IsMatch(json,"\"last_tps_utc\"\\s*:");
            return precise?ActivityTime(json,"last_tps_utc"):activityUtc;
        }

        internal static bool CaptureSignalActive(DateTime writtenUtc,DateTime now)
        {
            return writtenUtc<=now && now-writtenUtc<=CaptureSignalLifetime;
        }

        private void PollActivity()
        {
            var now=DateTime.UtcNow;
            // A terminated capture worker can leave its marker behind.
            bool capturing=CaptureSignalActive(File.GetLastWriteTimeUtc(captureSignalPath),now);
            if(capturing || !hudEnabled) { if(hud.Visible) hud.Hide(); }
            else if(!hud.Visible){ hud.Reposition(); hud.Show(); }
            hud.RefreshResources();
            if(!ActivityVisible(lastActivitySource,activeStageUtc,now) && lastActivityStage!="")
            {
                lastActivityStage="";lastActivitySource="";
                activityMenu.Text="Activity: idle";
                icon.Text="ReflexCore | "+currentState;
                hud.RefreshStatus("Idle");
            }
            if(File.Exists(activityPath))
            {
                try
                {
                    var file= new FileInfo(activityPath);
                    var written=file.LastWriteTimeUtc;
                    if(written!=lastActivityWriteUtc && file.Length<=2048)
                    {
                        string json=File.ReadAllText(activityPath);
                        if(RenderActivity(json,now)) lastActivityWriteUtc=written;
                    }
                }
                catch(IOException) {} // A producer may be replacing the activity file.
                catch(UnauthorizedAccessException) {}
            }
            if(hud.Visible||hud.feedWhenHidden) hud.RefreshThroughput(modelRate,modelSampleUtc,now,modelSampleTimePrecise);
            if(companionHost!=null)companionHost.Update(lastPending<0?0:lastPending,currentState,capturing,SetHudVisible);
        }

        private bool RenderActivity(string json,DateTime now)
        {
            if(json.Length>2048||Value(json,"schema")!="reflexcore.activity.v1")return false;
            DateTime at=ActivityTime(json,"at_utc");
            string source=Value(json,"source");
            if(!ActivityVisible(source,at,now))return at!=DateTime.MinValue;
            if(source!="citadel_rust"&&source!="shared_control"&&source!="vision_loop")return false;
            string stage=Value(json,"stage");
            string label=StageText(stage);
            if(label.Length==0)return false;
            string origin=source=="shared_control"?"Shared Control":source=="vision_loop"?"VisionLoop":"Citadel";
            if(source=="vision_loop")
            {
                double rate=TokensPerSecond(json);
                bool precise;
                DateTime measured=ModelSampleTime(json,at,out precise);
                if(rate>0 && measured>=modelSampleUtc && Fresh(measured,now))
                {
                    modelRate=rate;
                    modelSampleUtc=measured;
                    modelSampleTimePrecise=precise;
                }
            }
            activeStageUtc=at;
            activityMenu.Text=origin+" — "+label;
            hud.RefreshStatus(origin+" — "+label);
            icon.Text="ReflexCore | "+label;
            bool changed=(stage!=lastActivityStage || source!=lastActivitySource);
            lastActivityStage=stage;lastActivitySource=source;
            bool showProgressToast=source!="citadel_rust" && (stage=="thinking"||stage=="awaiting_effect"||stage=="verified");
            if(changed && (showProgressToast||
                           stage=="failed"||stage=="completed"||stage=="human_override"))
            {
                string message=origin+": "+label;
                toast.Display(message);
                if(companionHost!=null && companionHost.WindowsNotificationsEnabled)
                {
                    try {icon.ShowBalloonTip(2200,"ReflexCore",message,ToolTipIcon.Info);}catch{}
                }
            }
            return true;
        }

        private string[] Jobs()
        {
            string[] jobs = Directory.GetFiles(pending, "*.job");
            Array.Sort(jobs, StringComparer.OrdinalIgnoreCase);
            return jobs;
        }

        private void StartPending(bool approvedByUser)
        {
            if (active != null) return;
            foreach (string path in Jobs())
            {
                try
                {
                    if(queue.Requested(path,"cancel")){queue.Finish(path,"cancelled");continue;}
                    var info=new FileInfo(path);
                    if((info.Attributes&FileAttributes.ReparsePoint)!=0 || info.Length>256)
                        throw new InvalidDataException("Invalid job file");
                    string[] lines = File.ReadAllLines(path);
                    if (lines.Length != 2) throw new Exception("Invalid job manifest");
                    bool auto = lines[0] == "RUN";
                    if(!auto && lines[0]!="REVIEW")throw new InvalidDataException("Invalid queue mode");
                    if (!approvedByUser && !queue.Requested(path,"approve") && (!auto || File.GetCreationTimeUtc(path) < sessionStartedUtc)) continue;
                    string name = lines[1];
                    if (!Regex.IsMatch(name, @"^[a-zA-Z0-9_-]{1,70}\.ps1$"))
                        throw new Exception("Invalid task name");
                    string tasks = Path.Combine(root, "tasks");
                    string script = Path.GetFullPath(Path.Combine(tasks, name));
                    if (!script.StartsWith(tasks + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                        throw new Exception("Task path outside project");
                    if (!File.Exists(script)) throw new Exception("Task script missing");
                    FileAttributes attr = File.GetAttributes(script);
                    if ((attr & FileAttributes.ReparsePoint) != 0) throw new Exception("Symlink task disallowed");
                    string moved = Path.Combine(running, Path.GetFileName(path));
                    File.Move(path, moved);
                    activeJob = moved;
                    cancelled = false;
                    forceStopStarted = false;
                    stopTimedOut = false;
                    cooperativeOnly=name=="notepad-save.ps1" || name=="notepad-visual.ps1" || name=="rename-extensions.ps1";
                    ProcessStartInfo psi = new ProcessStartInfo();
                    psi.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                        @"WindowsPowerShell\v1.0\powershell.exe");
                    string file=Path.GetFileName(moved);
                    if(!Regex.IsMatch(file,@"\A[a-zA-Z0-9_-]{1,100}\.job\z"))throw new InvalidDataException("Invalid job filename");
                    psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \""
                        +Path.Combine(root,"tools","ReflexCore-QueuedWorker.ps1")+"\" -Manifest "+file;
                    if(name=="verify-handoff.ps1"){
                        var epoch=new DateTime(1970,1,1,0,0,0,DateTimeKind.Utc);
                        var submitted=DateTime.ParseExact(file.Substring(0,17),"yyyyMMddHHmmssfff",
                            System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.AssumeUniversal|System.Globalization.DateTimeStyles.AdjustToUniversal);
                        psi.EnvironmentVariables["REFLEX_HANDOFF_SUBMIT_US"]=((submitted-epoch).Ticks/10).ToString();
                        psi.EnvironmentVariables["REFLEX_HANDOFF_LAUNCH_US"]=((DateTime.UtcNow-epoch).Ticks/10).ToString();
                    }
                    psi.WorkingDirectory = root;
                    psi.UseShellExecute = false;
                    psi.CreateNoWindow = true;
                    psi.WindowStyle = ProcessWindowStyle.Hidden;
                    psi.RedirectStandardOutput = true;
                    psi.RedirectStandardError = true;
                    active = new Process();
                    active.StartInfo = psi;
                    active.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { /* Discard private output. */ };
                    active.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { /* Discard private output. */ };
                    if (!active.Start()) throw new Exception("Task process could not start");
                    active.BeginOutputReadLine();
                    active.BeginErrorReadLine();
                    SetState("running", -1, "Agent started (Ctrl+Alt+P stops)");
                    return;
                }
                catch (Exception)
                {
                    if(activeJob!=null)queue.Finish(activeJob,"failed");
                    activeJob = null;
                    if (active != null)
                    {
                        try
                        {
                            if (!active.HasExited)
                                Process.Start(new ProcessStartInfo("taskkill.exe", "/PID " + active.Id + " /T /F")
                                    { CreateNoWindow = true, UseShellExecute = false }).WaitForExit(3000);
                        }
                        catch (Exception) { }
                        active.Dispose(); active = null;
                    }
                    if(File.Exists(path))queue.Finish(path,"failed");
                    SetState("failed", -1, "Invalid job; no task executed");
                }
            }
        }

        private void StopJob()
        {
            if (active == null)
            {
                toast.Display("No supervised job running");
                return;
            }
            if(active.HasExited)return;
            if(cancelled)return;
            queue.Request(QueueStore.IdOf(activeJob),"cancel");
            cancelled = true;
            // Notepad can share a Windows process with private tabs. Its worker stops cooperatively.
            stopDeadline = DateTime.UtcNow.AddMilliseconds(cooperativeOnly ? 30000 : 900);
            SetState("stopping", -1, "Stop requested; waiting for worker cleanup");
        }

        private void PollStop()
        {
            if(!cancelled || stopTimedOut || DateTime.UtcNow<stopDeadline || active.HasExited)return;
            if(!cooperativeOnly && !forceStopStarted){
                forceStopStarted=true;
                stopDeadline=DateTime.UtcNow.AddSeconds(3);
                try {
                    stopHelper=Process.Start(new ProcessStartInfo {
                        FileName=Path.Combine(Environment.SystemDirectory,"taskkill.exe"),
                        Arguments="/PID "+active.Id.ToString()+" /T /F",
                        CreateNoWindow=true,UseShellExecute=false,WindowStyle=ProcessWindowStyle.Hidden
                    });
                    return;
                } catch(System.ComponentModel.Win32Exception) { }
            }
            stopTimedOut=true;
            exitAfterWorker=false;
            SetState("error",-1,"Stop cleanup timed out; the queue is held while the worker is active");
        }

        private void EmergencyStopAgents()
        {
            try {
                string signal = Path.Combine(bridge,"global-stop.signal");
                File.WriteAllText(signal,TimeUtc());
                lastEmergencyStopUtc = File.GetLastWriteTimeUtc(signal);
            }
            catch (IOException) { SetState("error",-1,"Could not broadcast emergency stop"); }
            catch (UnauthorizedAccessException) { SetState("error",-1,"Could not broadcast emergency stop"); }
            StopAllJobs();
        }

        private void StopAllJobs()
        {
            // These manifests belong to this tray supervisor only. Do not touch other Windows processes.
            foreach(string file in Jobs()){
                try{queue.Finish(file,"cancelled");}catch(IOException){}
            }
            if(active!=null)StopJob();
            else SetState("stopped",-1,"All supervised Reflex tasks stopped");
        }
        private void Pump()
        {
            var stopAt = File.GetLastWriteTimeUtc(Path.Combine(bridge,"global-stop.signal"));
            if (stopAt >= sessionStartedUtc && stopAt > lastEmergencyStopUtc)
            {
                lastEmergencyStopUtc = stopAt;
                StopAllJobs();
            }
            queue.CancelPending();
            if (File.Exists(controlPath))
            {
                string claimed=controlPath+"."+Guid.NewGuid().ToString("N")+".claimed";
                try { File.Move(controlPath,claimed); }
                catch(IOException) { return; }
                string action;
                try { action=File.ReadAllText(claimed).Trim().ToLowerInvariant(); }
                finally { File.Delete(claimed); }
                if (action == "stop") StopJob();
                if (action == "stop-all") StopAllJobs();
                if (action == "exit") { RequestShutdown(false); return; }
                if (action == "restart") { RequestShutdown(true); return; }
            }
            if (active != null)
            {
                if(!active.HasExited && !cancelled && queue.Requested(activeJob,"cancel"))StopJob();
                PollStop();
                if (active.HasExited)
                {
                    int code = active.ExitCode;
                    if(stopHelper!=null){stopHelper.Dispose();stopHelper=null;}
                    active.Dispose();
                    active = null;
                    bool verified=false;
                    string terminal=code==0?"completed":"failed";
                    if(activeJob!=null){
                        TaskReceipt receipt=queue.ReadWorkerReceipt(activeJob);
                        verified=code==0 && receipt!=null && receipt.outcome=="verified" && receipt.verification=="verified";
                        cancelled=cancelled || (code!=0 && queue.Requested(activeJob,"cancel"));
                        terminal=verified?"completed":cancelled?"cancelled":code==0?"completed":"failed";
                        if(!verified && cancelled && (receipt==null || receipt.outcome!="cancelled")){
                            string id=QueueStore.IdOf(activeJob);
                            receipt=new TaskReceipt {
                                schema="reflexcore.task.receipt.v1",task_id=id,run_id=id,stage="queue",outcome="cancelled",
                                verification=code==2&&!forceStopStarted?"not_confirmed":"unknown",
                                reason=forceStopStarted||stopTimedOut?"cleanup_unconfirmed":code==2?"operator_cancelled":"cancelled_effect_unknown"
                            };
                        } else if(!verified && !cancelled && receipt!=null) {
                            if(receipt.outcome=="unverified" || receipt.outcome=="partial")terminal="completed";
                            else if(receipt.outcome=="verified" || receipt.outcome=="cancelled")receipt=null;
                        }
                        queue.Finish(activeJob,terminal,receipt);
                    }
                    activeJob = null;
                    if (terminal=="cancelled") SetState("stopped", -1, "Agent stopped; see the task receipt");
                    else if (terminal=="completed") SetState("completed", code, verified?"Agent result verified":"Agent finished without verification");
                    else SetState("failed", code, "Agent failed (exit code " + code.ToString() + ")");
                    if(exitAfterWorker)ExitTray();
                }
                return;
            }
            int count = PendingCount();
            if (count != lastPending)
            {
                if (!isolated && count > lastPending && count > 0 && lastPending >= 0)
                    toast.Display("New local task queued");
                lastPending = count;
                WriteStatus(currentState == "completed" ? 0 : -1);
            }
            StartPending(false);
        }

        private static bool StudioRunning()
        {
            try
            {
                using(var mutex=Mutex.OpenExisting(@"Local\ReflexCoreControlCenter"))return true;
            }
            catch(WaitHandleCannotBeOpenedException){return false;}
        }
        private void RequestShutdown(bool restartApplication)
        {
            if(exiting || shutdownUntil!=default(DateTime))return;
            shutdownRestart=restartApplication;
            if(!StudioRunning())
            {
                RestartRequested=shutdownRestart;
                ExitTray();
                return;
            }
            File.WriteAllText(Path.Combine(bridge,"ui-lifecycle.txt"),"exit");
            shutdownUntil=DateTime.UtcNow.AddSeconds(6);
        }
        private bool CheckShutdown()
        {
            if(shutdownUntil==default(DateTime))return false;
            if(!StudioRunning())
            {
                RestartRequested=shutdownRestart;
                shutdownUntil=default(DateTime);
                ExitTray();
            }
            else if(DateTime.UtcNow>=shutdownUntil)
            {
                string request=Path.Combine(bridge,"ui-lifecycle.txt");
                if(File.Exists(request))File.Delete(request);
                shutdownUntil=default(DateTime);
                toast.Display("Studio did not close. Try again after closing its dialog.");
            }
            return true;
        }
        private void ExitTray()
        {
            if (exiting) return;
            if (active != null) {
                exitAfterWorker=true;
                StopJob();
                return;
            }
            exiting = true;
            tick.Stop();
            if (stopHelper != null) stopHelper.Dispose();
            if (hotkeyRegistered) UnregisterHotKey(Handle, HotkeyId);
            if(emergencyHotkeyRegistered)UnregisterHotKey(Handle,7815);
            if(!isolated)UnregisterHotKey(Handle,7814);
            icon.Visible = false;
            icon.Dispose();
            if(companionHost!=null)companionHost.Dispose();
            hud.Close();hud.Dispose();
            toast.Close();
            toast.Dispose();
            menu.Dispose();
            Close();
            Application.ExitThread();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (tick != null) tick.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
