// ReflexCore 0.6.2 | Integrated Ollama management tab. No model text, prompts, tokens or screenshots are logged.
// Accepts only an enumerated local script, typed settings and model IDs returned by local Ollama.
using System;
using System.IO;
using System.Diagnostics;
using System.Drawing;
using System.Text;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace ReflexCore.Control
{
    public sealed class ModelPanel : UserControl
    {
        readonly string root, tool, settings;
        readonly ComboBox models;
        readonly NumericUpDown minutes;
        readonly Label stage,leaseStatus;
        readonly System.Windows.Forms.Timer leasePollTimer;
        volatile bool leasePollBusy=false;
        readonly Button loadButton,stopButton,allButton,refreshButton,saveButton,benchmarkButton;
        readonly NumericUpDown temp,context,predict,topP,topK,penalty,threads,gpu,seed,keepAlive;
        readonly Color bg=Color.FromArgb(11,19,18), panel=Color.FromArgb(18,35,32), fg=Color.FromArgb(221,244,231), muted=Color.FromArgb(151,187,174), green=Color.FromArgb(143,246,113);
        bool busy;
        volatile int operation=0;
        Process activeTool;
        bool initialSelection;
        string savedModel="qwen3-vl:2b-instruct";
        readonly JavaScriptSerializer json=new JavaScriptSerializer();
        public ModelPanel(string project)
        {
            root=project;tool=Path.Combine(root,"tools","ReflexCore-Models.ps1");settings=Path.Combine(root,"data","settings","ollama-local.json");
            BackColor=bg;ForeColor=fg;Dock=DockStyle.Fill;Font=new Font("Segoe UI",10);
            TableLayoutPanel outer=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=4,BackColor=bg,Padding=new Padding(14,8,14,8)};
            outer.RowStyles.Add(new RowStyle(SizeType.Absolute,63));outer.RowStyles.Add(new RowStyle(SizeType.Absolute,94));
            outer.RowStyles.Add(new RowStyle(SizeType.Percent,100));outer.RowStyles.Add(new RowStyle(SizeType.Absolute,68));
            Controls.Add(outer);
            var top=new TableLayoutPanel{Dock=DockStyle.Fill,RowCount=2,ColumnCount=1};
            top.RowStyles.Add(new RowStyle(SizeType.Absolute,31));top.RowStyles.Add(new RowStyle(SizeType.Percent,100));outer.Controls.Add(top,0,0);
            top.Controls.Add(new Label{Text="OLLAMA  /  ЛОКАЛЬНЫЕ МОДЕЛИ",Dock=DockStyle.Fill,ForeColor=green,Font=new Font("Consolas",16,FontStyle.Bold)},0,0);
            top.Controls.Add(new Label{Text="Запуск по времени, остановка и реальные параметры Qwen. Никаких запросов без твоего действия.",Dock=DockStyle.Fill,ForeColor=muted},0,1);
            var commands=new FlowLayoutPanel{Dock=DockStyle.Fill,AutoScroll=true,WrapContents=true,BackColor=panel,Padding=new Padding(8,7,8,5)};
            outer.Controls.Add(commands,0,1);
            commands.Controls.Add(new Label{Text="Модель",ForeColor=fg,Width=65,Height=30,TextAlign=ContentAlignment.MiddleLeft});
            models=new ComboBox{DropDownStyle=ComboBoxStyle.DropDownList,Width=240,Height=31,BackColor=panel,ForeColor=fg};commands.Controls.Add(models);
            commands.Controls.Add(new Label{Text="Минут",ForeColor=fg,Width=61,Height=30,TextAlign=ContentAlignment.MiddleRight});
            minutes=new NumericUpDown{Minimum=1,Maximum=240,Value=15,Width=62,BackColor=panel,ForeColor=fg};commands.Controls.Add(minutes);
            loadButton=MakeModelButton("▶  ЗАПУСТИТЬ",147,()=>Call("Load",true));commands.Controls.Add(loadButton);
            stopButton=MakeModelButton("■  СТОП МОДЕЛЬ",161,()=>Call("Stop",true));commands.Controls.Add(stopButton);
            refreshButton=MakeModelButton("↻  ОБНОВИТЬ",145,()=>Call("List",false));commands.Controls.Add(refreshButton);
            benchmarkButton=MakeModelButton("TEST QWEN ×3",150,()=>Call("Benchmark",false));commands.Controls.Add(benchmarkButton);
            allButton=MakeModelButton("■  СТОП ВСЁ",155,()=>{
                if(MessageBox.Show("Остановить задания ReflexCore и выгрузить ВСЕ загруженные локальные модели Ollama?\nДругие программы, использующие Ollama, тоже потеряют загруженные модели. Процессы Windows не завершаются.","ReflexCore — подтверждение",MessageBoxButtons.YesNo,MessageBoxIcon.Warning)==DialogResult.Yes)EmergencyStop();
            });allButton.BackColor=Color.FromArgb(105,43,47);commands.Controls.Add(allButton);
            var tabs=new TabControl{Dock=DockStyle.Fill};outer.Controls.Add(tabs,0,2);
            var basic=new TabPage("Основные настройки"){BackColor=bg};var advanced=new TabPage("Дополнительные параметры"){BackColor=bg};tabs.TabPages.AddRange(new TabPage[]{basic,advanced});
            var basicFlow=SettingsFlow(basic);var advancedFlow=SettingsFlow(advanced);
            temp=Field(basicFlow,"Temperature",0m,2m,0.05m,2,"0 = стабильные решения; больше = разнообразие, но меньше повторяемость.");
            context=Field(basicFlow,"Context (num_ctx)",512m,8192m,256m,0,"Контекст модели. 2048 по умолчанию; 4096+ требует больше RAM/VRAM.");
            predict=Field(basicFlow,"Output tokens (num_predict)",1m,512m,1m,0,"Длина ответа. Меньше часто быстрее, но может обрезать JSON или логику.");
            topP=Field(basicFlow,"Top-p",0.05m,1m,0.05m,2,"Порог вероятностного отбора; влияет на разнообразие ответа.");
            keepAlive=Field(basicFlow,"Keep alive (мин)",1m,240m,1m,0,"Время удержания модели после запроса; это НЕ лимит вычислений.");
            topK=Field(advancedFlow,"Top-k",1m,100m,1m,0,"Ограничивает число кандидатов следующего токена.");
            penalty=Field(advancedFlow,"Repeat penalty",0.8m,2m,0.05m,2,"Штраф повторений. Значение 1 = без штрафа.");
            threads=Field(advancedFlow,"CPU threads (0 = auto)",0m,32m,1m,0,"Число CPU-потоков для инференса, если отличается от автоматического.");
            gpu=Field(advancedFlow,"GPU layers (-1 = auto)",-1m,99m,1m,0,"Количество слоёв для GPU. На 4 ГБ VRAM высокие значения могут вызвать OOM.");
            seed=Field(advancedFlow,"Seed (-1 = auto)",-1m,2147483647m,1m,0,"Фиксированное зерно улучшает повторяемость; -1 оставляет выбор модели.");
            advancedFlow.Controls.Add(new Label{Text="Параметры здесь применяются только к локальному Qwen в Shared Control. OpenAI API и Citadel имеют отдельные настройки.",ForeColor=muted,AutoSize=false,Width=760,Height=52,Margin=new Padding(8,12,8,8)});
            var footer=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=2};footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));footer.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,240));
            footer.RowStyles.Add(new RowStyle(SizeType.Absolute,30));footer.RowStyles.Add(new RowStyle(SizeType.Absolute,29));outer.Controls.Add(footer,0,3);
            stage=new Label{Text="Ollama: получение статуса…",Dock=DockStyle.Fill,ForeColor=muted,TextAlign=ContentAlignment.MiddleLeft,AutoEllipsis=true};footer.Controls.Add(stage,0,0);
            leaseStatus=new Label{Text="Фактическая загрузка: проверяется через Ollama /api/ps",Dock=DockStyle.Fill,ForeColor=green,TextAlign=ContentAlignment.MiddleLeft,AutoEllipsis=true};footer.Controls.Add(leaseStatus,0,1);
            saveButton=MakeModelButton("СОХРАНИТЬ ПАРАМЕТРЫ",230,Save);saveButton.Dock=DockStyle.Fill;footer.Controls.Add(saveButton,1,0);footer.SetRowSpan(saveButton,2);
            LoadSettings();
            leasePollTimer=new System.Windows.Forms.Timer{Interval=4000};
            leasePollTimer.Tick+=delegate{PollLease();};leasePollTimer.Start();
            Disposed+=delegate{leasePollTimer.Stop();leasePollTimer.Dispose();};
            HandleCreated+=delegate{if(!initialSelection){initialSelection=true;Call("List",false);}PollLease();};
        }
        static FlowLayoutPanel SettingsFlow(TabPage tab)
        {
            var flow=new FlowLayoutPanel{Dock=DockStyle.Fill,AutoScroll=true,WrapContents=false,FlowDirection=FlowDirection.TopDown,Padding=new Padding(12,9,12,12),BackColor=Color.FromArgb(11,19,18)};
            tab.Controls.Add(flow);
            flow.Resize+=delegate{foreach(System.Windows.Forms.Control c in flow.Controls)if(c is Panel)c.Width=Math.Max(450,flow.ClientSize.Width-44);};
            return flow;
        }
        NumericUpDown Field(FlowLayoutPanel parent,string title,decimal min,decimal max,decimal step,int decimals,string explanation)
        {
            var line=new Panel{Height=75,Width=775,BackColor=panel,Margin=new Padding(3,3,3,7)};
            line.Controls.Add(new Label{Text=title,Location=new Point(12,7),Width=310,Height=26,ForeColor=fg,Font=new Font("Segoe UI",10,FontStyle.Bold)});
            var n=new NumericUpDown{Minimum=min,Maximum=max,Increment=step,DecimalPlaces=decimals,Width=144,Location=new Point(330,8),BackColor=Color.FromArgb(25,44,40),ForeColor=fg};line.Controls.Add(n);
            line.Controls.Add(new Label{Text=explanation,Location=new Point(12,40),Width=745,Height=28,ForeColor=muted,AutoEllipsis=true});parent.Controls.Add(line);
            line.Resize+=delegate{line.Controls[2].Width=Math.Max(290,line.ClientSize.Width-25);};return n;
        }
        Button MakeModelButton(string name,int width,Action click)
        {
            var b=new Button{Text=name,Width=width,Height=34,FlatStyle=FlatStyle.Flat,BackColor=Color.FromArgb(29,74,52),ForeColor=green,Margin=new Padding(4,0,4,4),Font=new Font("Segoe UI",9,FontStyle.Bold)};
            b.Click+=delegate{try{click();}catch(Exception){stage.Text="Операция отклонена; проверь локальный сервис.";}};return b;
        }
        static decimal Get(Dictionary<string,object> raw,string key,decimal fallback,decimal min,decimal max)
        {
            try{object v;if(!raw.TryGetValue(key,out v))return fallback;decimal d=Convert.ToDecimal(v,System.Globalization.CultureInfo.InvariantCulture);return d>=min&&d<=max?d:fallback;}catch{return fallback;}
        }
        void LoadSettings()
        {
            Dictionary<string,object> d=new Dictionary<string,object>();
            try{if(File.Exists(settings)&&new FileInfo(settings).Length<16384)d=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(settings,Encoding.UTF8));}catch{}
            object m;
            if(d.TryGetValue("model",out m)&&m is string&&Regex.IsMatch((string)m,@"^[a-zA-Z0-9_.:/-]{1,128}$"))savedModel=(string)m;
            temp.Value=Get(d,"temperature",0m,0m,2m);context.Value=Get(d,"num_ctx",2048m,512m,8192m);
            predict.Value=Get(d,"num_predict",40m,1m,512m);topP.Value=Get(d,"top_p",0.9m,0.05m,1m);
            topK.Value=Get(d,"top_k",40m,1m,100m);penalty.Value=Get(d,"repeat_penalty",1.1m,.8m,2m);
            threads.Value=Get(d,"num_thread",0m,0m,32m);gpu.Value=Get(d,"num_gpu",-1m,-1m,99m);
            seed.Value=Get(d,"seed",-1m,-1m,2147483647m);keepAlive.Value=Get(d,"keep_alive_minutes",30m,1m,240m);
        }
        void Save()
        {
            string name=SelectedModel();if(name.Length==0)throw new InvalidOperationException("Сначала выбери установленную модель через ОБНОВИТЬ.");
            var data=new Dictionary<string,object>{{"schema","reflexcore.ollama.settings.v1"},{"model",name},
                {"temperature",(double)temp.Value},{"num_ctx",(int)context.Value},{"num_predict",(int)predict.Value},
                {"top_p",(double)topP.Value},{"top_k",(int)topK.Value},{"repeat_penalty",(double)penalty.Value},
                {"num_thread",(int)threads.Value},{"num_gpu",(int)gpu.Value},{"seed",(int)seed.Value},
                {"keep_alive_minutes",(int)keepAlive.Value}};
            Directory.CreateDirectory(Path.GetDirectoryName(settings));
            string tmp=settings+".reflex-tmp-"+Guid.NewGuid().ToString("N");
            try{
                File.WriteAllText(tmp,json.Serialize(data),new UTF8Encoding(false));
                if(File.Exists(settings)){
                    string bak=tmp+".backup";
                    try{File.Replace(tmp,settings,bak);}finally{if(File.Exists(bak))File.Delete(bak);}
                }else File.Move(tmp,settings);
            }finally{if(File.Exists(tmp))File.Delete(tmp);}
            savedModel=name;stage.Text="Настройки сохранены; Shared Control применит их при следующем запросе Qwen.";
        }
        string SelectedModel()
        {
            string s=models.SelectedItem as string;
            return s!=null&&s.Length<=128&&Regex.IsMatch(s,@"^[a-zA-Z0-9_.:/-]+$")?s:"";
        }
        void Busy(bool value){busy=value;loadButton.Enabled=stopButton.Enabled=refreshButton.Enabled=benchmarkButton.Enabled=!value;allButton.Enabled=true;}
        void EmergencyStop()
        {
            // STOP must not wait for the current model loading or benchmark request to finish.
            try{
                string path=Path.Combine(root,"data","bridge");Directory.CreateDirectory(path);
                File.WriteAllText(Path.Combine(path,"control.txt"),"stop-all");
                File.WriteAllText(Path.Combine(path,"global-stop.signal"),DateTime.UtcNow.ToString("o"));
            }catch{}
            try{if(activeTool!=null&&!activeTool.HasExited)activeTool.Kill();}catch{}
            ++operation;busy=false;
            Call("StopAll",false);
        }
        void Call(string action,bool requiresModel)
        {
            if(busy)return;
            string model=SelectedModel();if(requiresModel&&model.Length==0){stage.Text="Выбери локально установленную модель.";return;}
            int span=(int)minutes.Value;
            Busy(true);int myOperation=++operation;
            stage.Text=action=="Load"?"Загрузка модели (может занять время)…":action=="StopAll"?"Останавливаю задачи Reflex и выгружаю модели…":action=="Benchmark"?"Фиксированный Qwen-тест: 1 прогрев + 3 проверки JSON…":"Проверяю Ollama…";
            Task.Run(delegate{
                string response="";string error="";
                try{
                    if(myOperation!=operation)return; // STOP ALL superseded this request.
                    string script=action=="Benchmark"?Path.Combine(root,"tools","Benchmark-ReflexQwen.ps1"):tool;
                    string args=action=="Benchmark"?" -Runs 3 -Warmups 1":" -Action "+action+(model.Length>0?" -Model \""+model+"\"":"")+" -Minutes "+span;
                    var psi=new ProcessStartInfo{FileName=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe"),
                        Arguments="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \""+script+"\""+args,
                        WorkingDirectory=root,UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
                    using(var p=new Process{StartInfo=psi}){
                        if(!p.Start())throw new Exception("Tool start failed");
                        activeTool=p;
                        if(myOperation!=operation){try{p.Kill();}catch{}return;}
                        var outTask=p.StandardOutput.ReadToEndAsync();var errTask=p.StandardError.ReadToEndAsync();
                        if(!p.WaitForExit(action=="Load"?205000:110000)){
                            try{p.Kill();}catch{}throw new Exception("Timeout");
                        }
                        response=outTask.GetAwaiter().GetResult();errTask.GetAwaiter().GetResult();
                        if(response.Length>65536)throw new Exception("Local tool response exceeded size limit");
                        // Failed fixed-model tasks still provide a sanitized result record.
                        if(p.ExitCode!=0 && action!="Benchmark")throw new Exception("Local manager returned error code "+p.ExitCode);
                    }
                }catch(Exception ex){error=ex.GetType().Name;}
                if(IsDisposed||!IsHandleCreated)return;
                try{BeginInvoke((Action)(()=>{
                    if(myOperation!=operation)return;
                    activeTool=null;Busy(false);
                    if(error.Length>0){stage.Text="Ollama / "+error+" — смотри, запущен ли локальный сервер.";return;}
                    if(action=="List"||action=="Stop"||action=="Load"||action=="StopAll"||action=="Benchmark"){
                        if(action=="Benchmark"){
                            try{
                                var b=json.Deserialize<Dictionary<string,object>>(response);
                                if(Convert.ToString(b["schema"])!="reflexcore.model.benchmark.v1")throw new Exception();
                                stage.Text="Qwen fixed JSON: verified "+b["success"]+"/"+b["runs"]+" · p50 "+b["p50_ms"]+" ms · p95 "+b["p95_ms"]+" ms (text only)";
                            }catch{stage.Text="Qwen benchmark result unavailable; see Diagnostics.";}
                        }else if(action=="List"){
                            try{
                                var obj=json.Deserialize<Dictionary<string,object>>(response);
                                if(Convert.ToString(obj["schema"])!="reflexcore.models.status.v1")throw new Exception();
                                var installed=obj["installed"] as System.Collections.IEnumerable;
                                models.Items.Clear();
                                if(installed!=null)foreach(object v in installed){string name=v as string;if(name!=null&&Regex.IsMatch(name,@"^[a-zA-Z0-9_.:/-]{1,128}$"))models.Items.Add(name);}
                                if(models.Items.Contains(savedModel))models.SelectedItem=savedModel;
                                else if(models.Items.Count>0)models.SelectedIndex=0;
                                var loaded=obj["loaded"] as System.Collections.IEnumerable;int count=0;
                                if(loaded!=null)foreach(object v in loaded)count++;
                                stage.Text="Ollama: установлено "+models.Items.Count+" · загружено "+count+" · модель выбирается из локального списка";
                            }catch{stage.Text="Неверный ответ локального Ollama.";}
                        }else{
                            stage.Text=action=="Load"?"Загрузка подтверждена Ollama; контроль сеанса "+span+" мин.":action=="Stop"?"Модель выгружена.":"Запрошен STOP всех управляемых задач и выгрузка моделей.";
                            PollLease(); // Live, read-only status; no additional model generation.
                        }
                    }
                }));}catch{}
            });
        }
        // Direct, read-only status polling; avoids launching PowerShell every four seconds.
        // The short-lived loader process is not evidence that Ollama unloaded the model.
        void PollLease()
        {
            if(leasePollBusy||busy||IsDisposed||!IsHandleCreated)return;
            leasePollBusy=true;
            Task.Run(delegate{
                string result="Загрузка: состояние неизвестно";
                try{
                    var request=(System.Net.HttpWebRequest)System.Net.WebRequest.Create("http://127.0.0.1:11434/api/ps");
                    request.Proxy=null;request.Method="GET";request.Timeout=1800;request.ReadWriteTimeout=1800;
                    string raw;
                    using(var reply=(System.Net.HttpWebResponse)request.GetResponse())
                    using(var reader=new StreamReader(reply.GetResponseStream(),Encoding.UTF8)){
                        raw=reader.ReadToEnd();
                    }
                    if(raw.Length>524288)throw new InvalidOperationException("metadata too large");
                    var serializer=new JavaScriptSerializer();
                    var ps=serializer.Deserialize<Dictionary<string,object>>(raw);
                    object entries;
                    ps.TryGetValue("models",out entries);
                    var loaded=new HashSet<string>(StringComparer.Ordinal);
                    var items=entries as System.Collections.IEnumerable;
                    if(items!=null)foreach(object entry in items){
                        var d=entry as Dictionary<string,object>;if(d==null)continue;
                        object name; if(!d.TryGetValue("name",out name))d.TryGetValue("model",out name);
                        if(name is string)loaded.Add((string)name);
                    }
                    var leasePath=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ReflexCore","runtime","model-lease.json");
                    if(File.Exists(leasePath)&&new FileInfo(leasePath).Length<4096){
                        var lease=serializer.Deserialize<Dictionary<string,object>>(File.ReadAllText(leasePath,Encoding.UTF8));
                        object modelValue,expiryValue;
                        if(lease!=null&&lease.TryGetValue("model",out modelValue)&&lease.TryGetValue("until_utc",out expiryValue)){
                            string name=Convert.ToString(modelValue),until=Convert.ToString(expiryValue);
                            DateTimeOffset deadline;
                            if(DateTimeOffset.TryParse(until,System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.None,out deadline)){
                                int left=(int)Math.Max(0,Math.Ceiling((deadline-DateTimeOffset.UtcNow).TotalSeconds));
                                if(loaded.Contains(name)&&left>0)result="ЗАГРУЖЕНА: "+name+" · осталось "+(left/60)+"м "+(left%60)+"с · до "+deadline.ToLocalTime().ToString("HH:mm:ss");
                                else if(left>0)result="ВНИМАНИЕ: сеанс ещё "+left+"с, но "+name+" отсутствует в Ollama /api/ps";
                                else result="Срок сеанса истёк; загружено моделей: "+loaded.Count;
                            }else result="Неверный срок сеанса; загружено моделей: "+loaded.Count;
                        }else result="Загружено моделей: "+loaded.Count+" · активный сеанс не указан";
                    }else result="Загружено моделей: "+loaded.Count+" · таймер запуска не активен";
                }catch(Exception){result="Не удалось прочитать /api/ps — состояние загрузки не подтверждено";}
                try{if(!IsDisposed&&IsHandleCreated)BeginInvoke((Action)(()=>{leaseStatus.Text=result;leasePollBusy=false;}));
                    else leasePollBusy=false;
                }catch{leasePollBusy=false;}
            });
        }
        public static void SelfTest(string project)
        {
            if(!File.Exists(Path.Combine(project,"tools","ReflexCore-Models.ps1")))throw new Exception("Model control script missing");
            if(!File.Exists(Path.Combine(project,"tools","ReflexCore-Diagnostics.cs")))throw new Exception("Dashboard source missing");
            Console.WriteLine("[ReflexCore] Integrated Models/Diagnostics UI compiled; model guard files present.");
        }
    }
}
