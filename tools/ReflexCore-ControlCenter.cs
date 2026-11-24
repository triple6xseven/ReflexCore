using System;
using System.IO;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using System.Text;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using System.Net;
using System.Threading;

namespace ReflexCore.Control
{
    public static class Center
    {
        public static void SelfTest(string root)
        {
            if(!File.Exists(Path.Combine(root,"Cargo.toml")))throw new Exception("Cargo.toml missing");
            if(!File.Exists(Path.Combine(root,"tools","ReflexGame-Server.ps1")))throw new Exception("Game server missing");
            Console.WriteLine("[ReflexCore] Control Center C# compiled and self-test passed.");
        }
        public static void Smoke(string root)
        {
            Application.EnableVisualStyles();
            string fixture=Path.Combine(Path.GetTempPath(),"ReflexCore-StudioQueue-"+Guid.NewGuid().ToString("N"));
            var tasks=Directory.CreateDirectory(Path.Combine(fixture,"tasks"));
            try{
                foreach(string task in new[]{"agent-demo","notepad-save","notepad-visual","verify-handoff"})
                    File.WriteAllText(Path.Combine(tasks.FullName,task+".ps1"),"");
                using(var form=new Dashboard(root,"Agent",new ReflexCore.Bridge.QueueStore(fixture)))form.ShowStudio(true);
            }finally{Directory.Delete(fixture,true);}
            Console.WriteLine("[ReflexCore] Studio passed: queue submission, approval and cancellation, six live pages, 45 themes and compact navigation.");
        }
        [STAThread]
        public static void Run(string root,string initialTab)
        {
            bool first;
            using(var mutex=new Mutex(true,@"Local\ReflexCoreControlCenter",out first))
            {
                if(!first)
                {
                    // Request a tab switch in the EXISTING control center instead of opening a duplicate window.
                    string request=Path.Combine(root,"data","bridge","ui-request.txt");
                    Directory.CreateDirectory(Path.GetDirectoryName(request));
                    File.WriteAllText(request,initialTab=="Models"?"Models":initialTab=="Diagnostics"?"Diagnostics":"Agent");
                    return;
                }
                Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
                using(var controller=new Dashboard(Path.GetFullPath(root),initialTab))controller.ShowStudio(false);
            }
        }
    }

