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
                foreach(string task in new[]{"agent-demo","notepad-save","notepad-visual"})
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
                delegate{WriteControl("stop");},ShellModernizer.CurrentStage);
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
            string ico=Path.Combine(root,"assets","reflex_dragon.ico");if(File.Exists(ico)){try{Icon=new Icon(ico);}catch{}}
            var header=new Panel{Dock=DockStyle.Top,Height=98,BackColor=surface};Controls.Add(header);
            var title=new Label{Text="◈  REFLEXCORE",Font=new Font("Consolas",26,FontStyle.Bold),ForeColor=accent,Location=new Point(26,17),AutoSize=true};header.Controls.Add(title);
            header.Controls.Add(new Label{Text="LOCAL AGENT · DEV BRIDGE · GAME LAB",Font=new Font("Consolas",10),ForeColor=muted,Location=new Point(30,66),AutoSize=true});
            var tabs=pages=new ReflexTabHost{Dock=DockStyle.Fill};Controls.Add(tabs);tabs.BringToFront();
            var agent=Page("АГЕНТ",tabs);
            var modelsTab=Page("МОДЕЛИ",tabs);
            var diagnosticsTab=Page("ДИАГНОСТИКА",tabs);
            var shared=Page("SHARED CONTROL",tabs);
            var game=Page("CITADEL LAB",tabs);
            var ai=Page("OPENAI API",tabs);
            // Preserve existing functional pages, replace only the window shell.
            // The WPF window hosts these six live WinForms pages in one process.
            modelsTab.Controls.Add(new ModelPanel(root));
            // Embed the original 0.6.1 Measurement Lab without opening an overlapping top-level window.
            var diagnosticView=new ReflexCore.Diagnostics.Dashboard(root){TopLevel=false,FormBorderStyle=FormBorderStyle.None,Dock=DockStyle.Fill,ShowInTaskbar=false};
            diagnosticsTab.Controls.Add(diagnosticView);
            tabs.SelectedIndexChanged+=(sender,args)=>{if(tabs.SelectedTab==diagnosticsTab)diagnosticView.Show();};
            diagnosticsTab.Enter+=(sender,args)=>{if(!diagnosticView.Visible)diagnosticView.Show();};
            if(initialTab=="Models")tabs.SelectedTab=modelsTab;
            else if(initialTab=="Diagnostics")tabs.SelectedTab=diagnosticsTab;
            else tabs.SelectedTab=agent;
            if(tabs.SelectedTab==diagnosticsTab)diagnosticView.Show();
            agent.Controls.Add(Header("AGENT SUPERVISOR",18,22));
            bridgeText=Info("BRIDGE: waiting...",18,62,680);agent.Controls.Add(bridgeText);
            agent.Controls.Add(Header("Панель управления проверенными локальными заданиями",18,102));
            AddButton(agent,"ОСТАНОВИТЬ ЗАДАНИЕ  ·  CTRL+ALT+P",18,150,365,44,()=>WriteControl("stop"),true);
            AddButton(agent,"ОТКРЫТЬ ПАПКУ ПРОЕКТА",401,150,365,44,()=>Process.Start("explorer.exe",root),false);
            AddButton(agent,"ЗАПУСТИТЬ AGENT DEMO",18,219,365,44,()=>RunTask("agent-demo"),false);
            AddButton(agent,"ПРОВЕРИТЬ STATUS",401,219,365,44,()=>UpdateStatus(),false);
            AddButton(agent,"БЛОКНОТ · СОЗДАТЬ ФАЙЛ",18,279,365,43,()=>RunTask("notepad-save"),false);
            AddButton(agent,"БЛОКНОТ · С ПРОВЕРКОЙ МОДЕЛЬЮ",401,279,365,43,()=>RunTask("notepad-visual"),false);
            var jobs=new ListView{View=View.Details,FullRowSelect=true,MultiSelect=false,HideSelection=false,
                Location=new Point(18,337),Size=new Size(748,164),AccessibleName="Очередь заданий"};
            jobs.Columns.Add("Время (местное)",180);jobs.Columns.Add("Задание",235);jobs.Columns.Add("Состояние",290);
            agent.Controls.Add(jobs);
            var notice=Info("После перезапуска подтвердите ожидающее задание. Прерванные задания видны в истории.",18,560,748);
            agent.Controls.Add(notice);
            Action<string> command=delegate(string action){
                if(jobs.SelectedItems.Count==0){notice.Text="Выберите задание в очереди.";return;}
                string id=(string)jobs.SelectedItems[0].Tag;
                notice.Text=queue.Request(id,action)?"Запрос передан диспетчеру.":"Состояние задания уже изменилось.";
            };
            AddButton(agent,"ОТМЕНИТЬ ВЫБРАННОЕ",18,511,365,40,()=>command("cancel"),false);
            AddButton(agent,"РАЗРЕШИТЬ ЗАПУСК",401,511,365,40,()=>command("approve"),false);
            string lastSnapshot=null;
            var taskTimer=new System.Windows.Forms.Timer{Interval=900};
            refreshQueue=delegate {
                if(!jobs.Visible)return;
                try{
                    var rows=queue.Snapshot();
                    string signature=String.Join("|",rows.Select(row=>row.Id+"/"+row.State).ToArray());
                    if(signature==lastSnapshot)return;
                    string selected=jobs.SelectedItems.Count>0?(string)jobs.SelectedItems[0].Tag:"";
                    jobs.BeginUpdate();
                    try{
                        jobs.Items.Clear();
                        foreach(var row in rows){
                            DateTime created;
                            string hour=DateTime.TryParseExact(row.Id.Substring(0,17),"yyyyMMddHHmmssfff",
                                System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.AssumeUniversal|System.Globalization.DateTimeStyles.AdjustToUniversal,out created)
                                ?created.ToLocalTime().ToString("dd.MM HH:mm:ss"):"—";
                            string task=row.Task=="uia"?"UI Automation":row.Task=="notepad"?"Блокнот":row.Task=="visual"?"Блокнот + модель":"Локальное задание";
                            string state=row.State=="pending"?"Ожидает":row.State=="running"?"Выполняется":
                                row.State=="completed"?"Завершено":row.State=="cancelled"?"Отменено":row.State=="interrupted"?"Прервано":"Ошибка";
                            var entry=new ListViewItem(new[]{hour,task,state});entry.Tag=row.Id;jobs.Items.Add(entry);
                            if(row.Id==selected)entry.Selected=true;
                        }
                        lastSnapshot=signature;
                    }finally{jobs.EndUpdate();}
                }catch(IOException){notice.Text="Очередь обновляется.";}
            };
            taskTimer.Tick+=delegate{refreshQueue();};
            taskTimer.Start();Disposed+=delegate{taskTimer.Dispose();};

            game.Controls.Add(Header("REFLEX CITADEL // AKVARIUM 3D ARENA",18,22));
            serverText=Info("SERVER: checking",18,63,725);game.Controls.Add(serverText);
            AddButton(game,"▶ ОТКРЫТЬ AI ARENA В CHROME",18,125,420,53,()=>OpenGame(),true);
            AddButton(game,"ЗАПУСТИТЬ СЕРВЕР",462,125,305,53,()=>StartServer(),false);
            AddButton(game,"ОСТАНОВИТЬ СЕРВЕР",18,199,420,47,()=>StopServer(),false);
            AddButton(game,"ОТКРЫТЬ ИСХОДНИКИ ИГРЫ",462,199,305,47,()=>Process.Start("explorer.exe",Path.Combine(root,"Sandbox for intelegent test","citadel-zero")),false);
            game.Controls.Add(Info("AKVARIUM 3D  ·  3 миссии  ·  VISIBLE: действия агента в Chrome  ·  HEADLESS: автономный Node.js процесс",18,285,755));
            game.Controls.Add(Info("В игре выбирай режим агента, камеру 3D/2D и нажимай ЗАПУСТИТЬ АГЕНТА. API вызывается отдельно по твоему клику.",18,360,755));

            // DPI-aware API tab. Controls flow vertically and scroll; no absolute Y positions.
            shared.Controls.Add(Header("SHARED CONTROL // CS 1.6 OFFLINE",18,23));
            shared.Controls.Add(Info("THIRD MODE: управляет твоими реальными мышью и клавиатурой. При любом физическом вводе — 3-секундная пауза. Только локальный приватный сервер.",18,73,750));
            AddButton(shared,"▶ ОТКРЫТЬ CS 1.6 SHARED CONTROL LAB",18,160,746,54,()=>OpenSharedControl(),true);
            shared.Controls.Add(Info("1. Запусти CS 1.6 и создай New Game без других игроков.  2. Выбери T и получи C4.  3. Нажми Plant Drill на bombsite или запиши свою демонстрацию.",18,244,750));
            shared.Controls.Add(Info("F12 или Ctrl+Alt+P: STOP. Контроллер не читает память игры, не работает с серверами и не записывает текстовые поля. Запись: только локальные WASD и другие игровые кнопки.",18,336,750));
            var apiFlow=new FlowLayoutPanel{Dock=DockStyle.Fill,AutoScroll=true,FlowDirection=FlowDirection.TopDown,
                WrapContents=false,BackColor=bg,Padding=new Padding(18,18,18,20)};
            ai.Controls.Add(apiFlow);
            apiFlow.Controls.Add(ApiLabel("OPENAI RESPONSES API",34,true));
            modelText=ApiLabel("API KEY: checking...",36,false);apiFlow.Controls.Add(modelText);
            apiFlow.Controls.Add(ApiLabel("API-ключ (ввод скрыт; хранится только через Windows DPAPI)",29,false));
            keyInput=new TextBox{Height=29,Width=710,PasswordChar='●',BackColor=Color.FromArgb(24,40,42),
                ForeColor=text,BorderStyle=BorderStyle.FixedSingle,Margin=new Padding(0,0,0,15)};
            apiFlow.Controls.Add(keyInput);
            var keyButtons=new FlowLayoutPanel{Height=55,Width=740,FlowDirection=FlowDirection.LeftToRight,WrapContents=false,Margin=new Padding(0,0,0,16)};
            apiFlow.Controls.Add(keyButtons);
            AddButton(keyButtons,"СОХРАНИТЬ API КЛЮЧ",0,0,350,44,SaveKey,true);
            AddButton(keyButtons,"УДАЛИТЬ КЛЮЧ",362,0,335,44,DeleteKey,false);
            apiFlow.Controls.Add(ApiLabel("Model ID (например: gpt-4.1-mini)",29,false));
            var modelRow=new FlowLayoutPanel{Height=55,Width=740,FlowDirection=FlowDirection.LeftToRight,WrapContents=false,Margin=new Padding(0,0,0,15)};
            apiFlow.Controls.Add(modelRow);
            modelInput=new TextBox{Width=465,Height=31,Text=LoadModel(),BackColor=Color.FromArgb(24,40,42),
                ForeColor=text,BorderStyle=BorderStyle.FixedSingle,Margin=new Padding(0,7,10,0)};
            modelRow.Controls.Add(modelInput);
            AddButton(modelRow,"СОХРАНИТЬ МОДЕЛЬ",0,0,225,43,SaveModel,false);
            apiFlow.Controls.Add(ApiLabel("Тест проверяет настоящий вызов OpenAI. Он может тарифицироваться отдельно от ChatGPT.",43,false));
            var testRow=new FlowLayoutPanel{Height=52,Width=740,Margin=new Padding(0,0,0,4)};
            apiFlow.Controls.Add(testRow);
            AddButton(testRow,"ПРОВЕРИТЬ API СОЕДИНЕНИЕ",0,0,350,44,TestApiConnection,true);
            apiTestText=ApiLabel("API ещё не проверен. Сохранённый ключ ≠ проверенное соединение.",57,false);
            apiFlow.Controls.Add(apiTestText);
            apiFlow.Controls.Add(ApiLabel("Ключ остаётся локально в data/secrets/*.dpapi. Отправляется только напрямую OpenAI по HTTPS с сервера, а не в браузерную игру.",70,false));
            apiFlow.Controls.Add(ApiLabel("Для автономных боёв выбери в Chrome: VISIBLE → OPENAI. При сбое API будет явно показан локальный fallback.",64,false));
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
                throw new Exception("Сначала сохрани API-ключ.");
            if(MessageBox.Show("Выполнить один реальный платный API-запрос с небольшой игровой картой?\n\nКлюч не будет показан или записан в журнал.",
                "ReflexCore / API test",MessageBoxButtons.YesNo,MessageBoxIcon.Question)!=DialogResult.Yes)return;
            if(Interlocked.CompareExchange(ref apiTestBusy,1,0)!=0)return;
            apiTestText.Text="Проверяю OpenAI: отправляется один тестовый запрос...";
            ThreadPool.QueueUserWorkItem(delegate(object unused){
                string result;
                try
                {
                    if(!IsServerUp())throw new Exception("Локальный Citadel Server недоступен: запусти сервер на вкладке CITADEL LAB.");
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
                        throw new Exception("Сервер ответил, но OpenAI не подтвердил план. Проверь модель, ключ и биллинг.");
                    result="API OK — реальный запрос завершён, текст плана получен. Теперь проверяй план в Citadel.";
                }
                catch(WebException ex){result="API ERROR — "+(ex.Response is HttpWebResponse ? "HTTP "+(int)((HttpWebResponse)ex.Response).StatusCode : "сетевая ошибка")+". Проверь ключ, модель и оплату API.";}
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
        void RunTask(string task)
        {
            queue.Submit(task,true);
            UpdateStatus();
        }
        void VerifyQueueControls()
        {
            var page=pages.TabPages[0];
            var buttons=page.Controls.OfType<Button>().ToDictionary(button=>button.Text);
            buttons["ЗАПУСТИТЬ AGENT DEMO"].PerformClick();
            buttons["БЛОКНОТ · СОЗДАТЬ ФАЙЛ"].PerformClick();
            buttons["БЛОКНОТ · С ПРОВЕРКОЙ МОДЕЛЬЮ"].PerformClick();
            refreshQueue();
            var jobs=page.Controls.OfType<ListView>().Single();
            if(jobs.Items.Count!=3 || queue.Snapshot().Select(row=>row.Task).Distinct().Count()!=3)
                throw new InvalidOperationException("Queued tasks missing from Studio");
            jobs.Items[0].Selected=true;
            string id=(string)jobs.Items[0].Tag;
            buttons["РАЗРЕШИТЬ ЗАПУСК"].PerformClick();
            buttons["ОТМЕНИТЬ ВЫБРАННОЕ"].PerformClick();
            if(!File.Exists(queue.Marker(id,"approve")) || !File.Exists(queue.Marker(id,"cancel")))
                throw new InvalidOperationException("Selected queue item commands failed");
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
