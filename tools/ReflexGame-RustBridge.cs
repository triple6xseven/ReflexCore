using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Web.Script.Serialization;

namespace ReflexCore.Citadel
{
    // Narrow localhost-to-stdin bridge. There is no client-specified executable,
    // path, command-line, filesystem target, keyboard, mouse, or shell operation.
    internal static class CitadelRustBridge
    {
        private static readonly object Gate = new object();
        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
        private static Process Agent;
        private static string Token;
        private static int ExpectedSeq = 1;
        private const string Schema = "reflexcore.citadel.bridge.v1";
        private const int TimeoutMs = 3500;
        // Privacy-safe progress snapshot for existing Windows tray. Never persist
        // game observations, prompts, tokens, command lines or window titles.
        // Contract: docs/ACTIVITY-PROTOCOL.md (finite enumerated stages only).
        private static void Activity(string stage, string action, int seq, long ms)
        {
            try
            {
                string folder=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "ReflexCore", "runtime");
                Directory.CreateDirectory(folder);
                string path=Path.Combine(folder,"activity.json");
                string text=Json.Serialize(new { schema="reflexcore.activity.v1", source="citadel_rust",
                    stage=stage, action=action, sequence=seq, elapsed_ms=Math.Max(0,ms),
                    at_utc=DateTime.UtcNow.ToString("o",System.Globalization.CultureInfo.InvariantCulture) });
                // A brief partially-written read is ignored by the polling tray.
                File.WriteAllText(path,text,System.Text.Encoding.UTF8);
            }
            catch { /* Telemetry must never block an action or emergency stop. */ }
        }

