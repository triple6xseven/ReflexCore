using System;
using System.IO;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using System.Threading;
using System.Text.RegularExpressions;

namespace ReflexCore.Bridge
{
    public static class TrayHost
    {
        public static void SelfTest(string root)
        {
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
            Console.WriteLine("[ReflexCore] Tray/HUD C# compiled and self-test passed.");
        }

        [STAThread]
        public static void Run(string root)
        {
            bool created;
            using (Mutex mutex = new Mutex(true, @"Local\ReflexCoreAgentTray", out created))
            {
                if (!created) return;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayWindow(root));
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

    // Light WinForms overlay owned by the already running tray process.
    // No browser, GPU renderer, network requests, raw prompt or screenshot data.
    internal sealed class ActivityHud : Form
    {
        private readonly Label header;
        private readonly Label stageLabel;
        private readonly Label speedLabel;
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams
        {
            get { CreateParams cp=base.CreateParams; cp.ExStyle|=0x08000000|0x00000080; return cp; }
        }
        public ActivityHud()
        {
            Width=288; Height=94; TopMost=true;
            FormBorderStyle=FormBorderStyle.None;
            StartPosition=FormStartPosition.Manual; ShowInTaskbar=false;
            BackColor=Color.FromArgb(14,24,27); Opacity=0.94;
            header=new Label { Text="REFLEXCORE  /  LIVE STATUS", Left=12, Top=7, Width=260, Height=20,
                ForeColor=Color.FromArgb(94,237,150), Font=new Font("Consolas",9,FontStyle.Bold) };
            stageLabel=new Label { Text="Сейчас: ожидание", Left=12, Top=33, Width=268, Height=22,
                ForeColor=Color.FromArgb(224,241,228), Font=new Font("Segoe UI",10,FontStyle.Regular) };
            speedLabel=new Label { Text="Ollama: — tok/s (последний ответ)", Left=12, Top=63, Width=270, Height=18,
                ForeColor=Color.FromArgb(140,198,182), Font=new Font("Segoe UI",8,FontStyle.Regular) };
            Controls.Add(header); Controls.Add(stageLabel); Controls.Add(speedLabel);
            Reposition();
        }
        public void Reposition()
        {
            Rectangle a=Screen.PrimaryScreen.WorkingArea;
            Location=new Point(a.Right-Width-12,a.Top+35);
        }
        public void RefreshStatus(string label,double tps)
        {
            stageLabel.Text="Сейчас: "+label;
            speedLabel.Text=tps>0?"Ollama: "+tps.ToString("0.0",System.Globalization.CultureInfo.InvariantCulture)+" tok/s (посл. ответ)":"Ollama: — tok/s (нет замера)";
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
        private readonly string captureSignalPath;
        private readonly ContextMenuStrip menu;
        private readonly ToolStripMenuItem statusMenu;
        private readonly ToolStripMenuItem activityMenu;
        private readonly string activityPath;
        private string lastActivityStage="";
        private string lastActivitySource="";
        private readonly System.Windows.Forms.Timer tick;
        private Process active;
        private string activeJob;
        private bool cancelled;
        private bool hotkeyRegistered;
        private bool exiting;
        private string currentState;
        private int lastPending = -1;
        private readonly DateTime sessionStartedUtc;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
        [DllImport("user32.dll")]
        private static extern bool UnregisterHotKey(IntPtr hwnd, int id);

        public TrayWindow(string rootPath)
        {
            root = Path.GetFullPath(rootPath);
            bridge = Path.Combine(root, "data", "bridge");
            pending = Path.Combine(bridge, "pending");
            running = Path.Combine(bridge, "running");
            statusPath = Path.Combine(bridge, "status.json");
            controlPath = Path.Combine(bridge, "control.txt");
            Directory.CreateDirectory(pending);
            Directory.CreateDirectory(running);
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
            menu = new ContextMenuStrip();
            statusMenu = new ToolStripMenuItem("Status: ready");
            statusMenu.Enabled = false;
            menu.Items.Add(statusMenu);
            activityMenu = new ToolStripMenuItem("Сейчас: ожидание");
            activityMenu.Enabled = false;
            menu.Items.Add(activityMenu);
            hudMenu=new ToolStripMenuItem("Hide corner status widget");
            hudMenu.Click += delegate(object s,EventArgs e) {
                hudEnabled=!hudEnabled;
                hudMenu.Text=hudEnabled?"Hide corner status widget":"Show corner status widget";
                if(hudEnabled)hud.Show();else hud.Hide();
            };
            menu.Items.Add(hudMenu);
            menu.Items.Add("Open Control Center", null, delegate(object s, EventArgs e) {
                string center = Path.Combine(root, "tools", "ReflexCore-ControlCenter.ps1");
                string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
                Process.Start(new ProcessStartInfo { FileName=ps, Arguments="-NoProfile -ExecutionPolicy Bypass -File \"" + center + "\"",WorkingDirectory=root,UseShellExecute=false,CreateNoWindow=true });
            });
            menu.Items.Add("Run next pending job", null, delegate(object s, EventArgs e) { StartPending(true); });
            menu.Items.Add("STOP - Ctrl+Alt+P", null, delegate(object s, EventArgs e) { StopJob(); });
            menu.Items.Add("STOP ALL: Reflex + Ollama", null, delegate(object s, EventArgs e) {
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
            menu.Items.Add("Open ReflexCore folder", null, delegate(object s, EventArgs e) {
                Process.Start("explorer.exe", root);
            });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Exit tray", null, delegate(object s, EventArgs e) { ExitTray(); });

            icon = new NotifyIcon();
            icon.ContextMenuStrip = menu;
            icon.Icon = SystemIcons.Information;
            icon.Text = "ReflexCore | ready";
            icon.Visible = true;
            string dragonIcon = Path.Combine(root,"assets","reflex_dragon.ico");
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
            hotkeyRegistered = RegisterHotKey(hwnd, HotkeyId, 0x4003u, 0x50u); // ALT+CTRL+NOREPEAT, P
            WriteStatus(-1);
            hud.Show();

            tick = new System.Windows.Forms.Timer();
            tick.Interval = 450;
            tick.Tick += delegate(object sender, EventArgs args) {
                try { Pump(); PollActivity(); }
                catch (Exception) { SetState("error", -1, "Bridge error; check local files"); }
            };
            tick.Start();
            if (!hotkeyRegistered) toast.Display("Ctrl+Alt+P unavailable; use tray Stop");
        }

        protected override void SetVisibleCore(bool value)
        {
            base.SetVisibleCore(false);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WmHotkey && m.WParam.ToInt32() == HotkeyId)
            {
                StopJob();
                return;
            }
            base.WndProc(ref m);
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
            string dragon = Path.Combine(root,"assets","reflex_dragon.ico");
            if(File.Exists(dragon)) { try { icon.Icon = new Icon(dragon); } catch(Exception) {} }
            if (notification != null && notification.Length > 0) toast.Display(notification);
        }

        // Never render raw strings from another process into the UI.
        // This intentionally accepts ONLY a small finite set of safe status enums.
        private static string StageText(string stage)
        {
            switch(stage)
            {
                case "ready": return "готов к работе";
                case "observing": return "наблюдает состояние";
                case "capturing": return "снимает кадр";
                case "thinking": return "модель анализирует";
                case "deciding": return "выбирает действие";
                case "awaiting_effect": return "ожидает результат";
                case "executing": return "выполняет действие";
                case "verifying": return "проверяет последствия";
                case "verified": return "действие проверено";
                case "human_override": return "остановлен человеком";
                case "completed": return "цель завершена";
                case "failed": return "ошибка или отказ проверки";
                case "stopped": return "остановлен";
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
            Match match=Regex.Match(json,"\"last_tps\"\\s*:\\s*(\\d{1,3}(?:\\.\\d{1,2})?)(?![0-9.])");
            if(!match.Success)return 0;
            double v;
            return double.TryParse(match.Groups[1].Value,System.Globalization.NumberStyles.AllowDecimalPoint,
                System.Globalization.CultureInfo.InvariantCulture,out v)&&v<=1000? v:0;
        }
        private void PollActivity()
        {
            bool capturing=File.Exists(captureSignalPath);
            if(capturing || !hudEnabled) { if(hud.Visible) hud.Hide(); }
            else if(!hud.Visible){ hud.Reposition(); hud.Show(); }
            if(!File.Exists(activityPath)){hud.RefreshStatus("ожидание",0);return;}
            string json;
            try { json=File.ReadAllText(activityPath); } catch { return; }
            if(json.Length>2048||Value(json,"schema")!="reflexcore.activity.v1")return;
            // JSON timestamp is not displayed, used only to discard stale reports.
            Match stamp=Regex.Match(json,"\"at_utc\"\\s*:\\s*\"([^\"]{1,40})\"");
            DateTime at;
            if(!stamp.Success || !DateTime.TryParse(stamp.Groups[1].Value,
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.RoundtripKind,out at))return;
            double age=(DateTime.UtcNow-at.ToUniversalTime()).TotalSeconds;
            if(age< -10||age>65)
            {
                if(lastActivityStage!="")
                {
                    lastActivityStage="";lastActivitySource="";
                    activityMenu.Text="Сейчас: ожидание";
                    icon.Text="ReflexCore | "+currentState;
                    hud.RefreshStatus("ожидание",0);
                }
                return;
            }
            string source=Value(json,"source");
            if(source!="citadel_rust"&&source!="shared_control"&&source!="vision_loop")return;
            string stage=Value(json,"stage");
            string label=StageText(stage);
            if(label.Length==0)return;
            string origin=source=="shared_control"?"Qwen/Windows":source=="vision_loop"?"VisionLoop":"Rust";
            double rate=source=="vision_loop"?TokensPerSecond(json):0;
            activityMenu.Text="Сейчас: "+origin+" — "+label+(rate>0?" | "+rate.ToString("0.0",System.Globalization.CultureInfo.InvariantCulture)+" tok/s (last)":"");
            hud.RefreshStatus(origin+" — "+label,rate);
            icon.Text="ReflexCore | "+label;
            bool changed=(stage!=lastActivityStage || source!=lastActivitySource);
            lastActivityStage=stage;lastActivitySource=source;
            if(changed && (stage=="thinking"||stage=="awaiting_effect"||stage=="verified"||
                           stage=="failed"||stage=="completed"||stage=="human_override"))
            {
                string message=origin+": "+label;
                toast.Display(message);
                try {icon.ShowBalloonTip(2200,"ReflexCore",message,ToolTipIcon.Info);}catch{}
            }
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
                    string[] lines = File.ReadAllLines(path);
                    if (lines.Length != 2) throw new Exception("Invalid job manifest");
                    bool auto = lines[0] == "RUN";
                    if (!approvedByUser && (!auto || File.GetCreationTimeUtc(path) < sessionStartedUtc)) continue;
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
                    ProcessStartInfo psi = new ProcessStartInfo();
                    psi.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                        @"WindowsPowerShell\v1.0\powershell.exe");
                    psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + "\"";
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
                    if (activeJob != null && File.Exists(activeJob)) File.Delete(activeJob);
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
                    if (File.Exists(path)) File.Delete(path);
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
            cancelled = true;
            try
            {
                if (!active.HasExited)
                {
                    ProcessStartInfo psi = new ProcessStartInfo();
                    psi.FileName = "taskkill.exe";
                    psi.Arguments = "/PID " + active.Id.ToString() + " /T /F";
                    psi.CreateNoWindow = true;
                    psi.UseShellExecute = false;
                    psi.WindowStyle = ProcessWindowStyle.Hidden;
                    using (Process killer = Process.Start(psi))
                    {
                        if (!killer.WaitForExit(3000)) throw new Exception("taskkill timed out");
                        if (killer.ExitCode != 0 && !active.HasExited)
                            throw new Exception("taskkill failed");
                    }
                }
            }
            catch (Exception)
            {
                SetState("error", -1, "Stop failed; check job process");
                return;
            }
            SetState("stopping", -1, "Stop requested; terminating job tree");
        }

        private void StopAllJobs()
        {
            // These manifests belong to this tray supervisor only. Do not touch other Windows processes.
            foreach(string file in Jobs()){
                try{File.Delete(file);}catch{}
            }
            if(active!=null)StopJob();
            else SetState("stopped",-1,"All supervised Reflex tasks stopped");
        }
        private void Pump()
        {
            if (File.Exists(controlPath))
            {
                string action = File.ReadAllText(controlPath).Trim().ToLowerInvariant();
                File.Delete(controlPath);
                if (action == "stop") StopJob();
                if (action == "stop-all") StopAllJobs();
                if (action == "exit") { ExitTray(); return; }
            }
            if (active != null)
            {
                if (active.HasExited)
                {
                    int code = active.ExitCode;
                    active.Dispose();
                    active = null;
                    if (activeJob != null && File.Exists(activeJob)) File.Delete(activeJob);
                    activeJob = null;
                    if (cancelled) SetState("stopped", -1, "Agent stopped");
                    else if (code == 0) SetState("completed", 0, "Agent finished successfully");
                    else SetState("failed", code, "Agent failed (exit code " + code.ToString() + ")");
                }
                return;
            }
            int count = PendingCount();
            if (count != lastPending)
            {
                if (count > lastPending && count > 0 && lastPending >= 0)
                    toast.Display("New local task queued");
                lastPending = count;
                WriteStatus(currentState == "completed" ? 0 : -1);
            }
            StartPending(false);
        }

        private void ExitTray()
        {
            if (exiting) return;
            exiting = true;
            tick.Stop();
            if (active != null) StopJob();
            if (hotkeyRegistered) UnregisterHotKey(Handle, HotkeyId);
            icon.Visible = false;
            icon.Dispose();
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