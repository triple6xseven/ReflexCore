// ReflexCore Measurement Lab 0.6.1 — local read-only evidence dashboard.
// Native WinForms / .NET Framework; no network listeners, credentials, screenshots or input automation.
// The benchmark launch button is an explicit operator action and launches one fixed local script.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace ReflexCore.Diagnostics
{
    internal static class Read
    {
        public static Dictionary<string,object> Json(string file)
        {
            try {
                if (!File.Exists(file) || new FileInfo(file).Length > 2097152) return null;
                return new JavaScriptSerializer { MaxJsonLength = 2097152 }.Deserialize<Dictionary<string,object>>(File.ReadAllText(file,Encoding.UTF8));
            } catch { return null; }
        }
        public static object Value(Dictionary<string,object> d,string key)
        {
            object v; return d != null && d.TryGetValue(key,out v) ? v : null;
        }
        public static string Str(Dictionary<string,object> d,string key)
        { object v=Value(d,key);return v == null ? "" : Convert.ToString(v,System.Globalization.CultureInfo.InvariantCulture); }
        public static double Num(Dictionary<string,object> d,string key)
        { double n;return double.TryParse(Str(d,key),System.Globalization.NumberStyles.Any,System.Globalization.CultureInfo.InvariantCulture,out n) ? n : 0; }
        public static bool Bool(Dictionary<string,object> d,string key)
        { object v=Value(d,key);return v is bool && (bool)v; }
        public static Dictionary<string,object> Map(object o){return o as Dictionary<string,object>;}
        public static object[] Array(Dictionary<string,object> d,string key)
        {
            var list=Value(d,key) as System.Collections.IList;
            if(list==null)return new object[0];
            object[] items=new object[list.Count];list.CopyTo(items,0);return items;
        }
    }
    internal sealed class TimeBars : System.Windows.Forms.Control
    {
        public Color AccentColor = Color.FromArgb(55,201,121);
        public List<double> Values = new List<double>();
        public TimeBars(){DoubleBuffered=true;BackColor=Color.FromArgb(14,24,20);ForeColor=Color.FromArgb(108,236,154);}
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e); Graphics g=e.Graphics; g.Clear(BackColor);
            using(Brush muted=new SolidBrush(ForeColor))
                g.DrawString("Verified goal time · recent successful runs (ms; lower is better)",Font,muted,12,8);
            if(Values.Count==0){g.DrawString("No verified benchmark samples yet",Font,Brushes.Gray,12,40);return;}
            int count=Math.Min(Values.Count,24), left=20, right=Width-16, top=43, bottom=Height-26;
            if(right<=left || bottom<=top)return;
            double max=Values.Skip(Math.Max(0,Values.Count-count)).DefaultIfEmpty(1).Max(); if(max<=0)max=1;
            int cell=Math.Max(3,(right-left)/count), barW=Math.Max(2,cell-4);
            using(Brush b=new SolidBrush(AccentColor))
            using(Pen p=new Pen(ForeColor))
            {
                g.DrawLine(p,left,bottom,right,bottom);
                for(int i=0;i<count;i++){
                    double v=Values[Values.Count-count+i]; int h=(int)((bottom-top)*v/max);
                    int x=left+i*cell;g.FillRectangle(b,x,bottom-h,barW,h);
                    if(cell>40)g.DrawString(Math.Round(v,0).ToString(),Font,Brushes.LightGray,x,Math.Max(top,bottom-h-17));
                }
            }
        }
    }
    public sealed class Dashboard : Form
    {
        readonly string root,dir;
        readonly Label stage,summary,resources,qwen,help;
        readonly NumericUpDown n;
        readonly DataGridView runs,trace,procGrid;
        readonly TimeBars chart;
        readonly TextBox evidence;
        readonly System.Windows.Forms.Timer timer;
        readonly Dictionary<string,double> previousCpu = new Dictionary<string,double>();
        readonly DateTime start=DateTime.UtcNow;
        DateTime lastCpu=DateTime.UtcNow;
        volatile bool gpuBusy=false;
        volatile string gpuSummary="GPU: not sampled (optional nvidia-smi)";
        string selectedRun="",lastHistorySignature="";
        int pulse=0;
        static readonly Color bg=Color.FromArgb(11,19,16),fg=Color.FromArgb(194,233,205),accent=Color.FromArgb(89,231,143),panel=Color.FromArgb(20,32,26);
        private void ApplyChartTheme(Color surface,Color text,Color highlight)
        {
            chart.BackColor=surface;
            chart.ForeColor=text;
            chart.AccentColor=highlight;
            chart.Invalidate();
        }

        private static void SelectSection(Panel[] screens,List<Button> buttons,int selected)
        {
            for(int i=0;i<screens.Length;i++){
                screens[i].Visible=i==selected;
                buttons[i].FlatAppearance.BorderSize=i==selected?2:1;
            }
        }

        public Dashboard(string project)
        {
            root=Path.GetFullPath(project);
            dir=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ReflexCore","diagnostics","measurement-lab");
            Text="REFLEXCORE | Measurement & Intelligence Lab v0.6.1";
            Width=1180;Height=810;MinimumSize=new Size(820,590);BackColor=bg;ForeColor=fg;
            Font=new Font("Segoe UI",9F);StartPosition=FormStartPosition.CenterScreen;
            var outer=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=3,BackColor=bg};
            outer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
            outer.RowStyles.Add(new RowStyle(SizeType.Absolute,108));
            outer.RowStyles.Add(new RowStyle(SizeType.Absolute,27));
            outer.RowStyles.Add(new RowStyle(SizeType.Percent,100));
            Controls.Add(outer);
            var header=new Panel{Dock=DockStyle.Fill,BackColor=panel};outer.Controls.Add(header,0,0);
            // Responsive 2-column header, safe under high-DPI and embedded tab widths.
            var headerGrid=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=2,Padding=new Padding(10,7,10,8)};
            headerGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,53));
            headerGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,47));
            headerGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,42));
            headerGrid.RowStyles.Add(new RowStyle(SizeType.Percent,100));header.Controls.Add(headerGrid);
            Label title=MakeLabel("REFLEXCORE  /  PERFORMANCE LAB",new Font("Consolas",15,FontStyle.Bold),accent);
            title.Dock=DockStyle.Fill;title.TextAlign=ContentAlignment.MiddleLeft;title.AutoEllipsis=true;headerGrid.Controls.Add(title,0,0);
            stage=MakeLabel("STATUS  waiting for measurements",new Font("Consolas",9),fg);
            stage.Dock=DockStyle.Fill;stage.TextAlign=ContentAlignment.TopLeft;stage.AutoEllipsis=true;headerGrid.Controls.Add(stage,0,1);
            var tools=new FlowLayoutPanel{Dock=DockStyle.Fill,FlowDirection=FlowDirection.LeftToRight,WrapContents=true,AutoScroll=true,Margin=new Padding(0)};
            headerGrid.Controls.Add(tools,1,0);headerGrid.SetRowSpan(tools,2);
            var launch=new Button{Text="RUN VERIFIED BENCHMARK",FlatStyle=FlatStyle.Flat,BackColor=Color.FromArgb(31,76,47),ForeColor=fg,Width=220,Height=33};
            launch.Click+=OnBenchmark;tools.Controls.Add(launch);
            n=new NumericUpDown{Minimum=1,Maximum=50,Value=5,BackColor=panel,ForeColor=fg,Width=53,Height=28};tools.Controls.Add(n);
            var open=new Button{Text="OPEN REPORTS",FlatStyle=FlatStyle.Flat,BackColor=panel,ForeColor=fg,Width=135,Height=33};
            open.Click+=delegate{Directory.CreateDirectory(dir);Process.Start("explorer.exe","\""+dir+"\"");};tools.Controls.Add(open);
            var sectionLayout=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=2,Margin=new Padding(0)};
            sectionLayout.RowStyles.Add(new RowStyle(SizeType.Absolute,44));
            sectionLayout.RowStyles.Add(new RowStyle(SizeType.Percent,100));
            outer.Controls.Add(sectionLayout,0,2);
            var sectionBar=new FlowLayoutPanel{Dock=DockStyle.Fill,WrapContents=false,AutoScroll=true};
            sectionLayout.Controls.Add(sectionBar,0,0);
            var content=new Panel{Dock=DockStyle.Fill,Margin=new Padding(0)};
            sectionLayout.Controls.Add(content,0,1);
            var overview=new Panel{Dock=DockStyle.Fill};
            summary=MakeLabel("No benchmark results recorded.",new Font("Consolas",11),accent);
            var overviewLayout=Rows(62,155);overview.Controls.Add(overviewLayout);
            summary.Dock=DockStyle.Fill;overviewLayout.Controls.Add(summary,0,0);
            chart=new TimeBars{Dock=DockStyle.Fill};overviewLayout.Controls.Add(chart,0,1);
            Tag=new Action<Color,Color,Color>(ApplyChartTheme);
            runs=Grid();runs.Dock=DockStyle.Fill;overviewLayout.Controls.Add(runs,0,2);
            runs.Columns.Add("at","Local time");runs.Columns.Add("number","Iteration");runs.Columns.Add("outcome","Verified");
            runs.Columns.Add("ms","Task ms");runs.Columns.Add("flow","UIA flow ms");runs.Columns.Add("cpu","Rust CPU ms");runs.Columns.Add("ram","Rust peak MB");runs.Columns.Add("id","Run ID");
            runs.Columns[7].Visible=false;
            runs.Columns[0].ValueType=typeof(DateTime);
            runs.Columns[0].DefaultCellStyle.Format="yyyy-MM-dd HH:mm:ss";
            runs.Columns[0].FillWeight=195;
            runs.Columns[1].ValueType=typeof(int);runs.Columns[1].FillWeight=67;
            foreach(int k in new[]{3,4,5,6}){runs.Columns[k].ValueType=typeof(double);runs.Columns[k].DefaultCellStyle.Format="F1";}
            runs.Columns[0].ToolTipText="Shown in local time. Stored in UTC.";
            runs.SelectionChanged+=delegate{ShowSelected();};
            var details=new Panel{Dock=DockStyle.Fill};
            evidence=new TextBox{Dock=DockStyle.Top,Height=135,ReadOnly=true,Multiline=true,BackColor=panel,ForeColor=fg,BorderStyle=BorderStyle.None,
                Font=new Font("Consolas",10),Text="Select a benchmark run to inspect its structural decision evidence."};
            var detailsLayout=Rows(135);details.Controls.Add(detailsLayout);
            evidence.Dock=DockStyle.Fill;detailsLayout.Controls.Add(evidence,0,0);
            trace=Grid();trace.Dock=DockStyle.Fill;detailsLayout.Controls.Add(trace,0,1);
            trace.Columns.Add("step","Step");trace.Columns.Add("action","UIA action");trace.Columns.Add("tries","Attempts");
            trace.Columns.Add("status","Status");trace.Columns.Add("verify","Verification");trace.Columns.Add("duration","Elapsed ms");trace.Columns.Add("why","Evidence code");
            var resourcePage=new Panel{Dock=DockStyle.Fill};
            var resourceLayout=Rows(112);resourcePage.Controls.Add(resourceLayout);
            resources=MakeLabel("CPU/RAM polling…",new Font("Consolas",12),accent);resources.Dock=DockStyle.Fill;resourceLayout.Controls.Add(resources,0,0);
            procGrid=Grid();procGrid.Dock=DockStyle.Fill;resourceLayout.Controls.Add(procGrid,0,1);
            procGrid.Columns.Add("group","Process group");procGrid.Columns.Add("count","Instances");procGrid.Columns.Add("cpu","CPU % (system normalized)");
            procGrid.Columns.Add("ram","Working RAM MB");procGrid.Columns.Add("priv","Private RAM MB");
            var modelPage=new Panel{Dock=DockStyle.Fill};
            qwen=MakeLabel("No local Qwen measurements loaded yet.",new Font("Consolas",11),fg);
            var modelLayout=Rows(50);modelPage.Controls.Add(modelLayout);
            qwen.Dock=DockStyle.Fill;qwen.TextAlign=ContentAlignment.TopLeft;modelLayout.Controls.Add(qwen,0,1);
            var toolbar=new Panel{Dock=DockStyle.Fill};modelLayout.Controls.Add(toolbar,0,0);
            var inspect=new Button{Text="REFRESH QWEN REVIEW",FlatStyle=FlatStyle.Flat,BackColor=panel,ForeColor=fg};inspect.SetBounds(20,8,240,32);toolbar.Controls.Add(inspect);
            inspect.Click+=delegate{LaunchKnownScript("Review-ReflexPerformance.ps1","");};
            help=MakeLabel("Local-only. No prompts, screenshots, window titles or user text are read. CPU excludes short-lived child UIA processes.",new Font("Segoe UI",9),Color.Gray);
            help.Dock=DockStyle.Fill;help.AutoEllipsis=true;outer.Controls.Add(help,0,1);
            var screens=new[]{overview,details,resourcePage,modelPage};
            var sectionNames=new[]{"Benchmark / history","Evidence / decisions","Live resources","Qwen / bottlenecks"};
            var sectionButtons=new List<Button>();
            for(int index=0;index<screens.Length;index++){
                int selected=index;
                var button=new Button{Text=sectionNames[index],AutoSize=true,Height=32,
                    Padding=new Padding(9,0,9,0),FlatStyle=FlatStyle.Flat,BackColor=panel,ForeColor=fg};
                button.Click+=delegate{SelectSection(screens,sectionButtons,selected);};
                sectionButtons.Add(button);
                sectionBar.Controls.Add(button);
                content.Controls.Add(screens[index]);
            }
            SelectSection(screens,sectionButtons,0);
            timer=new System.Windows.Forms.Timer{Interval=800};timer.Tick+=delegate{RefreshAll();};
            VisibleChanged+=delegate{timer.Enabled=Visible;if(Visible)RefreshAll();};
        }
        static TableLayoutPanel Rows(params int[] fixedHeights)
        {
            var layout=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=fixedHeights.Length+1,BackColor=bg};
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
            foreach(int height in fixedHeights)layout.RowStyles.Add(new RowStyle(SizeType.Absolute,height));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent,100));
            return layout;
        }
        static Label MakeLabel(string s,Font font,Color color){return new Label{Text=s,ForeColor=color,BackColor=Color.Transparent,Font=font,AutoEllipsis=true,Padding=new Padding(10)};}
        static DataGridView Grid(){
            var g=new DataGridView{ReadOnly=true,AllowUserToAddRows=false,AllowUserToDeleteRows=false,AllowUserToResizeRows=false,
                RowHeadersVisible=false,SelectionMode=DataGridViewSelectionMode.FullRowSelect,MultiSelect=false,AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill,
                BackgroundColor=bg,GridColor=Color.FromArgb(38,57,45),BorderStyle=BorderStyle.None,EnableHeadersVisualStyles=false};
            g.ColumnHeadersDefaultCellStyle.BackColor=panel;g.ColumnHeadersDefaultCellStyle.ForeColor=accent;
            g.DefaultCellStyle.BackColor=bg;g.DefaultCellStyle.ForeColor=fg;g.DefaultCellStyle.SelectionBackColor=Color.FromArgb(35,83,55);
            g.DefaultCellStyle.SelectionForeColor=Color.White;g.RowTemplate.Height=25;return g;
        }
        void OnBenchmark(object sender,EventArgs e)
        {
            var answer=MessageBox.Show("Run " + n.Value + " measured Windows UIA tasks plus one warmup?\n\n"+
                "Each run opens the ReflexCore test window, fills its input, invokes Apply and verifies output.\n"+
                "It can temporarily take focus. Do not interact with the fixture while testing.\n\n"+
                "No actual mouse clicks or Qwen requests are performed.","Explicit consent: controlled Windows UI",MessageBoxButtons.YesNo,MessageBoxIcon.Question);
            if(answer!=DialogResult.Yes)return;
            LaunchKnownScript("Run-ReflexBenchmark.ps1","-Runs " + (int)n.Value + " -Warmups 1 -AllowVisibleUI");
        }
        void LaunchKnownScript(string filename,string arguments)
        {
            string path=Path.Combine(root,"tools",filename);
            if(!File.Exists(path)){MessageBox.Show("Expected ReflexCore tool not found.");return;}
            string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe");
            var psi=new ProcessStartInfo{FileName=ps,Arguments="-NoProfile -ExecutionPolicy Bypass -File \""+path+"\" "+arguments,WorkingDirectory=root,UseShellExecute=true};
            try{Process.Start(psi);}catch(Exception){MessageBox.Show("Failed to start the known local tool. Check installation.");}
        }
        void RefreshAll()
        {
            pulse++;
            var live=Read.Json(Path.Combine(dir,"progress.json"));
            string step=Read.Str(live,"stage");
            var activity=Read.Json(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ReflexCore","runtime","activity.json"));
            string agent=Read.Str(activity,"stage");
            DateTime activityUtc;
            if(!DateTime.TryParse(Read.Str(activity,"at_utc"),null,System.Globalization.DateTimeStyles.RoundtripKind,out activityUtc) ||
                Math.Abs((DateTime.UtcNow-activityUtc.ToUniversalTime()).TotalSeconds)>65)agent="inactive / stale";
            stage.Text="BENCH  " + (step.Length==0?"idle":step) + "    REFLEX  " + (agent.Length==0?"unknown":agent);
            if(pulse%3==1){RefreshHistory();RefreshModel();}
            RefreshResources();
            if(pulse%6==0 && !gpuBusy)PollGpuAsync();
        }
        void PollGpuAsync()
        {
            gpuBusy=true;
            ThreadPool.QueueUserWorkItem(delegate(object state){
                try{
                    var psi=new ProcessStartInfo{FileName="nvidia-smi.exe",
                        Arguments="--query-gpu=utilization.gpu,memory.used,temperature.gpu,power.draw --format=csv,noheader,nounits",
                        UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true};
                    using(var child=Process.Start(psi)){
                        if(child==null){gpuSummary="GPU: unavailable";return;}
                        if(!child.WaitForExit(1800)){try{child.Kill();}catch{}gpuSummary="GPU: query timed out";return;}
                        var csv=child.StandardOutput.ReadToEnd().Trim().Split(new[]{'\r','\n'},StringSplitOptions.RemoveEmptyEntries);
                        if(csv.Length>0){
                            var parts=csv[0].Split(',');
                            if(parts.Length==4)gpuSummary="GPU total: "+parts[0].Trim()+"% util | "+parts[1].Trim()+" MiB VRAM | "+parts[2].Trim()+" °C | "+parts[3].Trim()+" W";
                        }
                    }
                }catch{gpuSummary="GPU: nvidia-smi not available";}
                finally{gpuBusy=false;}
            });
        }
        // Benchmark storage uses UTC ISO-8601; display only is converted to local system time.
        // Keep a typed DateTime in the grid: text-sorting localized strings gives wrong order.
        internal static DateTime HistoryLocalTime(string utc)
        {
            DateTimeOffset parsed;
            if (!DateTimeOffset.TryParse(utc, System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.None,out parsed))
                return DateTime.MinValue;
            return parsed.ToLocalTime().DateTime;
        }
        void RefreshHistory()
        {
            string path=Path.Combine(dir,"history.jsonl");
            if(!File.Exists(path))return;
            try{
                var info=new FileInfo(path);
                if(info.Length>2097152)return;
                string sig=info.Length+"/"+info.LastWriteTimeUtc.Ticks;
                if(sig==lastHistorySignature)return;
                lastHistorySignature=sig;
                List<Dictionary<string,object>> list=new List<Dictionary<string,object>>();
                string[] lines=File.ReadAllLines(path,Encoding.UTF8);
                foreach(string line in lines.Skip(Math.Max(0,lines.Length-75))){
                    try{var x=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(line);
                        if(Read.Str(x,"schema")=="reflexcore.benchmark.run.v1")list.Add(x);
                    }catch{}
                }
                runs.Rows.Clear(); chart.Values.Clear();
                foreach(var row in list){
                    DateTime local=HistoryLocalTime(Read.Str(row,"started_utc"));
                    int iteration=0;int.TryParse(Read.Str(row,"iteration"),out iteration);
                    int idx=runs.Rows.Add(local,iteration,Read.Bool(row,"success")?"VERIFIED":"FAILED",
                        Read.Num(row,"total_ms"),Read.Num(row,"flow_ms"),
                        Read.Num(row,"process_cpu_ms"),Read.Num(row,"peak_private_mb"),Read.Str(row,"run_id"));
                    runs.Rows[idx].Cells[0].ToolTipText="UTC: "+Read.Str(row,"started_utc");
                    if(Read.Bool(row,"success"))chart.Values.Add(Read.Num(row,"total_ms"));
                }
                // Newest FIRST, independent of how the user last sorted the grid.
                runs.Sort(runs.Columns[0],System.ComponentModel.ListSortDirection.Descending);
                chart.Invalidate();
                var session=Read.Json(Path.Combine(dir,"latest-session.json"));
                if(session!=null)summary.Text="VERIFIED " + Read.Str(session,"success")+"/"+Read.Str(session,"measured_runs")+
                    "   |   p50 " + Read.Str(session,"p50_ms")+" ms   |   p95 " + Read.Str(session,"p95_ms")+
                    " ms   |   MEAN " + Read.Str(session,"mean_ms")+" ms";
                if(runs.Rows.Count>0){runs.ClearSelection();runs.Rows[0].Selected=true;ShowSelected();}
            }catch{}
        }
        void ShowSelected()
        {
            if(runs.SelectedRows.Count==0)return;
            var raw=runs.SelectedRows[0].Cells[7].Value;
            if(raw==null)return;
            string runId=Convert.ToString(raw);
            if(runId==null || runId.Length!=32 || !System.Text.RegularExpressions.Regex.IsMatch(runId,"^[0-9a-f]{32}$"))return;
            if(runId==selectedRun)return;
            selectedRun=runId;
            var row=Read.Json(Path.Combine(dir,"runs",runId+".json"));
            if(row==null)return;
            evidence.Text="Task: fixed Goal Agent -> controlled WinForms input -> Apply -> verified output\r\n"+
                "Outcome="+Read.Str(row,"reason_code")+"; duration="+Read.Str(row,"total_ms")+"ms; flow="+Read.Str(row,"flow_ms")+"ms\r\n"+
                "Root Rust CPU="+Read.Str(row,"process_cpu_ms")+"ms; peak private="+Read.Str(row,"peak_private_mb")+"MB; peak working="+Read.Str(row,"peak_working_mb")+"MB\r\n"+
                "Non-flow time includes Rust startup, planning, fixture startup and other overhead; not pure reasoning.\r\n"+
                "Decision policy: Dijkstra minimum cost over declared skill flows. Evidence = UIA assertions, not model thoughts.";
            trace.Rows.Clear();
            foreach(var part in Read.Array(row,"steps")){
                var x=Read.Map(part);if(x==null)continue;
                trace.Rows.Add(Read.Str(x,"index"),Read.Str(x,"action"),Read.Str(x,"attempts"),Read.Str(x,"status"),
                    Read.Str(x,"verification"),Read.Str(x,"duration_ms"),Read.Str(x,"evidence"));
            }
        }
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        static extern bool GetSystemTimes(out ulong idle, out ulong kernel, out ulong user);
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        struct MemoryStatus {
            internal uint length, load;
            internal ulong total, available, pageTotal, pageFree, virtualTotal, virtualFree, extendedFree;
        }
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
        ulong lastTicks, lastIdle;
        string HostResources()
        {
            ulong idle,kernel,user;
            string cpu = "warming up";
            if (GetSystemTimes(out idle,out kernel,out user)) {
                ulong total = kernel + user;
                if (lastTicks != 0 && total > lastTicks && idle >= lastIdle)
                    cpu = Math.Max(0, 100.0 * (1.0 - (double)(idle-lastIdle)/(total-lastTicks))).ToString("F0") + "%";
                lastTicks = total; lastIdle = idle;
            }
            var m = new MemoryStatus();
            m.length = (uint)System.Runtime.InteropServices.Marshal.SizeOf(typeof(MemoryStatus));
            string ram = GlobalMemoryStatusEx(ref m) ? (m.available/1048576UL) + " MiB available / " + (m.total/1048576UL) + " MiB" : "unavailable";
            return "Host CPU " + cpu + "   |   RAM " + ram;
        }
        void RefreshResources()
        {
            string[] names={"reflexcore","ollama","ollama_llama_server"};
            double seconds=Math.Max(0.1,(DateTime.UtcNow-lastCpu).TotalSeconds);
            lastCpu=DateTime.UtcNow;
            procGrid.Rows.Clear();
            double totalWorking=0;
            foreach(string name in names){
                int count=0;double cpuTotal=0,working=0,priv=0;
                Process[] ps=new Process[0];
                try{ps=Process.GetProcessesByName(name);foreach(Process p in ps){
                        try{count++;cpuTotal+=p.TotalProcessorTime.TotalMilliseconds;working+=p.WorkingSet64/1048576.0;priv+=p.PrivateMemorySize64/1048576.0;}
                        catch{} finally{p.Dispose();}
                    }}catch{};
                double old;double cpu=0;
                if(previousCpu.TryGetValue(name,out old))cpu=Math.Max(0,(cpuTotal-old)/(seconds*1000*Math.Max(1,Environment.ProcessorCount))*100);
                previousCpu[name]=cpuTotal;
                totalWorking+=working;
                procGrid.Rows.Add(name,count,cpu.ToString("F1"),working.ToString("F1"),priv.ToString("F1"));
            }
            resources.Text=HostResources()+"\r\nObserved RAM (named Rust/Ollama processes): "+totalWorking.ToString("F1")+
                " MB  |  CPU normalized to all logical processors.\r\n"+
                gpuSummary+" (whole GPU, not attributable to ReflexCore). PowerShell UIA child CPU and full process tree not measured.";
        }
        string ModelBenchSummary()
        {
            try{
                string path=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ReflexCore","diagnostics","model-bench","latest.json");
                var d=Read.Json(path);if(d==null||Read.Str(d,"schema")!="reflexcore.model.benchmark.v1")return "No fixed Qwen benchmark measured yet.";
                return "Fixed text-only Qwen benchmark (NOT vision/UI): "+Read.Str(d,"success")+"/"+Read.Str(d,"runs")+
                    " verified; p50/p95 "+Read.Str(d,"p50_ms")+"/"+Read.Str(d,"p95_ms")+" ms; model "+Read.Str(d,"model")+
                    "; config "+Read.Str(d,"config_sha256").Substring(0,8);
            }catch{return "Model benchmark report unavailable.";}
        }
        void RefreshModel()
        {
            string file=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ReflexCore","diagnostics","nav-performance.jsonl");
            if(!File.Exists(file)){qwen.Text="QWEN MEASUREMENTS  /  NO RECORDED SAMPLES\r\n\r\n"+
                ModelBenchSummary()+"\r\n\r\n"+
                "Use existing Shared Control with explicit foreground/permission to collect real capture/infer/parse/verify times.\r\n"+
                "The repeatable WinForms benchmark does not call a language model; never interpret its result as Qwen throughput.";return;}
            try{
                var info=new FileInfo(file);if(info.Length>1048576)return;
                string[] lines=File.ReadAllLines(file,Encoding.UTF8);
                Dictionary<string,object> latest=null;
                foreach(string line in lines.Reverse().Take(30)){
                    try {var d=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(line);
                         if(Read.Str(d,"schema")=="reflexcore.input.diagnostic.v1"){latest=d;break;}}catch{}
                }
                if(latest==null)return;
                var review=Read.Json(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ReflexCore","diagnostics","performance-review.json"));
                var metrics=Read.Map(Read.Value(review,"metrics"));
                var infer=Read.Map(Read.Value(metrics,"infer_ms"));
                var total=Read.Map(Read.Value(metrics,"cycle_ms"));
                string aggregate=(infer==null?"No p50/p95 review yet. Press REFRESH QWEN REVIEW.\r\n":
                    "Reviewed inference p50/p95: "+Read.Str(infer,"p50_ms")+" / "+Read.Str(infer,"p95_ms")+" ms (n="+Read.Str(infer,"samples")+")\r\n");
                if(total!=null)aggregate+="Reviewed cycle p50/p95: "+Read.Str(total,"p50_ms")+" / "+Read.Str(total,"p95_ms")+" ms\r\n";
                qwen.Text="QWEN / SHARED CONTROL   ·   MOST RECENT RECORDED CYCLE\r\n\r\n"+
                    "Model          "+Read.Str(latest,"model_id")+"\r\n"+
                    "Ctx / output   "+Read.Str(latest,"model_num_ctx")+" / "+Read.Str(latest,"model_num_predict")+" tokens\r\n"+
                    "Temp / top_p   "+Read.Str(latest,"model_temperature")+" / "+Read.Str(latest,"model_top_p")+"\r\n"+
                    "Decision mode  "+Read.Str(latest,"thinking_mode")+"\r\n"+
                    "Action enum    "+Read.Str(latest,"move")+"\r\n"+
                    "Cycle outcome  "+Read.Str(latest,"outcome")+"\r\n"+
                    "Frame reused   "+Read.Str(latest,"next_frame_reused")+"\r\n"+
                    "Scene change % "+Read.Str(latest,"scene_change_percent")+" (not verified motion)\r\n\r\n"+
                    "Capture        "+Read.Str(latest,"capture_ms")+" ms\r\n"+
                    "Inference      "+Read.Str(latest,"infer_ms")+" ms\r\n"+
                    "Parsing        "+Read.Str(latest,"parse_ms")+" ms\r\n"+
                    "Rust decision  "+Read.Str(latest,"rust_decide_ms")+" ms\r\n"+
                    "Verify capture "+Read.Str(latest,"verify_capture_ms")+" ms\r\n"+
                    "Windows input  "+Read.Str(latest,"input_ms")+" ms\r\n"+
                    "Full cycle     "+Read.Str(latest,"cycle_ms")+" ms\r\n"+
                    "Model load     "+Read.Str(latest,"ollama_load_ms")+" ms\r\n"+
                    "Prompt eval    "+Read.Str(latest,"ollama_prompt_ms")+" ms\r\n"+
                    "Token eval     "+Read.Str(latest,"ollama_eval_ms")+" ms\r\n"+
                    "Prompt tokens  "+Read.Str(latest,"ollama_prompt_tokens")+"\r\n"+
                    "Output tokens  "+Read.Str(latest,"ollama_output_tokens")+"\r\n\r\n"+
                    aggregate+"\r\n"+ModelBenchSummary()+"\r\n\r\nSamples describe individual navigation cycles. Visual scene change is NOT proof of task completion.";
            }catch{}
        }
        public static void SelfTest(string root)
        {
            if(!File.Exists(Path.Combine(root,"Cargo.toml")))throw new Exception("Not an existing ReflexCore root");
            if(!File.Exists(Path.Combine(root,"tools","Run-ReflexBenchmark.ps1")))throw new Exception("Missing benchmark runner");
            var d=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>("{\"schema\":\"reflexcore.benchmark.run.v1\",\"total_ms\":3.5}");
            if(Read.Str(d,"schema")!="reflexcore.benchmark.run.v1" || Read.Num(d,"total_ms")!=3.5)throw new Exception("JSON parsing self-test failed");
            DateTime utc=HistoryLocalTime("2026-11-21T02:05:14.0000000Z");
            if(utc.ToUniversalTime()!=new DateTime(2026,11,21,2,5,14,DateTimeKind.Utc))
                throw new Exception("UTC/local timestamp conversion regression");
            Console.WriteLine("[ReflexCore] Measurement Lab C# compiled and JSON self-test passed. No UI opened.");
        }
        [STAThread]
        public static void Run(string root)
        {
            Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new Dashboard(root));
        }
    }
}