    internal sealed class QueueListView : ListView
    {
        [System.Runtime.InteropServices.DllImport("uxtheme.dll",CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
        private static extern int SetWindowTheme(IntPtr window,string theme,string subId);
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr window,int message,IntPtr wParam,IntPtr lParam);
        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            ApplyNativeTheme();
            FillLastColumn();
        }
        protected override void OnSizeChanged(EventArgs e)
        {
            base.OnSizeChanged(e);
            FillLastColumn();
        }
        protected override void OnColumnWidthChanged(ColumnWidthChangedEventArgs e)
        {
            base.OnColumnWidthChanged(e);
            FillLastColumn();
        }
        internal void FillLastColumn()
        {
            if(!IsHandleCreated || Columns.Count<2)return;
            int last=Columns.Count-1;
            int remaining=ClientSize.Width;
            for(int i=0;i<last;i++)remaining-=Columns[i].Width;
            if(remaining>0 && Columns[last].Width!=remaining)Columns[last].Width=remaining;
        }
        protected override void OnBackColorChanged(EventArgs e)
        {
            base.OnBackColorChanged(e);
            if(IsHandleCreated)ApplyNativeTheme();
        }
        private void ApplyNativeTheme()
        {
            string theme=BackColor.GetBrightness()<.5f?"DarkMode_Explorer":"Explorer";
            SetWindowTheme(Handle,theme,null);
            var header=SendMessage(Handle,0x101f,IntPtr.Zero,IntPtr.Zero);
            if(header!=IntPtr.Zero)SetWindowTheme(header,theme,null);
        }
    }
    internal class Dashboard : Form
    {
        readonly string root;
        readonly Label bridgeText, serverText, modelText, apiTestText;
        readonly ReflexTabHost pages;
        readonly ReflexCore.Bridge.QueueStore queue;
        readonly Action refreshQueue;
        ReflexCore.Studio.StudioWindow studio;
        internal void ShowStudio(bool test)
        {
            pages.Parent=null;
            studio=new ReflexCore.Studio.StudioWindow(pages,ReflexThemeCatalog.Load().Name,
                delegate(string name){ReflexThemeCatalog.Save(ReflexThemeCatalog.Find(name));},
                delegate{WriteControl("stop");},ShellModernizer.CurrentStage,root);
            Exception failure=null;
            if(test)studio.ContentRendered+=delegate{
                try{VerifyQueueControls();studio.VerifyView();}
                catch(Exception ex){failure=ex;}
                finally{studio.Close();}
            };
            try{studio.ShowDialog();}finally{studio=null;pages.Dispose();}
            if(failure!=null)throw new InvalidOperationException("Studio acceptance failed",failure);
        }
        int apiTestBusy=0;
        readonly TextBox keyInput, modelInput;
        readonly System.Windows.Forms.Timer timer;
        readonly Color bg=Color.FromArgb(10,18,22),surface=Color.FromArgb(16,32,33),text=Color.FromArgb(223,246,227),muted=Color.FromArgb(122,164,148),accent=Color.FromArgb(171,255,101);
        string serverStatus="unknown";
        public Dashboard(string project,string initialTab):this(project,initialTab,null){}
        public Dashboard(string project,string initialTab,ReflexCore.Bridge.QueueStore testQueue)
        {
            queue=testQueue ?? new ReflexCore.Bridge.QueueStore(project);
            root=project;Text="REFLEXCORE // CONTROL CENTER";Width=1210;Height=825;MinimumSize=new Size(900,680);StartPosition=FormStartPosition.CenterScreen;
            BackColor=bg;ForeColor=text;Font=new Font("Segoe UI",10);ShowInTaskbar=true;
            string ico=Path.Combine(root,"assets","reflexcore.ico");if(File.Exists(ico)){try{Icon=new Icon(ico);}catch{}}
            var header=new Panel{Dock=DockStyle.Top,Height=98,BackColor=surface};Controls.Add(header);
            var title=new Label{Text="◈  REFLEXCORE",Font=new Font("Consolas",26,FontStyle.Bold),ForeColor=accent,Location=new Point(26,17),AutoSize=true};header.Controls.Add(title);
            header.Controls.Add(new Label{Text="LOCAL AGENT · DEV BRIDGE · GAME LAB",Font=new Font("Consolas",10),ForeColor=muted,Location=new Point(30,66),AutoSize=true});
            var tabs=pages=new ReflexTabHost{Dock=DockStyle.Fill};Controls.Add(tabs);tabs.BringToFront();
            var agent=Page("AGENT",tabs);
            var modelsTab=Page("MODELS",tabs);
            var diagnosticsTab=Page("DIAGNOSTICS",tabs);
            var shared=Page("SHARED CONTROL",tabs);
            var game=Page("CITADEL LAB",tabs);
            var ai=Page("OPENAI API",tabs);
            // Preserve existing functional pages, replace only the window shell.
            // The WPF window hosts these six live WinForms pages in one process.
            modelsTab.Controls.Add(new ModelPanel(root));
            // Embed the original 0.6.1 Measurement Lab without opening an overlapping top-level window.
            var diagnosticView=new ReflexCore.Diagnostics.Dashboard(root){TopLevel=false,MinimumSize=Size.Empty,FormBorderStyle=FormBorderStyle.None,Dock=DockStyle.Fill,ShowInTaskbar=false};
            diagnosticsTab.Controls.Add(diagnosticView);
            tabs.SelectedIndexChanged+=(sender,args)=>{if(tabs.SelectedTab==diagnosticsTab)diagnosticView.Show();};
            diagnosticsTab.Enter+=(sender,args)=>{if(!diagnosticView.Visible)diagnosticView.Show();};
            if(initialTab=="Models")tabs.SelectedTab=modelsTab;
            else if(initialTab=="Diagnostics")tabs.SelectedTab=diagnosticsTab;
            else tabs.SelectedTab=agent;
            if(tabs.SelectedTab==diagnosticsTab)diagnosticView.Show();
            bridgeText=Info("Bridge: waiting",18,20,680);
            bridgeText.Height=32;
            agent.Controls.Add(bridgeText);
            AddButton(agent,"RUN AGENT DEMO",18,68,222,38,()=>RunTask("agent-demo"),true);
            AddButton(agent,"NOTEPAD · CREATE FILE",250,68,237,38,()=>RunTask("notepad-save"),false);
            AddButton(agent,"NOTEPAD · CHECK WITH MODEL",497,68,270,38,()=>RunTask("notepad-visual"),false);
            agent.Controls.Add(Header("Task queue",18,131));
            AddButton(agent,"VERIFY A HANDOFF FOLDER",497,122,270,34,SelectHandoff,false);
            var jobs=new QueueListView{View=View.Details,FullRowSelect=true,MultiSelect=false,HideSelection=false,
                OwnerDraw=true,BorderStyle=BorderStyle.None,
                Location=new Point(18,168),Size=new Size(748,215),AccessibleName="Task queue"};
            var selectionColor=Color.FromArgb(75,51,92);
            jobs.Tag=new Action<Color,Color,Color>((card,ink,highlight)=>{
                selectionColor=Color.FromArgb((card.R*3+highlight.R)/4,(card.G*3+highlight.G)/4,(card.B*3+highlight.B)/4);
                jobs.Invalidate();
            });
            jobs.DrawColumnHeader+=(sender,args)=>{
                using(var brush=new SolidBrush(jobs.BackColor))args.Graphics.FillRectangle(brush,args.Bounds);
                TextRenderer.DrawText(args.Graphics,args.Header.Text,jobs.Font,Rectangle.Inflate(args.Bounds,-7,0),
                    jobs.ForeColor,TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis);
            };
            jobs.DrawSubItem+=(sender,args)=>{
                var rowColor=args.Item.Selected?selectionColor:jobs.BackColor;
                using(var brush=new SolidBrush(rowColor))args.Graphics.FillRectangle(brush,args.Bounds);
                var cellBounds=Rectangle.Inflate(args.Bounds,-5,0);
                TextRenderer.DrawText(args.Graphics,args.SubItem.Text,jobs.Font,cellBounds,jobs.ForeColor,
                    TextFormatFlags.NoPrefix|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis|TextFormatFlags.SingleLine);
            };
            jobs.ContextMenuStrip=new ContextMenuStrip();
            jobs.ContextMenuStrip.ShowImageMargin=false;
            jobs.MouseDown+=(sender,args)=>{
                if(args.Button!=MouseButtons.Right)return;
                var row=jobs.GetItemAt(args.X,args.Y);
                jobs.SelectedItems.Clear();
                if(row!=null){row.Selected=true;row.Focused=true;}
            };
            jobs.ContextMenuStrip.Items.Add("Open project folder",null,(sender,args)=>Process.Start("explorer.exe",root));
            jobs.ContextMenuStrip.Items.Add("Refresh queue",null,(sender,args)=>{UpdateStatus();refreshQueue();});
            jobs.Columns.Add("Local time",180);jobs.Columns.Add("Task",235);jobs.Columns.Add("Status",290);
            agent.Controls.Add(jobs);
            var notice=Info("No jobs yet. Choose a task above to get started.",18,437,748);
            agent.Controls.Add(notice);
            Func<ReflexCore.Bridge.QueueEntry> completedSelection=()=>{
                if(jobs.SelectedItems.Count==0)return null;
                string selectedId=(string)jobs.SelectedItems[0].Tag;
                return queue.Snapshot().FirstOrDefault(row=>row.Id==selectedId && row.State!="pending" && row.State!="running");
            };
            var erase=jobs.ContextMenuStrip.Items.Add("Delete selected history entry",null,(sender,args)=>{
                try{
                    var entry=completedSelection();
                    if(entry==null || !queue.DeleteHistory(entry.Id,entry.State))return;
                    refreshQueue();
                    notice.Text="History entry deleted.";
                }catch(IOException){notice.Text="Could not delete the history entry.";}
                 catch(UnauthorizedAccessException){notice.Text="Could not delete the history entry.";}
            });
            jobs.ContextMenuStrip.Opening+=delegate{
                jobs.ContextMenuStrip.Renderer=new ReflexCore.Presentation.DarkMenuRenderer(
                    jobs.BackColor,selectionColor,selectionColor,jobs.ForeColor);
                erase.Enabled=completedSelection()!=null;
            };
            Action<string> command=delegate(string action){
                if(jobs.SelectedItems.Count==0){notice.Text="Select a task in the queue.";return;}
                string id=(string)jobs.SelectedItems[0].Tag;
                notice.Text=queue.Request(id,action)?"Request sent to the task supervisor.":"The task status has changed.";
            };
            AddButton(agent,"CANCEL SELECTED",18,395,182,32,()=>command("cancel"),false);
            AddButton(agent,"APPROVE SELECTED",211,395,182,32,()=>command("approve"),false);
            string lastSnapshot=null;
            var taskTimer=new System.Windows.Forms.Timer{Interval=900};
            refreshQueue=delegate {
                if(!jobs.Visible)return;
                try{
                    var rows=queue.Snapshot();
                    string signature=String.Join("|",rows.Select(row=>row.Id+"/"+row.State+"/"+row.Verification+"/"+row.Reason).ToArray());
                    if(signature==lastSnapshot)return;
                    string selected=jobs.SelectedItems.Count>0?(string)jobs.SelectedItems[0].Tag:"";
                    string topId=jobs.TopItem==null?null:(string)jobs.TopItem.Tag;
                    ListViewItem topRow=null;
                    jobs.BeginUpdate();
                    try{
                        jobs.Items.Clear();
                        foreach(var row in rows){
                            DateTime created;
                            string hour=DateTime.TryParseExact(row.Id.Substring(0,17),"yyyyMMddHHmmssfff",
                                System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.AssumeUniversal|System.Globalization.DateTimeStyles.AdjustToUniversal,out created)
                                ?created.ToLocalTime().ToString("dd.MM HH:mm:ss"):"—";
                            string task=row.Task=="uia"?"UI Automation":row.Task=="notepad"?"Notepad":row.Task=="visual"?"Notepad + model":row.Task=="handoff"?"Verify a handoff folder":"Local task";
                            string state=row.State=="pending"?"Pending":row.State=="running"?"Running":
                                row.State=="stopping"?"Stopping":row.State=="completed"?(row.Verification=="verified"?"Verified":"Finished without verification"):
                                row.State=="cancelled"?(row.Verification=="unknown"?"Cancelled · effect unknown":"Cancelled"):
                                row.State=="interrupted"?"Interrupted":row.Reason=="focus_lost"?"Failed · focus lost":"Failed";
                            var entry=new ListViewItem(new[]{hour,task,state});entry.Tag=row.Id;jobs.Items.Add(entry);
                            if(row.Id==selected)entry.Selected=true;
                            if(row.Id==topId)topRow=entry;
                        }
                        if(topRow!=null)jobs.TopItem=topRow;
                        lastSnapshot=signature;
                        notice.Text=rows.Count==0?"No jobs yet. Choose a task above to get started.":
                            "Select a pending task to approve or cancel it.";
                    }finally{jobs.EndUpdate();}
                    jobs.FillLastColumn();
                }catch(IOException){notice.Text="Refreshing the task queue.";}
            };
            taskTimer.Tick+=delegate{refreshQueue();};
            taskTimer.Start();Disposed+=delegate{taskTimer.Dispose();};

            game.Controls.Add(Header("REFLEX CITADEL // AKVARIUM 3D ARENA",18,22));
            serverText=Info("SERVER: checking",18,63,725);game.Controls.Add(serverText);
            AddButton(game,"▶ OPEN AI ARENA IN CHROME",18,125,420,53,()=>OpenGame(),true);
            AddButton(game,"START SERVER",462,125,305,53,()=>StartServer(),false);
            AddButton(game,"STOP SERVER",18,199,420,47,()=>StopServer(),false);
            AddButton(game,"OPEN GAME SOURCE",462,199,305,47,()=>Process.Start("explorer.exe",Path.Combine(root,"sandbox","citadel-zero")),false);
            game.Controls.Add(Info("Akvarium 3D offers three missions. Run the agent in Chrome or as a headless Node.js process.",18,285,755));
            game.Controls.Add(Info("Choose an agent mode and the 3D or 2D camera in the game, then start the agent. API calls require a separate action.",18,360,755));

            // DPI-aware API tab. Controls flow vertically and scroll; no absolute Y positions.
            shared.Controls.Add(Header("SHARED CONTROL // CS 1.6 OFFLINE",18,23));
            shared.Controls.Add(Info("Shared Control sends mouse and keyboard input to the local game. Physical input pauses the agent for three seconds. Use a private local server.",18,73,750));
            AddButton(shared,"▶ OPEN CS 1.6 SHARED CONTROL LAB",18,160,746,54,()=>OpenSharedControl(),true);
            AddButton(shared,"SHOW REFLEXVISION",18,385,235,50,()=>OpenOfflineTool("ReflexCore-ReflexVision.ps1",""),true);
            AddButton(shared,"CLOSE REFLEXVISION",268,385,235,50,()=>OpenOfflineTool("ReflexCore-ReflexVision.ps1","-Action Stop"),false);
            AddButton(shared,"OPEN OFFLINE PLANT DRILL",518,385,246,50,()=>OpenOfflineTool("ReflexCore-CS16Practice.ps1",""),false);
            AddButton(shared,"PLAY OFFLINE MATCH",18,450,746,50,()=>OpenOfflineTool("ReflexCore-CS16Practice.ps1","-AutoStart -Match"),true);
            shared.Controls.Add(Info("Play Offline Match tracks the kill, plant and round result. ReflexVision shows purple tracks beside the windowed game.",18,517,748));
            AddButton(shared,"OPEN MATCH RECORDINGS",18,580,365,42,()=>{
                string folder=Path.Combine(root,"data","replays","cs16");
                Directory.CreateDirectory(folder);
                Process.Start("explorer.exe","\""+folder+"\"");
            },false);
            shared.Controls.Add(Info("Start a local CS 1.6 game, join the Terrorists and obtain C4. Use the Plant C4 drill at a bombsite or record a demonstration.",18,244,750));
            shared.Controls.Add(Info("Press F12 or Ctrl+Alt+P to stop. The controller uses public game signals and a limited set of inputs. Recordings capture local game controls.",18,336,750));
            var apiFlow=new FlowLayoutPanel{Dock=DockStyle.Fill,AutoScroll=true,FlowDirection=FlowDirection.TopDown,
                WrapContents=false,BackColor=bg,Padding=new Padding(18,18,18,20)};
            ai.Controls.Add(apiFlow);
            apiFlow.Controls.Add(ApiLabel("OPENAI RESPONSES API",34,true));
            modelText=ApiLabel("API KEY: checking...",36,false);apiFlow.Controls.Add(modelText);
            apiFlow.Controls.Add(ApiLabel("API key (hidden input, protected by Windows DPAPI)",29,false));
            keyInput=new TextBox{Height=29,Width=710,PasswordChar='●',BackColor=Color.FromArgb(24,40,42),
                ForeColor=text,BorderStyle=BorderStyle.FixedSingle,Margin=new Padding(0,0,0,15)};
            apiFlow.Controls.Add(keyInput);
            var keyButtons=new FlowLayoutPanel{Height=55,Width=740,FlowDirection=FlowDirection.LeftToRight,WrapContents=false,Margin=new Padding(0,0,0,16)};
            apiFlow.Controls.Add(keyButtons);
            AddButton(keyButtons,"SAVE API KEY",0,0,350,44,SaveKey,true);
            AddButton(keyButtons,"DELETE KEY",362,0,335,44,DeleteKey,false);
            apiFlow.Controls.Add(ApiLabel("Model ID (for example, gpt-4.1-mini)",29,false));
            var modelRow=new FlowLayoutPanel{Height=55,Width=740,FlowDirection=FlowDirection.LeftToRight,WrapContents=false,Margin=new Padding(0,0,0,15)};
            apiFlow.Controls.Add(modelRow);
            modelInput=new TextBox{Width=465,Height=31,Text=LoadModel(),BackColor=Color.FromArgb(24,40,42),
                ForeColor=text,BorderStyle=BorderStyle.FixedSingle,Margin=new Padding(0,7,10,0)};
            modelRow.Controls.Add(modelInput);
            AddButton(modelRow,"SAVE MODEL",0,0,225,43,SaveModel,false);
            apiFlow.Controls.Add(ApiLabel("The test makes one OpenAI API request and may incur a separate charge.",43,false));
            var testRow=new FlowLayoutPanel{Height=52,Width=740,Margin=new Padding(0,0,0,4)};
            apiFlow.Controls.Add(testRow);
            AddButton(testRow,"TEST API CONNECTION",0,0,350,44,TestApiConnection,true);
            apiTestText=ApiLabel("API connection untested.",57,false);
            apiFlow.Controls.Add(apiTestText);
            apiFlow.Controls.Add(ApiLabel("The key is stored locally in data/secrets/*.dpapi. The server sends it directly to OpenAI over HTTPS.",70,false));
            apiFlow.Controls.Add(ApiLabel("For autonomous arena matches in Chrome, choose Visible, then OpenAI. The arena shows when it switches to the local fallback.",64,false));
            // Keep scroll area flexible on compact / high-DPI Windows screens.
            apiFlow.Resize+=(sender,args)=>{
                int w=Math.Max(300,apiFlow.ClientSize.Width-48);
                foreach(System.Windows.Forms.Control child in apiFlow.Controls){
                    if(child==keyButtons||child==modelRow||child==testRow)child.Width=Math.Min(740,w);
                    else child.Width=Math.Min(710,w);
                }
                keyInput.Width=Math.Min(710,w);
            };
            timer=new System.Windows.Forms.Timer();timer.Interval=950;
            timer.Tick+=(sender,args)=>{
                string lifecycle=Path.Combine(root,"data","bridge","ui-lifecycle.txt");
                if(studio!=null && testQueue==null && File.Exists(lifecycle))
                {
                    try{
                        bool close=DateTime.UtcNow-File.GetLastWriteTimeUtc(lifecycle)<TimeSpan.FromSeconds(6) &&
                            File.ReadAllText(lifecycle).Trim()=="exit";
                        File.Delete(lifecycle);
                        if(close){studio.Close();return;}
                    }catch(IOException){} catch(UnauthorizedAccessException){}
                }
                UpdateStatus();
                // Strict enum request, no command execution. Brings existing UI forward on repeated launch.
                string request=Path.Combine(root,"data","bridge","ui-request.txt");
                if(File.Exists(request)){
                    try{
                        string target=File.ReadAllText(request).Trim();File.Delete(request);
                        if(target=="Models")tabs.SelectedTab=modelsTab;
                        else if(target=="Diagnostics")tabs.SelectedTab=diagnosticsTab;
                        else if(target=="Agent")tabs.SelectedTab=agent;
                        if(tabs.SelectedTab==diagnosticsTab && !diagnosticView.Visible)diagnosticView.Show();
                        if(studio!=null && (target=="Agent" || target=="Models" || target=="Diagnostics"))studio.RestorePage(tabs.SelectedIndex);
                    }catch{}
                }
            };timer.Start();Disposed+=delegate{timer.Dispose();};UpdateStatus();
        }
        Label ApiLabel(string value,int height,bool heading)
        {
            return new Label{Text=value,Height=height,Width=710,AutoSize=false,
                ForeColor=heading?accent:muted,
                Font=new Font(heading?"Consolas":"Segoe UI",heading?16:10,heading?FontStyle.Bold:FontStyle.Regular),
                Margin=new Padding(0,0,0,9)};
        }
        void TestApiConnection()
        {
            if(!File.Exists(Path.Combine(root,"data","secrets","openai_key.dpapi")))
                throw new Exception("Save an API key first.");
            if(MessageBox.Show("Send one billable API request containing a small game map?\n\nThe API key stays out of the display and log.",
                "ReflexCore / API test",MessageBoxButtons.YesNo,MessageBoxIcon.Question)!=DialogResult.Yes)return;
            if(Interlocked.CompareExchange(ref apiTestBusy,1,0)!=0)return;
            apiTestText.Text="Sending one OpenAI API test request…";
            ThreadPool.QueueUserWorkItem(delegate(object unused){
                string result;
                try
                {
                    if(!IsServerUp())throw new Exception("The local Citadel server is unavailable. Start it from Citadel Lab.");
                    var req=(HttpWebRequest)WebRequest.Create("http://127.0.0.1:39771/api/plan");
                    req.Method="POST";req.ContentType="application/json";req.Timeout=45000;req.ReadWriteTimeout=45000;
                    req.Headers["Origin"]="http://127.0.0.1:39771";
                    string payload="{\"mission\":\"destroy-core\",\"instructions\":\"Connectivity test. Return a short valid game strategy.\",\"state\":{\"mission\":\"destroy-core\",\"budget\":260,\"buildings\":[{\"type\":\"core\",\"hp\":480},{\"type\":\"tower\",\"hp\":160}]}}";
                    byte[] body=Encoding.UTF8.GetBytes(payload);req.ContentLength=body.Length;
                    using(var stream=req.GetRequestStream())stream.Write(body,0,body.Length);
                    string reply;
                    using(var response=(HttpWebResponse)req.GetResponse())
                    using(var rd=new StreamReader(response.GetResponseStream()))reply=rd.ReadToEnd();
                    if(!Regex.IsMatch(reply,"\"ok\"\\s*:\\s*true") || !Regex.IsMatch(reply,"\"plan\"\\s*:"))
                        throw new Exception("The server received a response without a confirmed OpenAI plan. Check the model, API key, and billing.");
                    result="API request succeeded. Review the returned plan in Citadel.";
                }
                catch(WebException ex){result="API ERROR — "+(ex.Response is HttpWebResponse ? "HTTP "+(int)((HttpWebResponse)ex.Response).StatusCode : "network error")+". Check the API key, model, and billing.";}
                catch(Exception ex){result="API ERROR — "+ex.Message;}
                finally{Interlocked.Exchange(ref apiTestBusy,0);}
                try{if(!IsDisposed&&IsHandleCreated)BeginInvoke((Action)(()=>{apiTestText.Text=result;}));}catch{}
            });
        }
        TabPage Page(string name,TabControl tabs){var p=new TabPage(name){BackColor=bg,ForeColor=text,AutoScroll=true};tabs.TabPages.Add(p);return p;}
        Label Header(string value,int x,int y){return new Label{Text=value,Font=new Font("Consolas",17,FontStyle.Bold),ForeColor=accent,Location=new Point(x,y),AutoSize=true};}
        Label Info(string value,int x,int y,int width){return new Label{Text=value,Location=new Point(x,y),Width=width,Height=62,ForeColor=muted,Font=new Font("Segoe UI",10),AutoSize=false};}
        void AddButton(System.Windows.Forms.Control parent,string caption,int x,int y,int w,int h,Action action,bool prominent)
        {
            var b=new Button{Text=caption,Location=new Point(x,y),Size=new Size(w,h),FlatStyle=FlatStyle.Flat,Font=new Font("Segoe UI",10,FontStyle.Bold),BackColor=prominent?Color.FromArgb(36,72,48):surface,ForeColor=prominent?accent:text};
            b.FlatAppearance.BorderColor=prominent?accent:Color.FromArgb(49,90,80);
            b.Click+=(s,e)=>{try{action();}catch(Exception exc){MessageBox.Show(exc.Message,"ReflexCore",MessageBoxButtons.OK,MessageBoxIcon.Warning);}};
            parent.Controls.Add(b);
        }
        void UpdateStatus()
        {
            try
            {
                var path=Path.Combine(root,"data","bridge","status.json");string state="offline",jobs="?";
                if(File.Exists(path)){string s=File.ReadAllText(path);var m=Regex.Match(s,"\\\"state\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"");if(m.Success)state=m.Groups[1].Value;var p=Regex.Match(s,"\\\"pending\\\"\\s*:\\s*(\\d+)");if(p.Success)jobs=p.Groups[1].Value;}
                bridgeText.Text="BRIDGE: "+state.ToUpperInvariant()+"       PENDING: "+jobs+"       HOTKEY: Ctrl+Alt+P";
                serverStatus=File.Exists(Path.Combine(root,"data","bridge","citadel-server.json"))?File.ReadAllText(Path.Combine(root,"data","bridge","citadel-server.json")):"";
                serverText.Text="CITADEL SERVER: "+(serverStatus.Contains("\"running\"")?"RUNNING  127.0.0.1:39771":"STOPPED");
                modelText.Text="API KEY: "+(File.Exists(Path.Combine(root,"data","secrets","openai_key.dpapi"))?"CONFIGURED / DPAPI":"NOT CONFIGURED / LOCAL MODE");
            }catch{}
        }
        string PowerShellExe(){return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe");}
        void OpenOfflineTool(string file,string arguments)
        {
            string path=Path.Combine(root,"tools",file);
            if(!File.Exists(path))throw new IOException("The selected offline tool is unavailable.");
            var settings=new ProcessStartInfo {
                FileName=PowerShellExe(),
                Arguments="-NoProfile -STA -ExecutionPolicy Bypass -File \""+path+"\" "+arguments,
                WorkingDirectory=root,UseShellExecute=false,CreateNoWindow=true,
                RedirectStandardError=true,RedirectStandardOutput=true
            };
            ThreadPool.QueueUserWorkItem(delegate {
                bool failed;
                try{
                    using(var child=Process.Start(settings)){
                        child.BeginErrorReadLine();
                        child.BeginOutputReadLine();
                        child.WaitForExit();
                        failed=child.ExitCode!=0;
                    }
                }catch{failed=true;}
                if(failed && !IsDisposed && IsHandleCreated){
                    try{BeginInvoke((Action)delegate {
                        MessageBox.Show("Could not start the offline tool. Open a windowed local CS 1.6 match for ReflexVision, or check the local practice setup.",
                            "ReflexCore",MessageBoxButtons.OK,MessageBoxIcon.Warning);
                    });}catch(InvalidOperationException){}
                }
            });
        }
        void StartServer()
        {
            if(IsServerUp())return;
            string script=Path.Combine(root,"tools","ReflexGame-Server.ps1");
            var psi=new ProcessStartInfo{FileName=PowerShellExe(),Arguments="-NoLogo -NoProfile -ExecutionPolicy Bypass -File \""+script+"\"",WorkingDirectory=root,UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden};
            Process.Start(psi);for(int i=0;i<25;i++){Thread.Sleep(120);if(IsServerUp())break;}
            if(!IsServerUp())throw new Exception("Game server failed to start. Check data/bridge/citadel-startup-error.txt");
            UpdateStatus();
        }
        bool IsServerUp()
        {
            try{var req=(HttpWebRequest)WebRequest.Create("http://127.0.0.1:39771/health");req.Timeout=350;using(var response=(HttpWebResponse)req.GetResponse())return response.StatusCode==HttpStatusCode.OK;}catch{return false;}
        }
        void StopServer()
        {
            if(!IsServerUp())return;
            string f=Path.Combine(root,"data","bridge","citadel-stop.flag");File.WriteAllText(f,"stop");
            try{var req=(HttpWebRequest)WebRequest.Create("http://127.0.0.1:39771/health");req.Timeout=700;using(var r=req.GetResponse()){} }catch{}
            Thread.Sleep(350);UpdateStatus();
        }
        void OpenSharedControl()
        {
            string script=Path.Combine(root,"tools","ReflexCore-SharedControl.ps1");
            if(!File.Exists(script))throw new Exception("Shared Control module is not installed.");
            var psi=new ProcessStartInfo{FileName=PowerShellExe(),Arguments="-NoLogo -NoProfile -ExecutionPolicy Bypass -File \""+script+"\"",WorkingDirectory=root,UseShellExecute=false,CreateNoWindow=true};
            Process.Start(psi);
        }
        void OpenGame()
        {
            StartServer();string chrome="";
            foreach(string path in new string[]{Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),@"Google\Chrome\Application\chrome.exe"),Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),@"Google\Chrome\Application\chrome.exe"),Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),@"Google\Chrome\Application\chrome.exe")}){if(File.Exists(path)){chrome=path;break;}}
            if(chrome.Length==0){object p=Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe","",null);if(p!=null&&File.Exists(Convert.ToString(p)))chrome=Convert.ToString(p);}
            if(chrome.Length>0)Process.Start(chrome,"http://127.0.0.1:39771/");
            else Process.Start("http://127.0.0.1:39771/");
        }
        void WriteControl(string code)
        {
            if(code=="stop"){
                string runtimeDir=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ReflexCore","runtime");
                Directory.CreateDirectory(runtimeDir);
                File.WriteAllText(Path.Combine(runtimeDir,"vision-stop.signal"),DateTime.UtcNow.ToString("o"));
            }
            var dir=Path.Combine(root,"data","bridge");Directory.CreateDirectory(dir);File.WriteAllText(Path.Combine(dir,"control.txt"),code);
        }
        void SelectHandoff()
        {
            using(var folder=new FolderBrowserDialog { Description="Select the local handoff folder" })
            using(var list=new System.Windows.Forms.OpenFileDialog { Title="Choose a checklist or type a new checklist filename", Filter="JSON checklist|*.json", CheckFileExists=false, DefaultExt="json" })
            using(var output=new System.Windows.Forms.SaveFileDialog { Title="Choose a new report file", Filter="JSON report|*.json", FileName="handoff-report.json", OverwritePrompt=false })
            {
                try{
                    if(folder.ShowDialog(this)!=DialogResult.OK || list.ShowDialog(this)!=DialogResult.OK)return;
                    if(!File.Exists(list.FileName) && !CreateHandoffChecklist(list.FileName))return;
                    if(output.ShowDialog(this)!=DialogResult.OK)return;
                    if(File.Exists(output.FileName)){MessageBox.Show(this,"Choose a new report filename. This file already exists.");return;}
                    queue.SubmitHandoff(folder.SelectedPath,list.FileName,output.FileName);
                    refreshQueue();
                }catch(IOException){MessageBox.Show(this,"Could not save the checklist or submit the task.");}
                 catch(UnauthorizedAccessException){MessageBox.Show(this,"Access was denied. Choose a writable location.");}
            }
        }
        bool CreateHandoffChecklist(string path)
        {
            using(var form=new Form{Text="Create handoff checklist",StartPosition=FormStartPosition.CenterParent,ClientSize=new Size(560,460),
                BackColor=BackColor,ForeColor=ForeColor,MinimizeBox=false,MaximizeBox=false}){
                var hint=new Label{Dock=DockStyle.Top,Height=46,Text="Enter one relative file path per line. For a checksum, append | followed by the SHA-256 value."};
                var entries=new TextBox{Multiline=true,Dock=DockStyle.Fill,ScrollBars=ScrollBars.Vertical,AcceptsReturn=true};
                var save=new Button{Text="Save checklist",Dock=DockStyle.Bottom,Height=36,DialogResult=DialogResult.OK};
                var description = new TextBox { Dock=DockStyle.Top, Multiline=true, Height=56, MaxLength=8192 };
                var prompt = new Label { Dock=DockStyle.Top, Height=34,
                    Text="Optional: describe what to check. Example: Check README.md and docs/install.pdf." };
                description.AccessibleName = "Describe what to check";
                entries.AccessibleName = "Review checklist entries";
                var draftButton = new Button { Dock=DockStyle.Top, Height=32, Text="Build checklist from text" };
                var status = new Label { Dock=DockStyle.Top, Height=40 };
                draftButton.Click += delegate {
                    string[] draft;
                    var result = HandoffDraft.Build(description.Text, out draft);
                    if (result != HandoffDraftState.Draft) {
                        status.Text = result == HandoffDraftState.OutsideScope
                            ? "Use only relative file paths inside the selected folder."
                            : "Specify the exact filenames. Quote names with spaces and attach each SHA-256 to its file.";
                        return;
                    }
                    if (!String.IsNullOrWhiteSpace(entries.Text) &&
                        MessageBox.Show(form,"Replace the entries in the editor?","Build checklist from text",
                            MessageBoxButtons.YesNo,MessageBoxIcon.Question) != DialogResult.Yes) return;
                    entries.Lines = draft;
                    status.Text = "Review or edit the draft before saving.";
                    entries.Focus();
                };
                form.Controls.Add(entries); form.Controls.Add(save); form.Controls.Add(hint);
                form.Controls.Add(status); form.Controls.Add(draftButton); form.Controls.Add(description); form.Controls.Add(prompt);
                if(form.ShowDialog(this)!=DialogResult.OK)return false;
                var files=new System.Collections.Generic.List<object>();
                foreach(var line in entries.Lines.Where(l=>!String.IsNullOrWhiteSpace(l))){
                    var fields=line.Split('|');
                    if(fields.Length>2 || (fields.Length==2 && !Regex.IsMatch(fields[1].Trim(),@"\A[0-9a-fA-F]{64}\z"))){
                        MessageBox.Show(this,"Each checksum must have 64 hexadecimal digits.");return false;}
                    files.Add(new {path=fields[0].Trim(),sha256=fields.Length==2?fields[1].Trim():null});
                }
                if(files.Count==0 || files.Count>1024){MessageBox.Show(this,"Enter between 1 and 1,024 files.");return false;}
                var json=new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(
                    new {schema="reflexcore.handoff.checklist.v1",name=Path.GetFileNameWithoutExtension(path),files});
                using(var writer=new StreamWriter(new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None))){writer.Write(json);}
                return true;
            }
        }
        void RunTask(string task)
        {
            queue.Submit(task,true);
            UpdateStatus();
        }
        void VerifyQueueControls()
        {
            var page=pages.TabPages[0];
            var buttons=page.Controls.OfType<Button>().ToDictionary(button=>button.Text);
            buttons["RUN AGENT DEMO"].PerformClick();
            buttons["NOTEPAD · CREATE FILE"].PerformClick();
            buttons["NOTEPAD · CHECK WITH MODEL"].PerformClick();
            refreshQueue();
            var jobs=page.Controls.OfType<ListView>().Single();
            if(!buttons["VERIFY A HANDOFF FOLDER"].Visible)throw new InvalidOperationException("Handoff action missing");
            queue.SubmitHandoff(root,Path.Combine(root,"examples","handoff-checklist.json"),Path.Combine(root,"smoke-report.json"));
            refreshQueue();
            if(jobs.Items.Count!=4 || queue.Snapshot().Select(row=>row.Task).Distinct().Count()!=4)
                throw new InvalidOperationException("Queued tasks missing from Studio");
            if(jobs.Columns.Cast<ColumnHeader>().Sum(column=>column.Width)!=jobs.ClientSize.Width)
                throw new InvalidOperationException("Queue header does not fill its viewport");
            jobs.Items[0].Selected=true;
            string id=(string)jobs.Items[0].Tag;
            buttons["APPROVE SELECTED"].PerformClick();
            buttons["CANCEL SELECTED"].PerformClick();
            if(!File.Exists(queue.Marker(id,"approve")) || !File.Exists(queue.Marker(id,"cancel")))
                throw new InvalidOperationException("Selected queue item commands failed");
            if(queue.DeleteHistory(id,"pending"))throw new InvalidOperationException("Active task deletion was allowed");
            queue.CancelPending();
            refreshQueue();
            jobs.Items.Cast<ListViewItem>().Single(item=>(string)item.Tag==id).Selected=true;
            jobs.ContextMenuStrip.Items.Cast<ToolStripItem>().Single(item=>item.Text=="Delete selected history entry").PerformClick();
            if(queue.Snapshot().Any(row=>row.Id==id))
                throw new InvalidOperationException("Selected queue history deletion failed");
            for(int i=0;i<30;i++)jobs.Items.Add(new ListViewItem("Scroll fixture"));
            ((QueueListView)jobs).FillLastColumn();
            if(jobs.ClientSize.Width>=jobs.Width ||
                jobs.Columns.Cast<ColumnHeader>().Sum(column=>column.Width)!=jobs.ClientSize.Width)
                throw new InvalidOperationException("Queue header does not fill the viewport beside its scrollbar");
        }
        string LoadModel()
        {
            string p=Path.Combine(root,"data","settings","openai_model.txt");return File.Exists(p)?File.ReadAllText(p).Trim():"gpt-4.1-mini";
        }
        void SaveModel()
        {
            string model=modelInput.Text.Trim();if(!Regex.IsMatch(model,@"^[a-zA-Z0-9_.-]{3,64}$"))throw new Exception("Invalid model ID");
            string folder=Path.Combine(root,"data","settings");Directory.CreateDirectory(folder);File.WriteAllText(Path.Combine(folder,"openai_model.txt"),model);
            MessageBox.Show("Model ID saved: "+model,"ReflexCore");
        }
        void SaveKey()
        {
            string key=keyInput.Text.Trim();if(key.Length<15||key.Length>256)throw new Exception("Invalid key length");
            string folder=Path.Combine(root,"data","secrets");Directory.CreateDirectory(folder);
            byte[] raw=Encoding.UTF8.GetBytes(key);
            try{byte[] blob=ProtectedData.Protect(raw,null,DataProtectionScope.CurrentUser);File.WriteAllBytes(Path.Combine(folder,"openai_key.dpapi"),blob);Array.Clear(blob,0,blob.Length);}finally{Array.Clear(raw,0,raw.Length);keyInput.Clear();key=null;}
            MessageBox.Show("API key saved using Windows DPAPI. Only your Windows user can decrypt it.","ReflexCore");UpdateStatus();
        }
        void DeleteKey()
        {
            string path=Path.Combine(root,"data","secrets","openai_key.dpapi");if(File.Exists(path))File.Delete(path);
            keyInput.Clear();UpdateStatus();MessageBox.Show("Local API key file deleted.","ReflexCore");
        }
        protected override void OnFormClosed(FormClosedEventArgs e){timer.Stop();timer.Dispose();base.OnFormClosed(e);}
    }
}