        private static string Failure(string code)
        {
            return Json.Serialize(new { schema=Schema, ok=false, error=code });
        }
        private static void Terminate(Process p)
        {
            if(p==null)return;
            try{if(!p.HasExited)p.Kill();}catch{}
            try{p.Dispose();}catch{}
        }
        private static void ClearLocked()
        {
            var p=Agent;Agent=null;Token=null;ExpectedSeq=1;Terminate(p);
        }
        public static string Stop()
        {
            // Kill first, WITHOUT waiting for Gate. Stop must interrupt a blocked
            // pipe read and must not wait behind an unresponsive agent.
            var active=Volatile.Read(ref Agent);
            try{if(active!=null&&!active.HasExited)active.Kill();}catch{}
            lock(Gate){ClearLocked();}
            Activity("stopped", "none", 0, 0);
            return Json.Serialize(new { schema=Schema, ok=true, stopped=true });
        }
        public static void SelfTest()
        {
            if(Schema.Length<15||TimeoutMs<=0)throw new Exception("Rust bridge constants failed");
        }
        public static string Handle(string operation, string input, string root)
        {
            if(operation=="stop")return Stop();
            Stopwatch latency=Stopwatch.StartNew();
            if(operation!="start"&&operation!="next"&&operation!="commit"&&operation!="finish")return Failure("UNKNOWN_OPERATION");
            Dictionary<string,object> args;
            try {args=Json.Deserialize<Dictionary<string,object>>(input);}
            catch{return Failure("INVALID_JSON");}
            if(args==null||args.Count>5||!args.ContainsKey("schema")||!args.ContainsKey("seq")||!args.ContainsKey("world"))return Failure("INVALID_REQUEST");
            if(Convert.ToString(args["schema"])!=Schema)return Failure("SCHEMA_REJECTED");
            int seq;
            try{seq=Convert.ToInt32(args["seq"]);}catch{return Failure("INVALID_SEQUENCE");}
            if(seq<1||seq>2500)return Failure("INVALID_SEQUENCE");
            lock(Gate)
            {
                if(operation=="start")
                {
                    if(seq!=1)return Failure("START_SEQUENCE_REJECTED");
                    if(Agent!=null)return Failure("SESSION_ALREADY_RUNNING");
                    string binary=Path.Combine(root,"target","release","reflexcore.exe");
                    if(!File.Exists(binary))return Failure("RUST_RELEASE_NOT_BUILT");
                    var proc=new Process();
                    proc.StartInfo=new ProcessStartInfo {
                        FileName=binary,Arguments="citadel-bridge serve",WorkingDirectory=root,
                        UseShellExecute=false,CreateNoWindow=true,
                        RedirectStandardInput=true,RedirectStandardOutput=true,
                        RedirectStandardError=false
                    };
                    try{if(!proc.Start()){proc.Dispose();return Failure("RUST_PROCESS_START_FAILED");}}
                    catch{proc.Dispose();return Failure("RUST_PROCESS_START_FAILED");}
                    Agent=proc;Token=Guid.NewGuid().ToString("N");ExpectedSeq=1;
                    Activity("observing","none",seq,latency.ElapsedMilliseconds);
                }
                else
                {
                    if(Agent==null||!args.ContainsKey("token")||Convert.ToString(args["token"])!=Token)
                        return Failure("NO_ACTIVE_SESSION");
                }
                if(seq!=ExpectedSeq)return Failure("SEQUENCE_REPLAY_OR_GAP");
                try
                {
                    // Forward only schema, op, sequence and a structured game-world
                    // observation. A malicious extra HTTP field cannot become an IPC command.
                    string serialized=Json.Serialize(new {
                        schema=Schema,op=operation,seq=seq,world=args["world"]
                    });
                    if(serialized.Length>16000){ClearLocked();return Failure("WORLD_TOO_LARGE");}
                    if(Agent==null||Agent.HasExited){ClearLocked();return Failure("RUST_PROCESS_EXITED");}
                    Activity(operation=="commit"?"verifying":operation=="next"?"deciding":"observing",
                        "none",seq,latency.ElapsedMilliseconds);
                    Agent.StandardInput.WriteLine(serialized);
                    Agent.StandardInput.Flush();
                    var process=Agent;
                    Task<string> response=Task.Run(()=>process.StandardOutput.ReadLine());
                    if(!response.Wait(TimeoutMs)){ClearLocked();Activity("failed","none",seq,latency.ElapsedMilliseconds);return Failure("RUST_IPC_TIMEOUT");}
                    string line=response.Result;
                    if(line==null||line.Length>16000){ClearLocked();return Failure("RUST_RESPONSE_INVALID");}
                    Dictionary<string,object> result=Json.Deserialize<Dictionary<string,object>>(line);
                    if(result==null||!result.ContainsKey("schema")||Convert.ToString(result["schema"])!=Schema
                       ||!result.ContainsKey("ok"))
                    {
                        ClearLocked();return Failure("RUST_RESPONSE_INVALID");
                    }
                    if(!Convert.ToBoolean(result["ok"]))
                    {
                        string code=result.ContainsKey("error")?Convert.ToString(result["error"]):"RUST_REJECTED_WORLD_OR_ACTION";
                        if(code.Length>60||!System.Text.RegularExpressions.Regex.IsMatch(code,@"^[A-Z_]+$"))code="RUST_REJECTED_WORLD_OR_ACTION";
                        ClearLocked();Activity("failed","none",seq,latency.ElapsedMilliseconds);return Failure(code);
                    }
                    ExpectedSeq++;
                    if(operation=="start")result["token"]=Token;
                    string action="none";
                    if(operation=="next" && result.ContainsKey("action") && result["action"]!=null)
                    {
                        var candidate=result["action"] as Dictionary<string,object>;
                        if(candidate!=null && candidate.ContainsKey("kind"))
                        {
                            string k=Convert.ToString(candidate["kind"]);
                            if(k=="deploy"||k=="skill"||k=="focus")action=k;
                        }
                    }
                    string stage=operation=="start"?"ready":operation=="commit"?"verified":
                        operation=="finish"?"completed":action=="none"?"observing":"awaiting_effect";
                    Activity(stage,action,seq,latency.ElapsedMilliseconds);
                    if(operation=="finish")ClearLocked();
                    return Json.Serialize(result);
                }
                catch{ClearLocked();Activity("failed","none",seq,latency.ElapsedMilliseconds);return Failure("RUST_IPC_FAILURE");}
            }
        }
    }
}
