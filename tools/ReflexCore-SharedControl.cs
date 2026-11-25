// ReflexCore 0.4.3 — Shared Control, CS 1.6 private/offline training lab.
// No injection into the game process. Only normal Win32 SendInput.
// No system-wide key logs: recording is limited to gameplay keys while hl.exe/cstrike.exe is foreground.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Web.Script.Serialization;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ReflexCore.SharedControl
{
    internal static class Native
    {
        internal delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll",SetLastError=true)] internal static extern IntPtr SetWindowsHookEx(int idHook,HookProc callback,IntPtr module,uint thread);
        [DllImport("user32.dll",SetLastError=true)] internal static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] internal static extern IntPtr CallNextHookEx(IntPtr hook,int code,IntPtr wParam,IntPtr lParam);
        [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] internal static extern bool GetClientRect(IntPtr hwnd,out RECT rect);
        [DllImport("user32.dll")] internal static extern bool ClientToScreen(IntPtr hwnd,ref POINT point);
        [StructLayout(LayoutKind.Sequential)] internal struct RECT {public int left,top,right,bottom;}
        [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
        [DllImport("user32.dll",SetLastError=true)] internal static extern uint SendInput(uint count,INPUT[] inputs,int size);
        [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] internal static extern IntPtr GetModuleHandle(string module);
        [StructLayout(LayoutKind.Sequential)] internal struct POINT {public int x;public int y;}
        [StructLayout(LayoutKind.Sequential)] internal struct KBD {public uint vkCode,scanCode,flags,time;public IntPtr extra;}
        [StructLayout(LayoutKind.Sequential)] internal struct MOUSEHOOK {public POINT point;public uint mouseData,flags,time;public IntPtr extra;}
        [StructLayout(LayoutKind.Sequential)] internal struct KEYINPUT {public ushort vk,scan;public uint flags,time;public UIntPtr extra;}
        [StructLayout(LayoutKind.Sequential)] internal struct MOUSEINPUT {public int dx,dy;public uint mouseData,flags,time;public UIntPtr extra;}
        [StructLayout(LayoutKind.Explicit)] internal struct INPUTUNION { [FieldOffset(0)]public KEYINPUT key;[FieldOffset(0)]public MOUSEINPUT mouse; }
        [StructLayout(LayoutKind.Sequential)] internal struct INPUT {public uint type;public INPUTUNION data;}
        internal static bool IsGameMovementKey(int vk){return vk==0x57||vk==0x41||vk==0x53||vk==0x44;}
        internal static KEYINPUT BuildKeyInput(int vk,bool down)
        {
            if(IsGameMovementKey(vk))
            {
                // GoldSrc may read physical scancodes instead of Windows virtual keys.
                // Only WASD uses scancodes; C4 and existing playback bindings are unchanged.
                // Physical set-1 make codes for W/A/S/D, independent of text language.
                ushort scan=(ushort)(vk==0x57?0x11:vk==0x41?0x1E:vk==0x53?0x1F:0x20);
                return new KEYINPUT{vk=0,scan=scan,flags=down?8u:10u};
            }
            return new KEYINPUT{vk=(ushort)vk,flags=down?0u:2u};
        }
        internal static void Key(int vk,bool down)
        {
            INPUT v=new INPUT();v.type=1;v.data.key=BuildKeyInput(vk,down);
            if(SendInput(1,new INPUT[]{v},Marshal.SizeOf(typeof(INPUT)))!=1)
                throw new InvalidOperationException("SendInput keyboard failed (Win32="+Marshal.GetLastWin32Error()+")");
        }
        internal static void Mouse(string kind,int dx,int dy)
        {
            uint flag=kind=="move"?1u:kind=="ld"?2u:kind=="lu"?4u:kind=="rd"?8u:kind=="ru"?16u:0u;
            if(flag==0)return;
            INPUT v=new INPUT();v.type=0;v.data.mouse=new MOUSEINPUT{dx=dx,dy=dy,flags=flag};
            if(SendInput(1,new INPUT[]{v},Marshal.SizeOf(typeof(INPUT)))!=1)throw new InvalidOperationException("SendInput mouse failed");
        }
    }
    // In-memory, low-resolution visual change detector for game-window CLIENT AREA only.
    // Does not claim positional movement, kills or completion; rejects unchanged scenes.
    internal static class SceneProbe
    {
        internal const int Width=40,Height=24;
        internal static byte[] Capture()
        {
            try
            {
                IntPtr hwnd=Native.GetForegroundWindow();
                if(hwnd==IntPtr.Zero)return null;
                Native.RECT r;Native.POINT topLeft=new Native.POINT();
                if(!Native.GetClientRect(hwnd,out r)||!Native.ClientToScreen(hwnd,ref topLeft))return null;
                int w=r.right-r.left,h=r.bottom-r.top;
                if(w<160||h<120||w>8000||h>8000)return null;
                using(Bitmap frame=new Bitmap(w,h))
                {
                    using(Graphics g=Graphics.FromImage(frame))
                        g.CopyFromScreen(topLeft.x,topLeft.y,0,0,new Size(w,h),CopyPixelOperation.SourceCopy);
                    using(Bitmap small=new Bitmap(Width,Height))
                    {
                        using(Graphics g=Graphics.FromImage(small))
                        {
                            g.InterpolationMode=System.Drawing.Drawing2D.InterpolationMode.Bilinear;
                            g.DrawImage(frame,new Rectangle(0,0,Width,Height));
                        }
                        byte[] pixels=new byte[Width*Height];
                        // Skip image borders/HUD margins. Don't retain full images.
                        for(int y=0;y<Height;y++)for(int x=0;x<Width;x++)
                        {
                            Color c=small.GetPixel(x,y);
                            pixels[y*Width+x]=(byte)((c.R*3+c.G*6+c.B)/10);
                        }
                        return pixels;
                    }
                }
            }
            catch{return null;}
        }
        // Very small block shift estimator: visual FLOW evidence, never proof of positional movement.
        // Uses only the 40x24 grayscale fingerprint and does not retain images.
        internal static int[] EstimateVisualFlow(byte[] before,byte[] after)
        {
            if(before==null||after==null||before.Length!=Width*Height||after.Length!=before.Length)
                return new int[]{0,0,0};
            long still=0,best=Int64.MaxValue;int bestDx=0,bestDy=0;
            for(int dy=-2;dy<=2;dy++)for(int dx=-3;dx<=3;dx++)
            {
                long error=0;
                for(int y=5;y<Height-5;y++)for(int x=6;x<Width-6;x++)
                {
                    int baseIndex=y*Width+x;
                    int moved=(y+dy)*Width+x+dx;
                    error+=Math.Abs((int)before[baseIndex]-(int)after[moved]);
                }
                if(dx==0&&dy==0)still=error;
                // When multiple shifts tie, prefer zero displacement: a flat or unchanged
                // image must never imply motion. Never invent odometry from ambiguity.
                if(error<best||(error==best&&Math.Abs(dx)+Math.Abs(dy)<Math.Abs(bestDx)+Math.Abs(bestDy)))
                {best=error;bestDx=dx;bestDy=dy;}
            }
            if(still==0)return new int[]{0,0,0};
            int gain=(int)Math.Max(0,Math.Min(100,(still-best)*100/still));
            return new int[]{bestDx,bestDy,gain};
        }
        internal static int ChangePercent(byte[] before,byte[] after)
        {
            if(before==null||after==null||before.Length!=Width*Height||after.Length!=before.Length)return -1;
            int changed=0,total=0;
            for(int y=3;y<Height-3;y++)for(int x=4;x<Width-4;x++)
            {
                int at=y*Width+x;total++;
                if(Math.Abs(before[at]-after[at])>22)changed++;
            }
            return (changed*100)/total;
        }
    }
    // Navigation observation uses ONE capture for feedback and the next model input.
    // All images stay in memory. Only the foreground hl.exe / cstrike.exe may be captured.
    internal sealed class NavFrame
    {
        internal byte[] fingerprint;
        internal byte[] jpeg;
        internal long capture_ms;
    }
    internal static class GameVisionFrame
    {
        internal static NavFrame Capture()
        {
            var watch=Stopwatch.StartNew();
            try
            {
                IntPtr hwnd=Native.GetForegroundWindow();
                if(hwnd==IntPtr.Zero)return null;
                uint pid;Native.GetWindowThreadProcessId(hwnd,out pid);
                if(pid==0)return null;
                using(Process p=Process.GetProcessById((int)pid))
                {
                    string name=p.ProcessName.ToLowerInvariant();
                    if(name!="hl"&&name!="cstrike")return null;
                }
                Native.RECT r;Native.POINT origin=new Native.POINT();
                if(!Native.GetClientRect(hwnd,out r)||!Native.ClientToScreen(hwnd,ref origin))return null;
                int w=r.right-r.left,h=r.bottom-r.top;
                if(w<160||h<120||w>8000||h>8000)return null;
                using(Bitmap original=new Bitmap(w,h))
                {
                    using(Graphics g=Graphics.FromImage(original))
                        g.CopyFromScreen(origin.x,origin.y,0,0,new Size(w,h),CopyPixelOperation.SourceCopy);
                    if(Native.GetForegroundWindow()!=hwnd)return null;
                    using(Bitmap small=new Bitmap(SceneProbe.Width,SceneProbe.Height))
                    using(Bitmap resized=new Bitmap(Math.Min(384,w),Math.Max(1,(int)Math.Round((double)h*Math.Min(384,w)/w))))
                    {
                        using(Graphics g=Graphics.FromImage(small))
                        {
                            g.InterpolationMode=System.Drawing.Drawing2D.InterpolationMode.Bilinear;
                            g.DrawImage(original,new Rectangle(0,0,small.Width,small.Height));
                        }
                        byte[] pixels=new byte[SceneProbe.Width*SceneProbe.Height];
                        for(int y=0;y<small.Height;y++)for(int x=0;x<small.Width;x++)
                        {
                            Color c=small.GetPixel(x,y);
                            pixels[y*small.Width+x]=(byte)((c.R*3+c.G*6+c.B)/10);
                        }
                        using(Graphics g=Graphics.FromImage(resized))
                        {
                            g.InterpolationMode=System.Drawing.Drawing2D.InterpolationMode.HighQualityBilinear;
                            g.DrawImage(original,new Rectangle(0,0,resized.Width,resized.Height));
                        }
                        int black=0,total=0;
                        for(int y=0;y<resized.Height;y+=Math.Max(1,resized.Height/16))
                            for(int x=0;x<resized.Width;x+=Math.Max(1,resized.Width/16))
                            {
                                Color c=resized.GetPixel(x,y);
                                if(c.R<7&&c.G<7&&c.B<7)black++;
                                total++;
                            }
                        if(total>0&&black>total*0.97)return null;
                        using(var memory=new MemoryStream())
                        {
                            System.Drawing.Imaging.ImageCodecInfo jpeg=null;
                            foreach(var enc in System.Drawing.Imaging.ImageCodecInfo.GetImageEncoders())
                                if(enc.MimeType=="image/jpeg")jpeg=enc;
                            if(jpeg==null)return null;
                            using(var settings=new System.Drawing.Imaging.EncoderParameters(1))
                            {
                                settings.Param[0]=new System.Drawing.Imaging.EncoderParameter(System.Drawing.Imaging.Encoder.Quality,65L);
                                resized.Save(memory,jpeg,settings);
                            }
                            watch.Stop();
                            return new NavFrame{fingerprint=pixels,jpeg=memory.ToArray(),capture_ms=watch.ElapsedMilliseconds};
                        }
                    }
                }
            }
            catch{return null;}
        }
    }
    internal sealed class NavInferenceResult
    {
        internal NavigationPlan plan;
        internal long capture_ms,infer_ms,parse_ms;
        internal bool image_reused;
        internal long load_ms,prompt_ms,eval_ms,prompt_tokens,output_tokens;
        internal string model_id;internal int ctx,predict;internal double temperature,top_p;
    }
    // Settings shared with the integrated Model tab. Whitelist and bounds protect the Ollama request.
    // No prompts, screenshots or UI content are ever written to this file.
    internal sealed class OllamaTuning
    {
        internal string model="qwen3-vl:2b-instruct";
        internal int num_ctx=2048,num_predict=40,top_k=40,num_thread=0,num_gpu=-1,seed=-1,keep_alive_minutes=30;
        internal double temperature=0,top_p=.9,repeat_penalty=1.1;
        internal static int Int(Dictionary<string,object> d,string key,int fallback,int lo,int hi)
        {
            object o;
            try{int x=Convert.ToInt32(d.TryGetValue(key,out o)?o:fallback);return x>=lo&&x<=hi?x:fallback;}
            catch{return fallback;}
        }
        internal static double Number(Dictionary<string,object> d,string key,double fallback,double lo,double hi)
        {
            object o;
            try{double x=Convert.ToDouble(d.TryGetValue(key,out o)?o:fallback);return !Double.IsNaN(x)&&!Double.IsInfinity(x)&&x>=lo&&x<=hi?x:fallback;}
            catch{return fallback;}
        }
        internal static OllamaTuning Load(string root,string mode)
        {
            var p=new OllamaTuning();p.num_predict=mode=="deep"?70:40;
            string file=Path.Combine(root,"data","settings","ollama-local.json");
            try
            {
                if(!File.Exists(file)||new FileInfo(file).Length>16384)return p;
                var d=new JavaScriptSerializer().DeserializeObject(File.ReadAllText(file,Encoding.UTF8)) as Dictionary<string,object>;
                if(d==null||!d.ContainsKey("schema")||!Object.Equals(d["schema"],"reflexcore.ollama.settings.v1"))return p;
                object raw;string name=d.TryGetValue("model",out raw)?raw as string:null;
                if(!String.IsNullOrEmpty(name)&&name.Length<=128&&System.Text.RegularExpressions.Regex.IsMatch(name,@"^[a-zA-Z0-9_.:/-]+$")&&!name.Contains(".."))p.model=name;
                p.num_ctx=Int(d,"num_ctx",2048,512,8192);
                p.num_predict=Int(d,"num_predict",p.num_predict,1,512);
                p.temperature=Number(d,"temperature",0,0,2);
                p.top_p=Number(d,"top_p",.9,.05,1);
                p.top_k=Int(d,"top_k",40,1,100);
                p.repeat_penalty=Number(d,"repeat_penalty",1.1,.8,2);
                p.num_thread=Int(d,"num_thread",0,0,32);
                p.num_gpu=Int(d,"num_gpu",-1,-1,99);
                p.seed=Int(d,"seed",-1,-1,Int32.MaxValue);
                p.keep_alive_minutes=Int(d,"keep_alive_minutes",30,1,240);
            }catch{} // Invalid configuration retains conservative defaults.
            return p;
        }
    }
    // Persistent local Ollama client. The sole output is validated enums.
    internal static class LocalNav
    {
        static readonly HttpClient client=CreateClient();
        static HttpClient CreateClient()
        {
            var handler=new HttpClientHandler{UseProxy=false};
            var http=new HttpClient(handler);
            http.Timeout=TimeSpan.FromSeconds(125);
            return http;
        }
        internal static string Prompt=@"Observe this SINGLE Counter-Strike 1.6 screenshot from an offline practice map.
Choose one safe short action. Do not assume invisible world coordinates.
FORWARD if there is a clear path. TURN_LEFT / TURN_RIGHT to explore a blocked path.
STRAFE_LEFT / STRAFE_RIGHT to avoid obstacles. WAIT if unclear.
ARRIVED only if visibly standing inside the marked bombsite, not when a sign is ahead.
Return only action and at_bombsite as strict JSON.";
        internal static long Metric(Dictionary<string,object> obj,string key,long divisor=1)
        {
            object raw;
            if(obj==null||!obj.TryGetValue(key,out raw)||raw==null)return -1;
            try{return Math.Max(0,Convert.ToInt64(raw)/divisor);}catch{return -1;}
        }
        internal static string DeepPrompt=Prompt+"\nAnalyze likely obstacles, uncertain spatial evidence and prior failure. Never claim movement from a single frame. Choose one conservative next action.";
        internal static NavigationPlan Parse(string response,string id)
        {
            if(String.IsNullOrEmpty(response)||response.Length>1024)throw new InvalidOperationException("Navigation JSON size rejected");
            object decoded=new JavaScriptSerializer().DeserializeObject(response);
            var d=decoded as Dictionary<string,object>;
            if(d==null||d.Count!=2||!d.ContainsKey("action")||!d.ContainsKey("at_bombsite"))
                throw new InvalidOperationException("Navigation JSON schema rejected");
            string move=d["action"] as string,bombsite=d["at_bombsite"] as string;
            if(move=="ARRIVED"&&bombsite!="yes")move="WAIT";
            var plan=new NavigationPlan{schema="reflexcore.cs16.navigation.v1",request_id=id,move=move,at_bombsite=bombsite,
                created_utc=DateTime.UtcNow.ToString("o")};
            if(!Guard.ApprovedNav(plan,id))throw new InvalidOperationException("Navigation enum rejected");
            return plan;
        }
        internal static NavInferenceResult Infer(string id,byte[] reusedJpeg,CancellationToken stop,string mode,string root)
        {
            stop.ThrowIfCancellationRequested();
            long captureMs=0;
            byte[] image=reusedJpeg;
            if(image==null)
            {
                NavFrame frame=GameVisionFrame.Capture();
                if(frame==null)throw new InvalidOperationException("Game capture failed");
                image=frame.jpeg;captureMs=frame.capture_ms;
            }
            if(image==null||image.Length<100||image.Length>2*1024*1024)
                throw new InvalidOperationException("Game image bounds rejected");
            stop.ThrowIfCancellationRequested();
            var choices=new string[]{"FORWARD","TURN_LEFT","TURN_RIGHT","STRAFE_LEFT","STRAFE_RIGHT","WAIT","ARRIVED"};
            var zones=new string[]{"yes","no","unknown"};
            var schema=new Dictionary<string,object>{
                {"type","object"},
                {"properties",new Dictionary<string,object>{
                    {"action",new Dictionary<string,object>{{"type","string"},{"enum",choices}}},
                    {"at_bombsite",new Dictionary<string,object>{{"type","string"},{"enum",zones}}}
                }},
                {"required",new string[]{"action","at_bombsite"}},
                {"additionalProperties",false}
            };
            // Re-read the operator's validated settings on every inference; no restart required.
            OllamaTuning tuned=OllamaTuning.Load(root,mode);
            var options=new Dictionary<string,object>{{"num_ctx",tuned.num_ctx},{"num_predict",tuned.num_predict},
                {"temperature",tuned.temperature},{"top_p",tuned.top_p},{"top_k",tuned.top_k},{"repeat_penalty",tuned.repeat_penalty}};
            if(tuned.num_thread>0)options["num_thread"]=tuned.num_thread;
            if(tuned.num_gpu>=0)options["num_gpu"]=tuned.num_gpu;
            if(tuned.seed>=0)options["seed"]=tuned.seed;
            var payload=new {
                model=tuned.model,prompt=mode=="deep"?DeepPrompt:Prompt,images=new string[]{Convert.ToBase64String(image)},
                format=schema,stream=false,keep_alive=tuned.keep_alive_minutes.ToString()+"m",options=options
            };
            image=null; // Do not retain images after encoding.
            string body=new JavaScriptSerializer().Serialize(payload);
            var watch=Stopwatch.StartNew();
            using(var content=new StringContent(body,Encoding.UTF8,"application/json"))
            using(HttpResponseMessage response=client.PostAsync("http://127.0.0.1:11434/api/generate",content,stop).GetAwaiter().GetResult())
            {
                stop.ThrowIfCancellationRequested();
                if(!response.IsSuccessStatusCode)throw new InvalidOperationException("Local Ollama returned HTTP "+(int)response.StatusCode);
                string result=response.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                watch.Stop();
                if(String.IsNullOrEmpty(result)||result.Length>100000)
                    throw new InvalidOperationException("Local Ollama response size rejected");
                var parseWatch=Stopwatch.StartNew();
                var outer=new JavaScriptSerializer().DeserializeObject(result) as Dictionary<string,object>;
                if(outer==null||!outer.ContainsKey("response")||!(outer["response"] is string))
                    throw new InvalidOperationException("Local Ollama result missing response");
                var plan=Parse((string)outer["response"],id);
                stop.ThrowIfCancellationRequested();
                parseWatch.Stop();
                return new NavInferenceResult{plan=plan,capture_ms=captureMs,
                    infer_ms=watch.ElapsedMilliseconds,parse_ms=parseWatch.ElapsedMilliseconds,
                    image_reused=reusedJpeg!=null,
                    load_ms=Metric(outer,"load_duration",1000000),
                    prompt_ms=Metric(outer,"prompt_eval_duration",1000000),
                    eval_ms=Metric(outer,"eval_duration",1000000),
                    prompt_tokens=Metric(outer,"prompt_eval_count"),
                    output_tokens=Metric(outer,"eval_count"),
                    model_id=tuned.model,ctx=tuned.num_ctx,predict=tuned.num_predict,
                    temperature=tuned.temperature,top_p=tuned.top_p};
            }
        }
    }
    public sealed class Frame
    {
        public long at {get;set;}
        public string kind {get;set;}
        public int value {get;set;}
        public int dx {get;set;}
        public int dy {get;set;}
    }
    public sealed class Demo
    {
        public int version {get;set;}
        public List<Frame> frames {get;set;}
    }
    // Deliberately minimal: only enumerated observations, never model-generated input commands.
    public sealed class VisionPlan
    {
        public string schema {get;set;}
        public string request_id {get;set;}
        public string decision {get;set;}
        public string has_c4 {get;set;}
        public string at_bombsite {get;set;}
        public string created_utc {get;set;}
    }
    // Only finite, fixed-duration motions are accepted across the vision/input boundary.
    public sealed class NavigationPlan
    {
        public string schema {get;set;}
        public string request_id {get;set;}
        public string move {get;set;}
        public string at_bombsite {get;set;}
        public string created_utc {get;set;}
    }
    internal static class Guard
    {
        internal const int HoldMs=3000;
        internal const int MaxEvents=16000;
        internal const int MaxDurationMs=120000;
        internal static bool Allowed(int vk)
        {
            // Explicit gameplay allowlist. No chat, console, passwords, or arbitrary text capture.
            return vk==0x57||vk==0x41||vk==0x53||vk==0x44||vk==0x20||
                   vk==0x10||vk==0x11||vk==0x45||vk==0x52||vk==0x51||
                   vk==0x31||vk==0x32||vk==0x33||vk==0x34||vk==0x35;
        }
        internal static void Validate(List<Frame> frames)
        {
            if(frames==null||frames.Count==0||frames.Count>MaxEvents)throw new Exception("Invalid demo event count");
            long old=-1;
            foreach(Frame e in frames)
            {
                if(e==null||e.at<old||e.at>MaxDurationMs)throw new Exception("Invalid demo timestamp");
                if(e.kind=="kd"||e.kind=="ku") {if(!Allowed(e.value))throw new Exception("Invalid gameplay key");}
                else if(e.kind=="move") {if(Math.Abs((long)e.dx)>300||Math.Abs((long)e.dy)>300)throw new Exception("Invalid mouse delta");}
                else if(e.kind!="ld"&&e.kind!="lu"&&e.kind!="rd"&&e.kind!="ru")throw new Exception("Invalid game input event");
                old=e.at;
            }
        }
        internal static bool IsPaused(long now,long until){return now<until;}
        internal static bool AllowedNav(string move){return move=="FORWARD"||move=="STRAFE_LEFT"||move=="STRAFE_RIGHT"||move=="TURN_LEFT"||move=="TURN_RIGHT"||move=="WAIT"||move=="ARRIVED";}
        internal static bool ApprovedNav(NavigationPlan p,string id)
        {
            return p!=null && p.schema=="reflexcore.cs16.navigation.v1" && p.request_id==id && AllowedNav(p.move) &&
                   (p.at_bombsite=="yes"||p.at_bombsite=="no"||p.at_bombsite=="unknown") &&
                   !(p.move=="ARRIVED"&&p.at_bombsite!="yes");
        }
        internal static bool ApprovedPlan(VisionPlan p,string id)
        {
            return p!=null && p.schema=="reflexcore.cs16.vision.plan.v1" &&
                   p.request_id==id && p.decision=="REQUEST_HUMAN_APPROVAL" &&
                   p.has_c4=="yes" && p.at_bombsite=="yes";
        }
    }
    public static class Lab
    {
        public static void SelfTest(string root)
        {
            if(!File.Exists(Path.Combine(root,"Cargo.toml")))throw new Exception("Project missing");
            if(!Guard.Allowed(0x35)||Guard.Allowed(0x54)||Guard.HoldMs!=3000)throw new Exception("Safety invariants failed");
            List<Frame> good=new List<Frame>();good.Add(new Frame{at=0,kind="kd",value=0x35});good.Add(new Frame{at=150,kind="ku",value=0x35});
            good.Add(new Frame{at=400,kind="ld"});good.Add(new Frame{at=4900,kind="lu"});Guard.Validate(good);
            Guard.Validate(new List<Frame>{new Frame{at=0,kind="kd",value=0x57},new Frame{at=1200,kind="ku",value=0x57}});
            bool rejected=false;try{Guard.Validate(new List<Frame>{new Frame{at=0,kind="kd",value=0x54}});}catch{rejected=true;}
            if(!rejected||!Guard.IsPaused(2999,3000)||Guard.IsPaused(3000,3000))throw new Exception("Safety validation failed");
            VisionPlan goodPlan=new VisionPlan{schema="reflexcore.cs16.vision.plan.v1",request_id="0123456789abcdef0123456789abcdef",decision="REQUEST_HUMAN_APPROVAL",has_c4="yes",at_bombsite="yes"};
            if(!Guard.ApprovedPlan(goodPlan,goodPlan.request_id)||Guard.ApprovedPlan(goodPlan,"wrong"))throw new Exception("Vision plan correlation failed");
            goodPlan.at_bombsite="unknown";
            if(Guard.ApprovedPlan(goodPlan,goodPlan.request_id))throw new Exception("Uncertain vision approved input");
            NavigationPlan nav=new NavigationPlan{schema="reflexcore.cs16.navigation.v1",request_id="0123456789abcdef0123456789abcdef",move="FORWARD",at_bombsite="unknown"};
            if(!Guard.ApprovedNav(nav,nav.request_id))throw new Exception("Navigation plan rejection");
            nav.move="ALT_F4";if(Guard.ApprovedNav(nav,nav.request_id))throw new Exception("Unsafe navigation accepted");
            byte[] sceneA=new byte[SceneProbe.Width*SceneProbe.Height];
            byte[] sceneB=new byte[sceneA.Length];
            if(SceneProbe.ChangePercent(sceneA,sceneB)!=0)throw new Exception("Scene comparison identical-frame test failed");
            for(int i=0;i<sceneB.Length;i++)sceneB[i]=255;
            if(SceneProbe.ChangePercent(sceneA,sceneB)!=100)throw new Exception("Scene comparison changed-frame test failed");
            if(SceneProbe.ChangePercent(null,sceneA)!=-1)throw new Exception("Scene comparison null-frame test failed");
            int[] evidence=SceneProbe.EstimateVisualFlow(sceneA,sceneA);
            if(evidence[2]!=0||evidence[0]!=0||evidence[1]!=0)throw new Exception("Flow evidence unchanged test failed");
            // Non-flat identical fingerprints must also report zero shift.
            for(int i=0;i<sceneA.Length;i++)sceneA[i]=(byte)((i*73)%251);
            evidence=SceneProbe.EstimateVisualFlow(sceneA,sceneA);
            if(evidence[2]!=0||evidence[0]!=0||evidence[1]!=0)throw new Exception("Flow evidence patterned-identical test failed");
            // No SendInput during self-tests. Validate event encoding only.
            int[] gameKeys=new int[]{0x57,0x41,0x53,0x44};
            int[] physicalScans=new int[]{0x11,0x1E,0x1F,0x20};
            for(int k=0;k<gameKeys.Length;k++)
            {
                Native.KEYINPUT down=Native.BuildKeyInput(gameKeys[k],true),up=Native.BuildKeyInput(gameKeys[k],false);
                if(down.vk!=0||down.scan!=physicalScans[k]||down.flags!=8u||up.scan!=down.scan||up.flags!=10u)
                    throw new Exception("Scan-code key encoding failed");
            }
            int inputSize=Marshal.SizeOf(typeof(Native.INPUT));
            if(inputSize!=(IntPtr.Size==8?40:28))throw new Exception("SendInput struct size failed");
            Native.KEYINPUT c4=Native.BuildKeyInput(0x35,true);
            if(c4.vk!=0x35||c4.flags!=0u)throw new Exception("C4 keyboard input compatibility failed");
            const string id="0123456789abcdef0123456789abcdef";
            NavigationPlan parsed=LocalNav.Parse("{\"action\":\"FORWARD\",\"at_bombsite\":\"unknown\"}",id);
            if(parsed.move!="FORWARD"||parsed.request_id!=id)throw new Exception("In-process navigation schema parsing failed");
            NavigationPlan uncertain=LocalNav.Parse("{\"action\":\"ARRIVED\",\"at_bombsite\":\"unknown\"}",id);
            if(uncertain.move!="WAIT")throw new Exception("False arrival was not rejected");
            bool invalid=false;
            try{LocalNav.Parse("{\"action\":\"ALT_F4\",\"at_bombsite\":\"no\"}",id);}catch{invalid=true;}
            if(!invalid)throw new Exception("Unsafe inference action allowed");
            invalid=false;
            try{LocalNav.Parse("{\"action\":\"FORWARD\",\"at_bombsite\":\"no\",\"command\":\"cmd\"}",id);}catch{invalid=true;}
            if(!invalid)throw new Exception("Unbounded inference property allowed");
            if(LocalNav.Metric(new Dictionary<string,object>{{"eval_duration",2000000L}},"eval_duration",1000000)!=2)
                throw new Exception("Ollama telemetry metric conversion failed");
            if(OllamaTuning.Load(root,"deep").model.Length<1 || OllamaTuning.Int(new Dictionary<string,object>{{"num_ctx",999999}},"num_ctx",2048,512,8192)!=2048)
                throw new Exception("Qwen settings validation failed");
            DateTime began=DateTime.UtcNow;
            if(LabWindow.IsNewStop(began.AddTicks(-1),began,DateTime.MinValue)
                || !LabWindow.IsNewStop(began.AddTicks(1),began,DateTime.MinValue)
                || LabWindow.IsNewStop(began.AddTicks(1),began,began.AddTicks(1)))
                throw new InvalidOperationException("Shared Control accepted a stale/duplicate emergency stop.");
            Console.WriteLine("[ReflexCore] Shared Control: safety, scan codes, Qwen JSON, timing, scene and stop freshness tests passed.");
        }
        [STAThread]
        public static void Run(string root)
        {
            bool first;
            using(System.Threading.Mutex m=new System.Threading.Mutex(true,@"Local\ReflexCoreCS16SharedControl",out first))
            {
                if(!first)throw new Exception("CS16 Shared Control is already running.");
                Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new LabWindow(root));
            }
        }
    }
    internal sealed class Hud : Form
    {
        readonly Label text;
        protected override bool ShowWithoutActivation { get {return true;} }
        protected override CreateParams CreateParams { get {CreateParams p=base.CreateParams;p.ExStyle|=0x20|0x80000|0x08000000;return p;} }
        public Hud()
        {
            FormBorderStyle=FormBorderStyle.None;ShowInTaskbar=false;TopMost=true;Width=570;Height=66;
            BackColor=Color.FromArgb(8,22,20);Opacity=.87;
            text=new Label{Dock=DockStyle.Fill,TextAlign=ContentAlignment.MiddleCenter,ForeColor=Color.FromArgb(162,255,116),Font=new Font("Consolas",12,FontStyle.Bold)};
            Controls.Add(text);Location=new Point(Screen.PrimaryScreen.WorkingArea.Right-Width-25,25);
        }
        public void Set(string value){text.Text=value;}
    }
    internal sealed class LabWindow:Form
    {
        readonly string root,privateFile;
        readonly Stopwatch clock=Stopwatch.StartNew();
        readonly System.Windows.Forms.Timer timer=new System.Windows.Forms.Timer();
        Native.HookProc keyboardCallback,mouseCallback;
        IntPtr kHook=IntPtr.Zero,mHook=IntPtr.Zero;
        readonly List<Frame> frames=new List<Frame>();
        readonly HashSet<int> recordedDown=new HashSet<int>();
        readonly HashSet<int> logicalDown=new HashSet<int>();
        readonly HashSet<int> injectedDown=new HashSet<int>();
        bool logicalLeft,logicalRight,injectedLeft,injectedRight;
        string state="IDLE",activeScript="";
        bool navActive=false;int navSteps=0;const int NavMaxSteps=8;long navNextCapture=0;
        readonly DateTime startedUtc=DateTime.UtcNow;
        DateTime lastGlobalStopUtc=DateTime.MinValue;long lastGlobalStopPoll=0;
        string unifiedSession=""; bool unifiedPending=false; // bounded local Rust coordinator session
        byte[] navBeforeFrame=null;
        string lastNavMove="NONE";
        int lastNavKeyDown=0,lastNavKeyUp=0,lastNavMouse=0;
        bool navUserIntervened=false;
        Task<NavInferenceResult> navVisionTask;
        CancellationTokenSource navVisionCancel;
        Task<NavFrame> navVerifyTask;
        long navFocusDeadline;
        long lastCaptureMs,lastInferMs,lastParseMs,lastRustMs,lastVerifyMs,lastInputMs,lastInputStarted,lastStepStarted;
        long lastLoadMs=-1,lastPromptMs=-1,lastEvalMs=-1,lastPromptTokens=-1,lastOutputTokens=-1;
        string lastModelId="";int lastNumCtx=0,lastNumPredict=0;double lastTemperature=0,lastTopP=0;
        int lastFlowDx=0,lastFlowDy=0,lastFlowGain=0;
        bool lastFrameReused;
        IntPtr cachedForeground=IntPtr.Zero;
        bool cachedGameResult=false;
        long cachedForegroundChecked=0;
        bool visibleTestPending=false;byte[] visibleTestBefore=null;long visibleTestDeadline=0;
        readonly Queue<string> navHistory=new Queue<string>();
        string navStage="WAITING FOR CS";
        Process visionProcess;
        string visionId="",visionFile="";
        long visionStarted,visionReadyAt;
        bool recordPending=false,mouseWasKnown=false;
        long recordAt,recordBeginning,playAt,elapsedPlaying,lastTick,pauseUntil;
        int next,mouseX,mouseY;
        readonly Label summary,details;
        readonly TextBox activity;
        readonly CheckBox trackMouse;
        readonly ComboBox navMode;
        string activeNavMode="auto";
        readonly Button recordButton,replayButton,plantButton,stopButton,visionButton,approveButton,navButton,visibleTestButton;
        readonly Hud hud=new Hud();
        readonly Color dark=Color.FromArgb(12,22,24),green=Color.FromArgb(172,255,111);
        // Operator Console 0.4.9: task-first UI; fixed navigation and input invariants are unchanged.
        public LabWindow(string project)
        {
            root=project;privateFile=Path.Combine(root,"data","private","cs16-local-demo.json");
            Text="ReflexCore  |  Shared Control";
            Width=920;Height=740;MinimumSize=new Size(720,610);StartPosition=FormStartPosition.CenterScreen;
            AutoScaleMode=AutoScaleMode.Dpi;
            BackColor=dark;ForeColor=Color.FromArgb(221,238,229);Font=new Font("Segoe UI",10);

            TableLayoutPanel shell=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=3,BackColor=dark,Margin=new Padding(0),Padding=new Padding(0)};
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute,93));
            shell.RowStyles.Add(new RowStyle(SizeType.Percent,100));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute,173));
            Controls.Add(shell);
            Panel header=new Panel{Dock=DockStyle.Fill,Height=93,BackColor=Color.FromArgb(17,30,33),Padding=new Padding(22,14,22,10)};
            var brand=new Label{Text="REFLEXCORE    /    OPERATOR",Dock=DockStyle.Top,Height=35,
                ForeColor=green,Font=new Font("Consolas",17,FontStyle.Bold)};
            var description=new Label{Text="Shared Control · CS 1.6  |  Physical mouse or keyboard input pauses the agent for 3 seconds",
                Dock=DockStyle.Fill,Font=new Font("Segoe UI",9.5f),ForeColor=Color.FromArgb(168,192,182)};
            header.Controls.Add(description);header.Controls.Add(brand);

            // Status and STOP remain visible on every tab, including when detailed logs are hidden.
            Panel statusPanel=new Panel{Dock=DockStyle.Fill,Height=173,BackColor=Color.FromArgb(20,34,35),Padding=new Padding(22,10,22,10)};
            stopButton=MakeButton("■  STOP / SAVE RECORDING",delegate{StopCurrent(true);},false);
            stopButton.BackColor=Color.FromArgb(93,37,44);
            stopButton.FlatAppearance.BorderColor=Color.FromArgb(156,77,79);
            stopButton.Dock=DockStyle.Bottom;stopButton.Height=49;
            summary=new Label{Dock=DockStyle.Top,Height=36,Text="READY",ForeColor=green,
                Font=new Font("Consolas",15,FontStyle.Bold),AutoEllipsis=true};
            details=new Label{Dock=DockStyle.Fill,
                Text="Choose a mode and switch to CS 1.6 when prompted. Press F12 or Ctrl+Alt+P to stop.",
                ForeColor=Color.FromArgb(191,211,199),Font=new Font("Segoe UI",9.5f),AutoEllipsis=true};
            statusPanel.Controls.Add(details);statusPanel.Controls.Add(summary);statusPanel.Controls.Add(stopButton);
            
            TabControl tabs=new TabControl{Dock=DockStyle.Fill,Font=new Font("Segoe UI",10,FontStyle.Bold),
                Padding=new Point(14,8),DrawMode=TabDrawMode.OwnerDrawFixed,SizeMode=TabSizeMode.Fixed,ItemSize=new Size(135,35)};
            tabs.DrawItem+=delegate(object sender,DrawItemEventArgs e){
                bool selected=e.Index==tabs.SelectedIndex;
                using(Brush background=new SolidBrush(selected?Color.FromArgb(34,73,54):Color.FromArgb(17,29,30)))
                    e.Graphics.FillRectangle(background,e.Bounds);
                TextRenderer.DrawText(e.Graphics,tabs.TabPages[e.Index].Text,tabs.Font,e.Bounds,
                    selected?green:Color.FromArgb(170,195,179),TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter);
            };
            shell.Controls.Add(header,0,0);
            shell.Controls.Add(tabs,0,1);
            shell.Controls.Add(statusPanel,0,2);
            TabPage pilot=MakePage("Navigation");
            TabPage planting=MakePage("Plant C4");
            TabPage recording=MakePage("Demonstrations");
            TabPage journal=MakePage("Diagnostics");
            tabs.TabPages.AddRange(new TabPage[]{pilot,planting,recording,journal});

            TableLayoutPanel pilotGrid=PageGrid(7);
            pilotGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,52));
            pilotGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,70));
            pilotGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,66));
            pilotGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,78));
            pilotGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,50));
            pilotGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,76));
            pilotGrid.RowStyles.Add(new RowStyle(SizeType.Percent,100));
            pilotGrid.Controls.Add(PageTitle("Screen navigation"),0,0);
            navButton=MakeButton("▶   START AI NAVIGATION",delegate{StartNavigation();},true);
            pilotGrid.Controls.Add(navButton,0,1);
            visibleTestButton=MakeButton("TEST KEYBOARD INPUT · HOLD W FOR 1.2 S",delegate{StartVisibleInputTest();},false);
            pilotGrid.Controls.Add(visibleTestButton,0,2);
            pilotGrid.Controls.Add(PageNote("Qwen selects a short action from a screen capture. The agent checks how the image changes after each action, up to eight steps."),0,3);
            Panel modePanel=new Panel{Dock=DockStyle.Fill};
            var modeLabel=new Label{Text="THINKING MODE",Dock=DockStyle.Left,Width=180,TextAlign=ContentAlignment.MiddleLeft,ForeColor=green,
                Font=new Font("Consolas",11,FontStyle.Bold)};
            navMode=new ComboBox{Dock=DockStyle.Fill,DropDownStyle=ComboBoxStyle.DropDownList,
                BackColor=Color.FromArgb(29,48,45),ForeColor=Color.White,Font=new Font("Segoe UI",10)};
            navMode.Items.AddRange(new object[]{"Auto","Reflex","Focused","Deep"});navMode.SelectedIndex=0;
            modePanel.Controls.Add(navMode);modePanel.Controls.Add(modeLabel);
            pilotGrid.Controls.Add(modePanel,0,4);
            pilotGrid.Controls.Add(PageNote("Start navigation, then switch to CS 1.6 to observe.\nPhysical input pauses the agent for three seconds. Press F12 or Ctrl+Alt+P to stop."),0,5);
            CheckBox hudToggle=new CheckBox{Text="Show a compact status overlay in the game",Dock=DockStyle.Top,Height=30,
                ForeColor=Color.FromArgb(192,217,198),Checked=true,Margin=new Padding(4,12,4,4)};
            hudToggle.CheckedChanged+=delegate{
                if(hudToggle.Checked){hud.Show(TopLevelControl as Form);hud.Set("REFLEXCORE | "+summary.Text);}else hud.Hide();
            };
            pilotGrid.Controls.Add(hudToggle,0,6);pilot.Controls.Add(pilotGrid);
            Shown+=delegate{if(hudToggle.Checked){hud.Show(TopLevelControl as Form);hud.Set("REFLEXCORE | IDLE - NO INPUT");}};

            TableLayoutPanel plantGrid=PageGrid(7);
            plantGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,52));
            plantGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,68));
            plantGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,54));
            plantGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,68));
            plantGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,66));
            plantGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,64));
            plantGrid.RowStyles.Add(new RowStyle(SizeType.Percent,100));
            plantGrid.Controls.Add(PageTitle("Plant C4 with approval"),0,0);
            visionButton=MakeButton("1   CHECK C4 AND BOMBSITE WITH QWEN",delegate{StartVisionPlan();},true);
            plantGrid.Controls.Add(visionButton,0,1);
            plantGrid.Controls.Add(PageNote("Return to the game. The approval button becomes available when Qwen reports both C4 and a bombsite."),0,2);
            approveButton=MakeButton("2   APPROVE PLANTING",delegate{ApproveVisionPlant();},true);
            approveButton.Enabled=false;plantGrid.Controls.Add(approveButton,0,3);
            plantGrid.Controls.Add(PageNote("You have 30 seconds to approve. The drill sends the plant inputs at your current position."),0,4);
            plantButton=MakeButton("RUN PLANT C4 DRILL",delegate{StartReplay(true);},false);
            plantGrid.Controls.Add(plantButton,0,5);planting.Controls.Add(plantGrid);

            TableLayoutPanel recordGrid=PageGrid(6);
            recordGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,52));
            recordGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,68));
            recordGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,60));
            recordGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,68));
            recordGrid.RowStyles.Add(new RowStyle(SizeType.Absolute,55));
            recordGrid.RowStyles.Add(new RowStyle(SizeType.Percent,100));
            recordGrid.Controls.Add(PageTitle("Record a demonstration"),0,0);
            recordButton=MakeButton("●   START RECORDING",delegate{StartRecord();},true);
            recordGrid.Controls.Add(recordButton,0,1);
            recordGrid.Controls.Add(PageNote("Start recording and switch to CS 1.6. Demonstrate the movements, then press Stop to save locally."),0,2);
            replayButton=MakeButton("▶   REPLAY DEMONSTRATION",delegate{StartReplay(false);},false);
            recordGrid.Controls.Add(replayButton,0,3);
            trackMouse=new CheckBox{Dock=DockStyle.Top,Height=44,ForeColor=Color.FromArgb(190,210,194),
                Text="Include mouse movements (experimental)",Checked=false};
            recordGrid.Controls.Add(trackMouse,0,4);
            recordGrid.Controls.Add(PageNote("Recording captures selected game controls while CS 1.6 is in the foreground. The recording stays on this computer."),0,5);
            recording.Controls.Add(recordGrid);

            var journalPanel=new Panel{Dock=DockStyle.Fill,Padding=new Padding(3,10,3,3)};
            var journalTitle=PageTitle("Agent events · In memory");
            journalTitle.Dock=DockStyle.Top;journalTitle.Height=41;
            activity=new TextBox{Dock=DockStyle.Fill,ReadOnly=true,Multiline=true,ScrollBars=ScrollBars.Both,
                BackColor=Color.FromArgb(6,17,20),ForeColor=green,Font=new Font("Consolas",9),WordWrap=false,TabStop=false};
            journalPanel.Controls.Add(activity);journalPanel.Controls.Add(journalTitle);journal.Controls.Add(journalPanel);

            FormClosing+=delegate{timer.Stop();StopCurrent(false);UninstallHooks();try{hud.Close();}catch{}};
            keyboardCallback=Keyboard;mouseCallback=Mouse;
            IntPtr module=Native.GetModuleHandle(null);
            kHook=Native.SetWindowsHookEx(13,keyboardCallback,module,0);
            mHook=Native.SetWindowsHookEx(14,mouseCallback,module,0);
            if(kHook==IntPtr.Zero||mHook==IntPtr.Zero)
            {UninstallHooks();throw new Exception("Failed to install low-level input hooks. Run without elevation first.");}
            timer.Interval=20;timer.Tick+=Tick;timer.Start();lastTick=clock.ElapsedMilliseconds;
            LoadDemo();hud.Set("REFLEXCORE | IDLE - NO INPUT");
            Trace("Operator Console 0.4.9 ready. Shared Control is idle until started.");
        }
        TabPage MakePage(string title)
        {
            var page=new TabPage(title){BackColor=dark,ForeColor=this.ForeColor,Padding=new Padding(18,18,18,10)};
            return page;
        }
        TableLayoutPanel PageGrid(int rows)
        {
            return new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=rows,AutoScroll=true,
                Padding=new Padding(8),BackColor=dark};
        }
        Label PageTitle(string label)
        {
            return new Label{Dock=DockStyle.Fill,Text=label,TextAlign=ContentAlignment.MiddleLeft,
                ForeColor=green,Font=new Font("Segoe UI",13,FontStyle.Bold),Margin=new Padding(2,2,2,4)};
        }
        Label PageNote(string note)
        {
            return new Label{Dock=DockStyle.Fill,Text=note.Replace("\\n",Environment.NewLine),
                ForeColor=Color.FromArgb(186,206,192),Font=new Font("Segoe UI",9.5f),
                Margin=new Padding(3,7,5,3),AutoEllipsis=true};
        }
        Button MakeButton(string label,Action action,bool primary)
        {
            var b=new Button{Dock=DockStyle.Fill,Text=label,BackColor=primary?Color.FromArgb(39,83,60):Color.FromArgb(28,45,43),
                ForeColor=primary?green:Color.FromArgb(213,236,214),FlatStyle=FlatStyle.Flat,
                Font=new Font("Segoe UI",10,FontStyle.Bold),Margin=new Padding(2,5,4,7)};
            b.FlatAppearance.BorderColor=primary?Color.FromArgb(93,149,103):Color.FromArgb(59,95,77);
            b.Click+=delegate{try{action();}catch(Exception ex){StopCurrent(false);MessageBox.Show(ex.Message,"ReflexCore Shared Control",MessageBoxButtons.OK,MessageBoxIcon.Warning);}};
            return b;
        }
        void UninstallHooks()
        {
            if(kHook!=IntPtr.Zero){Native.UnhookWindowsHookEx(kHook);kHook=IntPtr.Zero;}
            if(mHook!=IntPtr.Zero){Native.UnhookWindowsHookEx(mHook);mHook=IntPtr.Zero;}
        }
        bool GameForeground(bool force=false)
        {
            try
            {
                IntPtr hwnd=Native.GetForegroundWindow();
                if(hwnd==IntPtr.Zero)return false;
                if(!force && hwnd==cachedForeground && Now-cachedForegroundChecked<250)return cachedGameResult;
                cachedForeground=hwnd;cachedForegroundChecked=Now;cachedGameResult=false;
                uint pid;Native.GetWindowThreadProcessId(hwnd,out pid);
                if(pid==0)return false;
                using(Process p=Process.GetProcessById((int)pid))
                {
                    string name=p.ProcessName.ToLowerInvariant();
                    cachedGameResult=name=="hl"||name=="cstrike";
                    return cachedGameResult;
                }
            }catch{return false;}
        }
        long Now {get{return clock.ElapsedMilliseconds;}}
        void Trace(string message)
        {
            if(activity==null||activity.IsDisposed)return;
            string line=DateTime.Now.ToString("HH:mm:ss")+"  "+message;
            string[] lines=(activity.Text+line+Environment.NewLine).Split(new string[]{Environment.NewLine},StringSplitOptions.RemoveEmptyEntries);
            int from=Math.Max(0,lines.Length-28);
            activity.Lines=new List<string>(new ArraySegment<string>(lines,from,lines.Length-from)).ToArray();
            activity.SelectionStart=activity.TextLength;activity.ScrollToCaret();
        }
        void ShowState(string s,string d)
        {
            summary.Text=s;details.Text=d;hud.Set("REFLEXCORE | "+s);
            Trace(s);
        }
        // Local enumerated diagnostics only. Never write screenshots, window titles or model output.
        void SaveInputDiagnostic(string mode,string outcome,int change)
        {
            try
            {
                string folder=Path.Combine(root,"data","private","cs16-auto");
                Directory.CreateDirectory(folder);
                string path=Path.Combine(folder,"input-diagnostic.json");
                var record=new {
                    schema="reflexcore.input.diagnostic.v1",mode=mode,outcome=outcome,
                    move=lastNavMove,key_down=lastNavKeyDown,key_up=lastNavKeyUp,
                    mouse_events=lastNavMouse,scene_change_percent=change,
                    capture_ms=lastCaptureMs,infer_ms=lastInferMs,parse_ms=lastParseMs,
                    rust_decide_ms=lastRustMs,verify_capture_ms=lastVerifyMs,input_ms=lastInputMs,
                    next_frame_reused=lastFrameReused,cycle_ms=lastStepStarted==0?0:Now-lastStepStarted,
                    nav_ollama_transport="in_process_http",rust_transport="persistent_stdio",
                    thinking_mode=activeNavMode,
                    ollama_load_ms=lastLoadMs,ollama_prompt_ms=lastPromptMs,ollama_eval_ms=lastEvalMs,
                    ollama_prompt_tokens=lastPromptTokens,ollama_output_tokens=lastOutputTokens,
                    model_id=lastModelId,model_num_ctx=lastNumCtx,model_num_predict=lastNumPredict,
                    model_temperature=lastTemperature,model_top_p=lastTopP,
                    movement_verified=false,visual_flow_dx=lastFlowDx,visual_flow_dy=lastFlowDy,
                    visual_flow_gain_percent=lastFlowGain, 
                    note="SendInput accepted is not proof of game input or movement"
                };
                string temp=path+".tmp";
                string json=new JavaScriptSerializer().Serialize(record);
                File.WriteAllText(temp,json);
                if(File.Exists(path))File.Delete(path);
                File.Move(temp,path);
                // Bounded, enum-only performance history. Never persist images, prompts or raw LLM text.
                string perf=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ReflexCore","diagnostics");
                Directory.CreateDirectory(perf);
                string history=Path.Combine(perf,"nav-performance.jsonl");
                if(File.Exists(history)&&new FileInfo(history).Length>262144)File.Delete(history);
                File.AppendAllText(history,json+Environment.NewLine);
            }
            catch{Trace("Diagnostic write unavailable; no gameplay effect");}
        }
        private string lastTrayStage="";
        private long lastTrayStageAt=0;
        // Low-overhead, enum-only progress channel. No frame/text/LLM output ever persisted.
        void TrayActivity(string stage)
        {
            if(stage==lastTrayStage && Now-lastTrayStageAt<1200)return;
            lastTrayStage=stage;lastTrayStageAt=Now;
            try
            {
                string dir=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "ReflexCore","runtime");
                Directory.CreateDirectory(dir);
                string json=new JavaScriptSerializer().Serialize(new {schema="reflexcore.activity.v1",
                    source="shared_control",stage=stage,action="none",sequence=navSteps,
                    elapsed_ms=lastInferMs,at_utc=DateTime.UtcNow.ToString("o",System.Globalization.CultureInfo.InvariantCulture)});
                File.WriteAllText(Path.Combine(dir,"activity.json"),json);
            }
            catch {} // Never allow the tray to delay, interrupt or authorize UI actions.
        }
        void UpdateTrayActivity()
        {
            if(state=="NAV_FOCUS")TrayActivity("observing");
            else if(state=="NAV_PLAN"||state=="AI_PLAN")TrayActivity("thinking");
            else if(state=="NAV_VERIFY"||state=="VISIBLE_TEST_VERIFY")TrayActivity("verifying");
            else if(state=="NAV_WAIT")TrayActivity(navUserIntervened?"human_override":"awaiting_effect");
            else if(state=="PLAY")TrayActivity("executing");
            else if(state=="RECORD")TrayActivity("observing");
            else if(state=="AI_READY")TrayActivity("ready");
            else if(lastTrayStage!="" && lastTrayStage!="stopped")TrayActivity("stopped");
        }
        void VisionOutput(string line)
        {
            if(String.IsNullOrEmpty(line)||IsDisposed)return;
            if(InvokeRequired){try{BeginInvoke((Action)(()=>VisionOutput(line)));}catch{}return;}
            // Read only enumerated child milestones. Never persist private UI text or screenshots.
            if(line.Contains("WAITING FOR CS")){navStage="WAITING FOR CS";return;}
            if(line.Contains("GAME FOCUSED")){navStage="CAPTURING";Trace("CS foreground confirmed; taking one frame");return;}
            if(line.Contains("Screenshot in RAM")){navStage="THINKING";Trace("Frame captured in memory; Qwen inference started");return;}
            if(line.Contains("Waiting for Ollama:")){navStage="THINKING";Trace("Ollama still processing; no input has been sent");return;}
            if(line.Contains("Ollama responded in")){navStage="VALIDATING";Trace("Ollama responded; validating bounded navigation decision");return;}
            if(line.Contains("NAVIGATION:")){
                navStage="DECIDING";
                string[] choices={"FORWARD","STRAFE_LEFT","STRAFE_RIGHT","TURN_LEFT","TURN_RIGHT","ARRIVED","WAIT"};
                foreach(string item in choices)if(line.Contains("NAVIGATION: "+item+",")){Trace("Qwen selected "+item);break;}
            }
        }
        void SaveDemo()
        {
            if(frames.Count==0)return;
            Guard.Validate(frames);
            Directory.CreateDirectory(Path.GetDirectoryName(privateFile));
            var json=new JavaScriptSerializer();json.MaxJsonLength=1024*1024;
            string output=json.Serialize(new Demo{version=1,frames=new List<Frame>(frames)});
            string temp=privateFile+".tmp";File.WriteAllText(temp,output);
            if(File.Exists(privateFile))File.Delete(privateFile);
            File.Move(temp,privateFile);
        }
        void LoadDemo()
        {
            if(!File.Exists(privateFile))return;
            FileInfo fi=new FileInfo(privateFile);if(fi.Length>1024*1024)throw new Exception("Demo file too large");
            var json=new JavaScriptSerializer();json.MaxJsonLength=1024*1024;
            Demo d=json.Deserialize<Demo>(File.ReadAllText(privateFile));
            if(d==null||d.version!=1)throw new Exception("Demo format mismatch");Guard.Validate(d.frames);
            frames.Clear();frames.AddRange(d.frames);
        }
        void CancelVision()
        {
            if(navVisionCancel!=null)
            {
                try{navVisionCancel.Cancel();}catch{}
                navVisionCancel=null;
            }
            navVisionTask=null;navVerifyTask=null;
            if(visionProcess!=null)
            {
                try{if(!visionProcess.HasExited)visionProcess.Kill();}catch{}
                try{visionProcess.Dispose();}catch{}
                visionProcess=null;
            }
            try{if(!String.IsNullOrEmpty(visionFile)&&File.Exists(visionFile))File.Delete(visionFile);}catch{}
            visionFile="";visionId="";
            if(approveButton!=null)approveButton.Enabled=false;
        }
        void StartVisionPlan()
        {
            StopCurrent(false);
            string script=Path.Combine(root,"tools","ReflexCore-LocalVision-CS16.ps1");
            if(!File.Exists(script))throw new Exception("Install Vision Gate 0.4.5 first.");
            string folder=Path.Combine(root,"data","private","cs16-auto");
            Directory.CreateDirectory(folder);
            visionId=Guid.NewGuid().ToString("N");
            visionFile=Path.Combine(folder,"plan-"+visionId+".json");
            string exe=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe");
            string args="-NoProfile -ExecutionPolicy Bypass -File \""+script+"\" -Action Plan -ImageWidth 512 -TimeoutSec 150 -RequestId "+visionId+" -DecisionFile \""+visionFile+"\"";
            var psi=new ProcessStartInfo{FileName=exe,Arguments=args,WorkingDirectory=root,UseShellExecute=false,CreateNoWindow=true};
            visionProcess=Process.Start(psi);
            if(visionProcess==null)throw new Exception("Failed to start local Qwen observer.");
            state="AI_PLAN";visionStarted=Now;
            ShowState("QWEN VISION · ANALYZING","Switch to CS 1.6 within five seconds. The screenshot stays in memory. Input requires separate approval. Analysis may take 20–150 seconds.");
        }
        void FinishVisionPlan()
        {
            int exit=visionProcess.ExitCode;
            visionProcess.Dispose();visionProcess=null;
            VisionPlan result=null;
            bool recent=false;
            try
            {
                if(exit==0&&File.Exists(visionFile))
                {
                    FileInfo fi=new FileInfo(visionFile);
                    if(fi.Length>0&&fi.Length<=2048&&Math.Abs((DateTime.UtcNow-fi.LastWriteTimeUtc).TotalSeconds)<=120)
                    {
                        var json=new JavaScriptSerializer();result=json.Deserialize<VisionPlan>(File.ReadAllText(visionFile));recent=true;
                    }
                }
            }
            catch {result=null;}
            bool approved=recent&&Guard.ApprovedPlan(result,visionId);
            try{if(File.Exists(visionFile))File.Delete(visionFile);}catch{}
            visionFile="";visionId="";
            if(approved)
            {
                state="AI_READY";visionReadyAt=Now;approveButton.Enabled=true;
                ShowState("QWEN: C4 + BOMBSITE VISIBLE","Qwen proposed planting. Confirm that you are a Terrorist carrying C4 inside a bombsite, then approve within 30 seconds. Switch back to the game within three seconds of approval.");
            }
            else
            {
                state="IDLE";
                ShowState("QWEN: NO AUTHORIZED ACTION",exit==0?"The check did not produce current evidence of both C4 and a bombsite. No input was sent.":"The local vision check failed. Check Ollama and try again. No input was sent.");
            }
        }
        void ApproveVisionPlant()
        {
            if(state!="AI_READY"||!approveButton.Enabled)throw new Exception("No validated pending AI plan.");
            if(Now-visionReadyAt>30000) {StopCurrent(false);throw new Exception("Vision plan expired; capture a new frame.");}
            StartReplay(true); // The only permitted action is the known, fixed 5 + LMB plant drill.
        }
        // 0.5.3: persistent, parent-only stdio pipe to one local Rust child process.
        // No named socket, listening pipe, shell, user-provided executable or filesystem command queue.
        Process rustRuntime;
        void CloseRustRuntime()
        {
            Process p=rustRuntime;rustRuntime=null;
            if(p==null)return;
            try{if(!p.HasExited)p.Kill();}catch{}
            try{p.Dispose();}catch{}
        }
        string Brain(params string[] tokens)
        {
            if(tokens.Length==0 || tokens.Length>5)throw new InvalidOperationException("Invalid runtime request count");
            foreach(string token in tokens)
            {
                if(String.IsNullOrEmpty(token)||token.Length>64)throw new InvalidOperationException("Bad IPC token");
                foreach(char c in token)
                    if(!((c>='A'&&c<='Z')||(c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='_'||c=='-'))
                        throw new InvalidOperationException("Unsafe runtime token");
            }
            string op=tokens[0];
            if(Array.IndexOf(new[]{"protocol","begin","mode","decide","feedback","reflex","cancel","status"},op)<0)
                throw new InvalidOperationException("Unsupported runtime command");
            if(rustRuntime==null)
            {
                string exe=Path.Combine(root,"target","release","reflexcore.exe");
                if(!File.Exists(exe))throw new InvalidOperationException("Rust 0.5.3 runtime not built");
                var psi=new ProcessStartInfo{FileName=exe,Arguments="unified serve",
                    WorkingDirectory=root,UseShellExecute=false,RedirectStandardInput=true,
                    RedirectStandardOutput=true,CreateNoWindow=true};
                rustRuntime=Process.Start(psi);
                if(rustRuntime==null)throw new InvalidOperationException("Cannot start local Rust runtime");
                rustRuntime.StandardInput.AutoFlush=true;
            }
            try
            {
                var req=new Dictionary<string,object>();
                req["schema"]="reflexcore.runtime.request.v1";
                string id=Guid.NewGuid().ToString("N");
                req["id"]=id;
                req["op"]=op;
                if(op!="protocol")
                {
                    if(tokens.Length<2)throw new InvalidOperationException("Missing runtime session");
                    req["session"]=tokens[1];
                }
                if(op=="decide")
                {
                    if(tokens.Length!=5)throw new InvalidOperationException("Bad decide length");
                    req["sequence"]=Int32.Parse(tokens[2]);req["observed"]=tokens[3];req["zone"]=tokens[4];
                }
                else if(op=="feedback")
                {
                    if(tokens.Length!=4)throw new InvalidOperationException("Bad feedback length");
                    req["sequence"]=Int32.Parse(tokens[2]);req["outcome"]=tokens[3];
                }
                else if(op=="mode")
                {
                    if(tokens.Length!=3)throw new InvalidOperationException("Bad mode request");
                    req["observed"]=tokens[2];
                }
                else if(op=="reflex")
                {
                    if(tokens.Length!=3)throw new InvalidOperationException("Bad reflex length");
                    req["sequence"]=Int32.Parse(tokens[2]);
                }
                else if(tokens.Length!=(op=="protocol"?1:2))throw new InvalidOperationException("Invalid runtime request");
                string json=new JavaScriptSerializer().Serialize(req);
                if(json.Length>700)throw new InvalidOperationException("Runtime request too large");
                rustRuntime.StandardInput.WriteLine(json);
                Task<string> read=rustRuntime.StandardOutput.ReadLineAsync();
                if(!read.Wait(750))throw new InvalidOperationException("Rust runtime timeout");
                string output=read.Result;
                if(String.IsNullOrEmpty(output)||output.Length>4608)throw new InvalidOperationException("Rust runtime response size invalid");
                var response=new JavaScriptSerializer().DeserializeObject(output) as Dictionary<string,object>;
                if(response==null || response.Count!=4 ||
                   !Object.Equals(response["schema"],"reflexcore.runtime.response.v1") ||
                   !Object.Equals(response["id"],id) || !Object.Equals(response["ok"],true) ||
                   !(response["value"] is string))throw new InvalidOperationException("Rust runtime rejected request");
                return (string)response["value"];
            }
            catch {CloseRustRuntime();throw;}
        }
        void StartNavigation()
        {
            StopCurrent(false);
            if(Brain("protocol")!="reflexcore.unified.cli.v1")
                throw new Exception("Rust coordinator protocol mismatch");
            unifiedSession=Guid.NewGuid().ToString("N");unifiedPending=false;
            if(Brain("begin",unifiedSession)!="READY")throw new Exception("Rust coordinator refused a new session");
            activeNavMode=navMode.SelectedItem.ToString().ToLowerInvariant();
            if(Brain("mode",unifiedSession,activeNavMode)!="MODE:"+activeNavMode)
                throw new Exception("Thinking mode was not accepted by Rust");
            if(activeNavMode=="reflex")
            {
                StopCurrent(false);
                ShowState("REFLEX · NO WORLD STATE","Reflex-only mode cannot safely choose an initial direction without observations. Use Auto to seed the world state via Qwen; the recovery reflex then needs no LLM.");
                return;
            }
            navActive=true;navSteps=0;pauseUntil=0;navHistory.Clear();
            navBeforeFrame=null;navUserIntervened=false;
            lastNavMove="NONE";lastNavKeyDown=lastNavKeyUp=lastNavMouse=0;
            lastCaptureMs=lastInferMs=lastParseMs=lastRustMs=lastVerifyMs=lastInputMs=lastStepStarted=0;
            lastLoadMs=lastPromptMs=lastEvalMs=lastPromptTokens=lastOutputTokens=-1;lastFlowDx=lastFlowDy=lastFlowGain=0;
            Trace("Navigation requested; focus CS (window switch may take up to 20 seconds)");
            StartNavVision(true);
        }
        void StartNavVision(bool initial,byte[] imageFromVerification=null)
        {
            if(!navActive)return;
            if(navSteps>=NavMaxSteps)
            {
                StopCurrent(false);
                ShowState("NAVIGATION LIMIT","Reached 8 bounded decisions. No further input.");
                return;
            }
            if(initial)
            {
                state="NAV_FOCUS";navStage="WAITING FOR CS";navFocusDeadline=Now+20000;
                ShowState("NAV · WAITING FOR CS","Switch to offline CS 1.6. The model starts only after CS is foreground. Stop with F12 / Ctrl+Alt+P.");
                return;
            }
            if(!GameForeground())
            {
                StopCurrent(false);ShowState("NAV STOP · GAME UNFOCUSED","No private screenshot or input attempted.");
                return;
            }
            visionId=Guid.NewGuid().ToString("N");
            string id=visionId;
            navVisionCancel=new CancellationTokenSource();
            navVisionCancel.CancelAfter(120000);
            CancellationToken stop=navVisionCancel.Token;
            navStage=imageFromVerification!=null?"THINKING · FRAME REUSED":"CAPTURING / THINKING";
            state="NAV_PLAN";visionStarted=Now;
            lastFrameReused=imageFromVerification!=null;
            lastStepStarted=Now;
            navVisionTask=Task.Run(()=>LocalNav.Infer(id,imageFromVerification,stop,activeNavMode,root),stop);
            ShowState("NAV · "+navStage,"Local Ollama inference runs off the UI thread. No screenshot, prompt or response is written to disk.");
        }
        List<Frame> NavFrames(string move)
        {
            List<Frame> output=new List<Frame>();int key=0;int duration=0;
            if(move=="FORWARD"){key=0x57;duration=850;}
            else if(move=="STRAFE_LEFT"){key=0x41;duration=600;}
            else if(move=="STRAFE_RIGHT"){key=0x44;duration=600;}
            else if(move=="TURN_LEFT")output.Add(new Frame{at=0,kind="move",dx=-55,dy=0});
            else if(move=="TURN_RIGHT")output.Add(new Frame{at=0,kind="move",dx=55,dy=0});
            if(key!=0){output.Add(new Frame{at=0,kind="kd",value=key});output.Add(new Frame{at=duration,kind="ku",value=key});}
            Guard.Validate(output);return output;
        }
        void FinishNavVision()
        {
            Task<NavInferenceResult> task=navVisionTask;
            navVisionTask=null;
            if(task==null||task.IsCanceled||task.IsFaulted)
            {
                string category="INFERENCE_FAILED";
                if(task!=null && task.IsCanceled)category="INFERENCE_CANCELLED";
                else if(task!=null && task.IsFaulted)
                {
                    Exception error=task.Exception.GetBaseException();
                    if(error is OperationCanceledException)category="INFERENCE_TIMEOUT_OR_CANCELLED";
                    else if(error is HttpRequestException)category="OLLAMA_CONNECTION_FAILED";
                    else if(error is InvalidOperationException)
                    {
                        // Controlled error categories only; never log model text or private window titles.
                        if(error.Message.Contains("capture"))category="CAPTURE_FAILED";
                        else if(error.Message.Contains("JSON")||error.Message.Contains("enum"))category="MODEL_SCHEMA_REJECTED";
                        else if(error.Message.Contains("HTTP"))category="OLLAMA_HTTP_ERROR";
                    }
                }
                SaveInputDiagnostic("AI_NAV",category,-1);
                StopCurrent(false);
                ShowState("NAV STOP · "+category,"No input was sent for this decision. See local diagnostic JSON for stage timing.");
                return;
            }
            NavInferenceResult result=task.Result;
            NavigationPlan plan=result.plan;
            bool valid=Guard.ApprovedNav(plan,visionId);
            lastCaptureMs=result.capture_ms;lastInferMs=result.infer_ms;
            lastParseMs=result.parse_ms;lastFrameReused=result.image_reused;
            lastLoadMs=result.load_ms;lastPromptMs=result.prompt_ms;lastEvalMs=result.eval_ms;
            lastPromptTokens=result.prompt_tokens;lastOutputTokens=result.output_tokens;
            lastModelId=result.model_id;lastNumCtx=result.ctx;lastNumPredict=result.predict;
            lastTemperature=result.temperature;lastTopP=result.top_p;
            if(navVisionCancel!=null){navVisionCancel.Dispose();navVisionCancel=null;}
            visionId="";
            Trace("Qwen result: "+(valid?plan.move:"REJECTED")+"; capture="+lastCaptureMs+"ms; infer="+lastInferMs+"ms; reused="+lastFrameReused);
            hud.Set("REFLEXCORE | "+activeNavMode.ToUpperInvariant()+" / QWEN "+(valid?plan.move:"REJECTED")+" / "+lastInferMs+"ms");
            if(!valid)
            {
                StopCurrent(false);ShowState("NAV STOP · INVALID PLAN","Only enumerated, bounded actions are allowed.");return;
            }
            if(navUserIntervened || Guard.IsPaused(Now,pauseUntil))
            {
                navUserIntervened=true;state="NAV_WAIT";navNextCapture=Now+Guard.HoldMs;
                ShowState("NAV · HUMAN OVERRIDE","User input took priority; discard the old vision decision and re-observe.");
                return;
            }
            if(!GameForeground(true)){StopCurrent(false);ShowState("NAV STOP · GAME UNFOCUSED","Switch back to CS and restart navigation. No input was sent.");return;}
            Stopwatch rustWatch=Stopwatch.StartNew();
            string grant=Brain("decide",unifiedSession,(navSteps+1).ToString(System.Globalization.CultureInfo.InvariantCulture),plan.move,plan.at_bombsite);
            rustWatch.Stop();lastRustMs=rustWatch.ElapsedMilliseconds;
            if(plan.move=="WAIT"||plan.move=="ARRIVED")
            {
                if(grant!=(plan.move=="WAIT"?"STOP:WAIT":"STOP:ARRIVED_UNVERIFIED"))
                    throw new Exception("Rust coordinator response mismatch");
                StopCurrent(false);
                ShowState(plan.move=="ARRIVED"?"NAV STOP · BOMBSITE?":"NAV STOP · UNCERTAIN",
                    plan.move=="ARRIVED"?"Rust stopped at an unverified arrival candidate; manual confirmation required.":"Model requested WAIT; Rust stopped navigation safely.");
                return;
            }
            if(grant!="ALLOW:"+plan.move)throw new Exception("Rust coordinator did not authorize the movement");
            LaunchNavAction(plan.move);
        }
        void LaunchNavAction(string move)
        {
            if(!Guard.AllowedNav(move) || move=="WAIT" || move=="ARRIVED")
                throw new InvalidOperationException("Unsafe runtime action");
            // Re-check physical control AFTER the Rust IPC round trip, not just before it.
            if(navUserIntervened || Guard.IsPaused(Now,pauseUntil))
            {
                StopCurrent(false);ShowState("NAV STOP · HUMAN INPUT","Human input changed while Rust decided; no new action dispatched.");return;
            }
            foreach(int key in new int[]{0x57,0x41,0x53,0x44,0x20,0x01,0x02})
            {
                if((Native.GetAsyncKeyState(key)&0x8000)!=0)
                {
                    StopCurrent(false);ShowState("NAV STOP · HUMAN KEY HELD","A physical key or mouse button is down; no AI input.");return;
                }
            }
            unifiedPending=true;
            if(!GameForeground(true))
            {
                StopCurrent(false);
                ShowState("NAV STOP · FOCUS CHANGED","Foreground window changed during Rust planning; no screenshot or input.");
                return;
            }
            navBeforeFrame=SceneProbe.Capture();
            if(navBeforeFrame==null)
            {
                StopCurrent(false);
                ShowState("NAV STOP · CAPTURE FAILED","Could not sample the visible CS window before input. No keys sent.");
                return;
            }
            navUserIntervened=false;
            navSteps++;frames.Clear();frames.AddRange(NavFrames(move));
            lastNavMove=move;lastNavKeyDown=lastNavKeyUp=lastNavMouse=0;
            Trace("Rust allowed step "+navSteps+" / "+move+"; dispatch is still pending");
            state="PLAY";activeScript="NAV "+move+" ("+navSteps+"/"+NavMaxSteps+")";
            playAt=Now+150;lastInputStarted=playAt;lastTick=Now;elapsedPlaying=0;next=0;
            logicalDown.Clear();injectedDown.Clear();logicalLeft=logicalRight=injectedLeft=injectedRight=false;
            if(pauseUntil<playAt)pauseUntil=playAt;
            ShowState("NAV · "+move,"One bounded movement planned. Physical input always has priority.");
        }
        void StartReflexRecovery()
        {
            if(navSteps>=NavMaxSteps){StopCurrent(false);ShowState("NAV LIMIT","8 bounded steps reached");return;}
            if(navUserIntervened || Guard.IsPaused(Now,pauseUntil) || !GameForeground(true))
            {
                StopCurrent(false);ShowState("NAV STOP · RECOVERY CANCELLED","Focus or human input changed; no recovery input sent.");return;
            }
            Stopwatch rustWatch=Stopwatch.StartNew();
            string grant=Brain("reflex",unifiedSession,(navSteps+1).ToString(System.Globalization.CultureInfo.InvariantCulture));
            rustWatch.Stop();lastRustMs=rustWatch.ElapsedMilliseconds;
            if(grant!="ALLOW:TURN_RIGHT" && grant!="ALLOW:TURN_LEFT")
                throw new InvalidOperationException("Unauthorized recovery movement");
            navStage="REFLEX RECOVERY";
            // A reflex uses no Ollama call: do not carry the previous VLM timing into this step.
            lastStepStarted=Now;lastCaptureMs=0;lastInferMs=0;lastParseMs=0;lastFrameReused=false;
            lastLoadMs=lastPromptMs=lastEvalMs=lastPromptTokens=lastOutputTokens=-1;
            Trace("WORLD: low scene-change evidence; one bounded recovery turn (no LLM call)");
            LaunchNavAction(grant.Substring(6));
        }
        // A deliberate visible smoke test, not an AI decision: one bounded W press in a local game.
        // No background game control, no Qwen, and no automatic retries.
        void StartVisibleInputTest()
        {
            StopCurrent(false);
            frames.Clear();
            frames.Add(new Frame{at=0,kind="kd",value=0x57});
            frames.Add(new Frame{at=1200,kind="ku",value=0x57});
            Guard.Validate(frames);
            visibleTestPending=true;visibleTestBefore=null;visibleTestDeadline=Now+25000;
            lastNavMove="FORWARD";lastNavKeyDown=lastNavKeyUp=lastNavMouse=0;
            state="PLAY";activeScript="VISIBLE W TEST (NOT AI)";
            playAt=Now+4000;lastTick=Now;elapsedPlaying=0;next=0;pauseUntil=0;
            logicalDown.Clear();injectedDown.Clear();logicalLeft=logicalRight=injectedLeft=injectedRight=false;
            ShowState("TEST W · SWITCH TO CS","Manual visible-input check, NOT autonomous navigation. Switch to a private/offline CS 1.6 game; W will be held for 1.2 seconds after the countdown. F12 / Ctrl+Alt+P stops.");
        }
        void StartRecord()
        {
            StopCurrent(false);frames.Clear();recordedDown.Clear();mouseWasKnown=false;
            state="RECORD";recordPending=true;recordAt=Now+3000;
            ShowState("RECORD IN 3s","Switch to CS 1.6. Recording captures selected game controls while the game is in the foreground. Press Stop when done.");
        }
        List<Frame> PlantFrames()
        {
            // Bomb selectable by 5 (default) and planted by holding mouse 1 while in a valid plant zone.
            return new List<Frame>{
                new Frame{at=0,kind="kd",value=0x35},new Frame{at=130,kind="ku",value=0x35},
                new Frame{at=400,kind="ld"},new Frame{at=4900,kind="lu"}
            };
        }
        void StartReplay(bool builtIn)
        {
            StopCurrent(false);
            if(builtIn){frames.Clear();frames.AddRange(PlantFrames());}
            else LoadDemo();
            Guard.Validate(frames);
            state="PLAY";activeScript=builtIn?"PLANT C4 DRILL":"DEMONSTRATION";
            playAt=Now+3000;lastTick=Now;elapsedPlaying=0;next=0;pauseUntil=0;
            logicalDown.Clear();injectedDown.Clear();logicalLeft=logicalRight=injectedLeft=injectedRight=false;
            ShowState("ARMED / 3s","Switch to CS 1.6. Physical input releases agent-held controls and pauses replay for three seconds.");
        }
        internal static bool IsNewStop(DateTime signal,DateTime started,DateTime seen)
        {
            return signal>started && signal>seen;
        }
        void StopCurrent(bool save)
        {
            CancelVision();
            CloseRustRuntime();
            if(state=="RECORD"&&save&&!recordPending&&frames.Count>0){try{SaveDemo();}catch(Exception ex){MessageBox.Show(ex.Message,"Demo save error");}}
            state="IDLE";recordPending=false;navActive=false;navSteps=0;
            visibleTestPending=false;visibleTestBefore=null;visibleTestDeadline=0;
            unifiedSession="";unifiedPending=false; // invalidates future use of this session in the GUI
            navBeforeFrame=null;navUserIntervened=false;
            ReleaseInjected();logicalDown.Clear();logicalLeft=logicalRight=false;
            if(!IsDisposed&&summary!=null)ShowState("STOPPED / READY","The demonstration stays in data/private and contains selected game controls.\nReplay follows the recorded sequence.");
        }
        void ReleaseInjected()
        {
            foreach(int key in new List<int>(injectedDown)){try{Native.Key(key,false);}catch{}}
            injectedDown.Clear();
            if(injectedLeft){try{Native.Mouse("lu",0,0);}catch{}}injectedLeft=false;
            if(injectedRight){try{Native.Mouse("ru",0,0);}catch{}}injectedRight=false;
        }
        void HumanOverride()
        {
            if(visibleTestPending && Now>=playAt && state=="PLAY")
            {
                // A person took control during the explicit visual smoke test: do not resume it.
                StopCurrent(false);
                ShowState("TEST CANCELLED · HUMAN INPUT","Physical user input interrupted the test; all injected keys released.");
                return;
            }
            if(navActive)navUserIntervened=true;
            pauseUntil=Now+Guard.HoldMs;
            if(state=="PLAY"&&(Now>=playAt||navActive))
            {
                ReleaseInjected();
                if(navActive)
                {
                    // Never resume a stale navigation action after a human move.
                    logicalDown.Clear();logicalLeft=logicalRight=false;
                    state="NAV_WAIT";navNextCapture=pauseUntil;
                }
            }
        }
        IntPtr Keyboard(int n,IntPtr w,IntPtr l)
        {
            try
            {
                if(n>=0)
                {
                    int msg=w.ToInt32();bool down=msg==0x100||msg==0x104,up=msg==0x101||msg==0x105;
                    if(down||up)
                    {
                        Native.KBD e=(Native.KBD)Marshal.PtrToStructure(l,typeof(Native.KBD));
                        if((e.flags&0x10u)==0)
                        {
                            int key=(int)e.vkCode;
                            if(down&&(key==0x7B || (key==0x50 && (Native.GetAsyncKeyState(0x11)&0x8000)!=0 && (Native.GetAsyncKeyState(0x12)&0x8000)!=0)))
                                StopCurrent(state=="RECORD");
                            else if(state=="PLAY"||navActive)HumanOverride();
                            else if(state=="RECORD"&&!recordPending&&GameForeground()&&Guard.Allowed(key))
                            {
                                if(down&&recordedDown.Add(key))AddFrame("kd",key,0,0);
                                if(up&&recordedDown.Remove(key))AddFrame("ku",key,0,0);
                            }
                        }
                    }
                }
            }catch{StopCurrent(false);}
            return Native.CallNextHookEx(kHook,n,w,l);
        }
        IntPtr Mouse(int n,IntPtr w,IntPtr l)
        {
            try
            {
                if(n>=0)
                {
                    int msg=w.ToInt32();Native.MOUSEHOOK e=(Native.MOUSEHOOK)Marshal.PtrToStructure(l,typeof(Native.MOUSEHOOK));
                    if((e.flags&1u)==0)
                    {
                        if(state=="PLAY"||navActive)
                        {
                            if(msg!=0x200||!mouseWasKnown||e.point.x!=mouseX||e.point.y!=mouseY)HumanOverride();
                        }
                        else if(state=="RECORD"&&!recordPending&&GameForeground())
                        {
                            if(msg==0x201)AddFrame("ld",0,0,0);
                            if(msg==0x202)AddFrame("lu",0,0,0);
                            if(msg==0x204)AddFrame("rd",0,0,0);
                            if(msg==0x205)AddFrame("ru",0,0,0);
                            if(msg==0x200&&trackMouse.Checked&&mouseWasKnown)
                            {
                                int dx=e.point.x-mouseX,dy=e.point.y-mouseY;
                                if((dx!=0||dy!=0)&&Math.Abs(dx)<=300&&Math.Abs(dy)<=300)AddFrame("move",0,dx,dy);
                            }
                        }
                        mouseX=e.point.x;mouseY=e.point.y;mouseWasKnown=true;
                    }
                }
            }catch{StopCurrent(false);}
            return Native.CallNextHookEx(mHook,n,w,l);
        }
        void AddFrame(string kind,int value,int dx,int dy)
        {
            long at=Now-recordBeginning;if(at<0)return;
            if(at>Guard.MaxDurationMs||frames.Count>=Guard.MaxEvents){StopCurrent(true);return;}
            if(kind=="move"&&frames.Count>0&&frames[frames.Count-1].kind=="move"&&at-frames[frames.Count-1].at<12)return;
            frames.Add(new Frame{at=at,kind=kind,value=value,dx=dx,dy=dy});
        }
        void Inject(Frame f)
        {
            if(!GameForeground(true))throw new InvalidOperationException("Focus changed before input: blocked");
            if(f.kind=="kd")
            {
                logicalDown.Add(f.value);
                if(injectedDown.Add(f.value))
                {
                    Native.Key(f.value,true);
                    if(navActive||visibleTestPending)lastNavKeyDown++;
                    if(navActive||visibleTestPending)Trace("INPUT: key DOWN "+(char)f.value+(Native.IsGameMovementKey(f.value)?" (scan code)":" (virtual key)"));
                }
            }
            else if(f.kind=="ku")
            {
                logicalDown.Remove(f.value);
                if(injectedDown.Remove(f.value))
                {
                    Native.Key(f.value,false);
                    if(navActive||visibleTestPending)lastNavKeyUp++;
                    if(navActive||visibleTestPending)Trace("INPUT: key UP "+(char)f.value+(Native.IsGameMovementKey(f.value)?" (scan code)":" (virtual key)"));
                }
            }
            else if(f.kind=="ld"){logicalLeft=true;if(!injectedLeft){Native.Mouse("ld",0,0);injectedLeft=true;}}
            else if(f.kind=="lu"){logicalLeft=false;if(injectedLeft){Native.Mouse("lu",0,0);injectedLeft=false;}}
            else if(f.kind=="rd"){logicalRight=true;if(!injectedRight){Native.Mouse("rd",0,0);injectedRight=true;}}
            else if(f.kind=="ru"){logicalRight=false;if(injectedRight){Native.Mouse("ru",0,0);injectedRight=false;}}
            else if(f.kind=="move")
            {
                Native.Mouse("move",f.dx,f.dy);
                if(navActive){lastNavMouse++;Trace("INPUT: mouse TURN "+lastNavMove+" (one relative event)");}
            }
        }
        void RestoreHeld()
        {
            if(!GameForeground(true))throw new InvalidOperationException("Focus changed before restoring input");
            foreach(int key in logicalDown)if(injectedDown.Add(key))Native.Key(key,true);
            if(logicalLeft&&!injectedLeft){Native.Mouse("ld",0,0);injectedLeft=true;}
            if(logicalRight&&!injectedRight){Native.Mouse("rd",0,0);injectedRight=true;}
        }
        void Tick(object sender,EventArgs unused)
        {
            long now=Now;long dt=Math.Max(0,Math.Min(100,now-lastTick));lastTick=now;
            UpdateTrayActivity();
            // Central STOP ALL from Control Center: cancel Qwen, close Rust IPC and release every injected key.
            // Poll at most 4 Hz, no agent-controlled paths or commands are executed.
            if(now-lastGlobalStopPoll>250)
            {
                lastGlobalStopPoll=now;
                try{
                    string signal=Path.Combine(root,"data","bridge","global-stop.signal");
                    if(File.Exists(signal)){
                        DateTime at=File.GetLastWriteTimeUtc(signal);
                        if(IsNewStop(at,startedUtc,lastGlobalStopUtc)){
                            lastGlobalStopUtc=at;StopCurrent(false);
                            ShowState("GLOBAL STOP", "Control Center requested stop; input and Qwen request cancelled.");
                        }
                    }
                }catch{}
            }
            try
            {
                if(state=="VISIBLE_TEST_VERIFY")
                {
                    if(now>=navNextCapture)
                    {
                        if(!GameForeground())
                        {
                            StopCurrent(false);
                            ShowState("TEST · GAME UNFOCUSED","Input was dispatched but the CS window is no longer foreground. Result unverified.");
                        }
                        else
                        {
                            int changed=SceneProbe.ChangePercent(visibleTestBefore,SceneProbe.Capture());
                            SaveInputDiagnostic("VISIBLE_W_TEST",changed<0?"CAPTURE_FAILED":changed<4?"NO_SCENE_CHANGE":"SCENE_CHANGED_UNVERIFIED",changed);
                            StopCurrent(false);
                            if(changed<0)ShowState("TEST · CAPTURE FAILED","Input was dispatched; could not compare game frames.");
                            else if(changed<4)ShowState("TEST · NO VISIBLE CHANGE","W scan-code input was dispatched; change below 4%. Check physical W movement, key binding, console/menu, and windowed CS. Game acceptance is unverified.");
                            else ShowState("TEST · VISIBLE CHANGE","W scan-code sent; image changed "+changed+"%. This does NOT prove movement or autonomous AI.");
                        }
                    }
                    return;
                }
                if(state=="NAV_WAIT")
                {
                    hud.Set("REFLEXCORE | NAV VERIFY / WAIT - STEP "+navSteps+" | UNVERIFIED");
                    if(now>=navNextCapture && !Guard.IsPaused(now,pauseUntil))
                    {
                        if(!GameForeground())
                        {
                            StopCurrent(false);ShowState("NAV STOP · GAME UNFOCUSED","Foreground game required to verify motion.");
                            return;
                        }
                        if(navUserIntervened)
                        {
                            navUserIntervened=false;navBeforeFrame=null;
                            if(unifiedPending)
                            {
                                if(Brain("feedback",unifiedSession,navSteps.ToString(System.Globalization.CultureInfo.InvariantCulture),"HUMAN")!="CONTINUE:REOBSERVE_AFTER_HUMAN")
                                    throw new Exception("Rust intervention feedback rejected");
                                unifiedPending=false;
                            }
                            Trace("Human input detected: result attributed to HUMAN, not the AI");
                            StartNavVision(false);
                        }
                        else
                        {
                            // Capturing and JPEG encoding run away from the Windows message pump.
                            state="NAV_VERIFY";
                            navVerifyTask=Task.Run(()=>GameVisionFrame.Capture());
                            navStage="VERIFYING";
                            ShowState("NAV · VERIFYING","One frame will serve as both movement feedback and the next Qwen image.");
                        }
                    }
                    return;
                }
                if(state=="NAV_VERIFY")
                {
                    if(navUserIntervened)
                    {
                        navVerifyTask=null;
                        state="NAV_WAIT";navNextCapture=pauseUntil;
                        return;
                    }
                    if(!GameForeground())
                    {
                        StopCurrent(false);ShowState("NAV STOP · GAME UNFOCUSED","Verification discarded: game is no longer foreground.");return;
                    }
                    if(navVerifyTask==null){StopCurrent(false);return;}
                    if(!navVerifyTask.IsCompleted)
                    {
                        summary.Text="NAV · VERIFYING · "+navSteps;
                        hud.Set("REFLEXCORE | "+summary.Text);
                        return;
                    }
                    Task<NavFrame> task=navVerifyTask;
                    navVerifyTask=null;
                    NavFrame after=task.IsFaulted||task.IsCanceled?null:task.Result;
                    lastVerifyMs=after==null?-1:after.capture_ms;
                    int changed=after==null?-1:SceneProbe.ChangePercent(navBeforeFrame,after.fingerprint);
                    int[] flow=after==null?new int[]{0,0,0}:SceneProbe.EstimateVisualFlow(navBeforeFrame,after.fingerprint);
                    lastFlowDx=flow[0];lastFlowDy=flow[1];lastFlowGain=flow[2];
                    navBeforeFrame=null;
                    if(changed<0)
                    {
                        Brain("feedback",unifiedSession,navSteps.ToString(System.Globalization.CultureInfo.InvariantCulture),"CAPTURE_FAILED");
                        unifiedPending=false;
                        SaveInputDiagnostic("AI_NAV","CAPTURE_FAILED",changed);
                        StopCurrent(false);ShowState("NAV STOP · VERIFY FAILED","Could not capture the post-action game frame.");
                    }
                    else if(changed<4)
                    {
                        string result=Brain("feedback",unifiedSession,navSteps.ToString(System.Globalization.CultureInfo.InvariantCulture),"UNCHANGED");
                        unifiedPending=false;
                        SaveInputDiagnostic("AI_NAV","NO_SCENE_CHANGE",changed);
                        if(result=="CONTINUE:REFLEX_RECOVER")
                        {
                            StartReflexRecovery();
                        }
                        else
                        {
                            if(result!="STOP:SCENE_UNCHANGED")throw new Exception("Unexpected world feedback");
                            StopCurrent(false);
                            ShowState("NAV STOP · NO VISIBLE CHANGE","No safe recovery remaining; scene change "+changed+"%.");
                        }
                    }
                    else
                    {
                        if(Brain("feedback",unifiedSession,navSteps.ToString(System.Globalization.CultureInfo.InvariantCulture),"VISIBLE_CHANGE")!="CONTINUE:SCENE_CHANGED_UNVERIFIED")
                            throw new Exception("Rust feedback rejected");
                        unifiedPending=false;
                        SaveInputDiagnostic("AI_NAV","SCENE_CHANGED_UNVERIFIED",changed);
                        Trace("Scene changed "+changed+"% (NOT verified movement). Reusing captured frame for next decision.");
                        StartNavVision(false,after.jpeg);
                    }
                    return;
                }
                if(state=="NAV_FOCUS")
                {
                    if(GameForeground()&&!Guard.IsPaused(now,pauseUntil))
                    {
                        StartNavVision(false);return;
                    }
                    if(now>=navFocusDeadline)
                    {
                        StopCurrent(false);ShowState("NAV STOP · FOCUS TIMEOUT","No screenshot or game input sent.");return;
                    }
                    summary.Text="NAV · WAITING FOR CS · "+((navFocusDeadline-now+999)/1000)+"s";
                    hud.Set("REFLEXCORE | "+summary.Text+" | NO INPUT YET");
                    return;
                }
                if(state=="NAV_PLAN")
                {
                    if(navVisionTask==null){StopCurrent(false);return;}
                    if(navVisionTask.IsCompleted){FinishNavVision();return;}
                    summary.Text="NAV · "+navStage+" · "+((now-visionStarted)/1000)+"s";
                    hud.Set("REFLEXCORE | "+summary.Text+" | NO INPUT YET");
                    return;
                }
                if(state=="AI_PLAN")
                {
                    if(visionProcess==null){StopCurrent(false);return;}
                    if(visionProcess.HasExited){FinishVisionPlan();return;}
                    summary.Text="QWEN ANALYZING · "+((now-visionStarted)/1000)+"s";
                    hud.Set("REFLEXCORE | "+summary.Text+" | NO INPUT YET");
                    return;
                }
                if(state=="AI_READY")
                {
                    if(now-visionReadyAt>30000){StopCurrent(false);return;}
                }
                if(state=="RECORD")
                {
                    if(recordPending&&now>=recordAt)
                    {
                        if(GameForeground()){recordBeginning=now;recordPending=false;mouseWasKnown=false;ShowState("RECORDING","Game in foreground. Demonstrate the movement or plant C4, then press Stop to save.");}
                        else ShowState("WAITING FOR CS 1.6","Switch to a local CS 1.6 game to start recording.");
                    }
                    else if(!recordPending){summary.Text="RECORDING · "+frames.Count+" events";if(now-recordBeginning>Guard.MaxDurationMs)StopCurrent(true);}
                }
                if(state=="PLAY")
                {
                    if(visibleTestPending && now>visibleTestDeadline)
                    {
                        StopCurrent(false);
                        ShowState("TEST · EXPIRED","Game was not ready within the bounded test window. No more test input will be sent.");
                        return;
                    }
                    if(now<playAt){summary.Text="START IN "+((playAt-now+999)/1000)+"s | "+activeScript;hud.Set("REFLEXCORE | "+summary.Text);return;}
                    if(!GameForeground())
                    {
                        if(injectedDown.Count>0||injectedLeft||injectedRight)ReleaseInjected();
                        summary.Text="WAITING · CS 1.6 MUST BE ACTIVE";hud.Set("REFLEXCORE | "+summary.Text);return;
                    }
                    // Detect keys/buttons held by the person even after the hook's initial event.
                    // Ignore keys currently held by our own SendInput playback.
                    foreach(int key in new int[]{0x57,0x41,0x53,0x44,0x20,0x10,0x11,0x45,0x51,0x52,0x01,0x02})
                    {
                        if((Native.GetAsyncKeyState(key)&0x8000)!=0 &&
                           !(key==0x01&&injectedLeft) && !(key==0x02&&injectedRight) &&
                           !injectedDown.Contains(key)) { HumanOverride();break; }
                    }
                    if(Guard.IsPaused(now,pauseUntil))
                    {
                        summary.Text="HUMAN OVERRIDE · PAUSED "+((pauseUntil-now+999)/1000)+"s";hud.Set("REFLEXCORE | "+summary.Text);return;
                    }
                    if(visibleTestPending && next==0 && visibleTestBefore==null)
                    {
                        visibleTestBefore=SceneProbe.Capture();
                        if(visibleTestBefore==null)
                        {
                            StopCurrent(false);
                            ShowState("TEST · CAPTURE FAILED","No usable foreground CS frame. No W input was sent.");
                            return;
                        }
                    }
                    RestoreHeld();elapsedPlaying+=dt;
                    while(next<frames.Count&&frames[next].at<=elapsedPlaying)
                    {
                        Inject(frames[next]);next++;
                    }
                    summary.Text="SHARED CONTROL · "+activeScript+" · "+next+"/"+frames.Count;
                    hud.Set("REFLEXCORE | "+summary.Text);
                    if(next==frames.Count)
                    {
                        ReleaseInjected();
                        if(navActive)
                        {
                            lastInputMs=Now-lastInputStarted;
                            state="NAV_WAIT";navNextCapture=Now+350;
                            ShowState("NAV · STEP "+navSteps+" SENT / UNVERIFIED","Input dispatched. Waiting for a NEW screenshot; SendInput success alone does not prove CS moved.");
                        }
                        else if(visibleTestPending)
                        {
                            state="VISIBLE_TEST_VERIFY";navNextCapture=Now+850;
                            ShowState("TEST · W SENT / VERIFYING","W sent using hardware scan-code encoding. Comparing screenshots; this does not prove the game moved.");
                        }
                        else
                        {
                            state="IDLE";
                            ShowState("INPUT SENT · RESULT NOT VERIFIED","The input sequence was sent. This does not prove the game reacted; check CS window and game state.");
                        }
                    }
                }
                hud.Set("REFLEXCORE | "+summary.Text);
            }
            catch(Exception ex){StopCurrent(false);ShowState("INPUT ERROR / STOPPED",ex.Message);}
        }
    }
}
