using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace ReflexCore.Bridge
{
    // A manifest moves atomically between states. Its basename is also its command identity.
    public sealed class QueueEntry
    {
        public string Id { get; set; }
        public string Task { get; set; }
        public string State { get; set; }
        public string Verification { get; set; }
        public string Reason { get; set; }
    }
    public sealed class TaskReceipt
    {
        public string schema { get; set; }
        public string task_id { get; set; }
        public string run_id { get; set; }
        public string stage { get; set; }
        public string outcome { get; set; }
        public string verification { get; set; }
        public string reason { get; set; }
    }
    public sealed class QueueStore
    {
        readonly string bridge, history, requests, tasks;
        readonly Dictionary<string,string> terminalKinds=new Dictionary<string,string>(StringComparer.Ordinal);
        readonly Dictionary<string,TaskReceipt> terminalReceipts=new Dictionary<string,TaskReceipt>(StringComparer.Ordinal);
        static readonly Regex IdPattern=new Regex(@"\A[0-9]{17}-[0-9a-f]{32}\z");
        const int HistoryLimit=100;
        public QueueStore(string project)
        {
            bridge=Path.Combine(project,"data","bridge");
            tasks=Path.Combine(project,"tasks");
            history=Path.Combine(bridge,"queue-history");
            requests=Path.Combine(bridge,"queue-requests");
        }
        public static bool ValidId(string id){return id!=null && IdPattern.IsMatch(id);}
        public string Submit(string task,bool run)
        {
            if(task==null || !Regex.IsMatch(task,@"\A[a-zA-Z0-9_-]{1,70}\z"))throw new ArgumentException("Invalid local task name");
            string script=Path.Combine(tasks,task+".ps1");
            if(!File.Exists(script) || (File.GetAttributes(script)&FileAttributes.ReparsePoint)!=0)
                throw new IOException("Local task missing or linked");
            string pending=Path.Combine(bridge,"pending");
            Directory.CreateDirectory(pending);
            string id=DateTime.UtcNow.ToString("yyyyMMddHHmmssfff",System.Globalization.CultureInfo.InvariantCulture)+"-"+Guid.NewGuid().ToString("N");
            string dest=Path.Combine(pending,id+".job");
            string staging=dest+".tmp";
            try{
                File.WriteAllText(staging,(run?"RUN":"REVIEW")+"\n"+task+".ps1");
                File.Move(staging,dest);
            }finally{if(File.Exists(staging))File.Delete(staging);}
            return id;
        }
        static string ReadKind(string path)
        {
            try{
                var info=new FileInfo(path);
                if((info.Attributes&FileAttributes.ReparsePoint)!=0 || info.Length>2048)return "local";
                string[] lines=File.ReadAllLines(path);
                if(lines.Length==2 || lines.Length==3)switch(lines[1]){
                    case "agent-demo.ps1":return "uia";
                    case "notepad-save.ps1":return "notepad";
                    case "notepad-visual.ps1":return "visual";
                }
            }catch(IOException){}
            return "local";
        }
        public static string IdOf(string path){return Path.GetFileNameWithoutExtension(path);}
        public string Marker(string id,string command)
        {
            if(!ValidId(id) || (command!="cancel" && command!="approve"))throw new ArgumentException("Invalid queue command");
            return Path.Combine(requests,id+"."+command);
        }
        public bool Request(string id,string command)
        {
            string marker=Marker(id,command);
            string name=id+".job";
            if(!File.Exists(Path.Combine(bridge,"pending",name)) &&
                !(command=="cancel" && File.Exists(Path.Combine(bridge,"running",name))))return false;
            Directory.CreateDirectory(requests);
            using(File.Open(marker,FileMode.OpenOrCreate,FileAccess.Write,FileShare.ReadWrite|FileShare.Delete)){}
            if(!File.Exists(Path.Combine(bridge,"pending",name)) && !File.Exists(Path.Combine(bridge,"running",name))){
                DeleteMarker(marker);
                return false;
            }
            return true;
        }
        static void DeleteMarker(string path){
            try{File.Delete(path);}catch(IOException){} // A concurrent request or startup cleanup can finish it.
        }
        public bool Requested(string path,string command){
            string id=IdOf(path);return ValidId(id)&&File.Exists(Marker(id,command));
        }
        static TaskReceipt ParseReceipt(string json,string id)
        {
            try {
                var value=new JavaScriptSerializer { MaxJsonLength=1024,RecursionLimit=4 }.Deserialize<TaskReceipt>(json);
                if(value==null || value.schema!="reflexcore.task.receipt.v1" || value.task_id!=id ||
                    (value.run_id!=id && !Regex.IsMatch(value.run_id??"",@"\A(?:[a-f0-9]{32}|[a-f0-9]{56})\z")) ||
                    !new[]{"goal","notepad","queue"}.Contains(value.stage) ||
                    !new[]{"verified","unverified","failed","cancelled","interrupted"}.Contains(value.outcome) ||
                    !new[]{"verified","failed","unknown","not_confirmed"}.Contains(value.verification) ||
                    !new[]{"verified_goal","disk_readback","verification_failed","precondition_failed","focus_lost","infrastructure_error","operator_cancelled",
                        "cancelled_effect_unknown","effect_unknown","no_effect_evidence","process_exited","process_failed","cleanup_unconfirmed","interrupted"}.Contains(value.reason))return null;
                return value;
            } catch(ArgumentException) { return null; }
              catch(InvalidOperationException) { return null; }
        }
        internal TaskReceipt ReadWorkerReceipt(string claim)
        {
            string kind=ReadKind(claim);
            if(kind=="local")return null;
            string path=Path.ChangeExtension(claim,"receipt.json");
            try {
                var file=new FileInfo(path);
                if(!file.Exists || file.Length>1024 || (file.Attributes&FileAttributes.ReparsePoint)!=0)return null;
                var value=ParseReceipt(File.ReadAllText(path),IdOf(claim));
                if(value==null)return null;
                if(kind=="uia" && value.stage=="goal")return value;
                if((kind=="notepad" || kind=="visual") && value.stage=="notepad" && value.reason=="disk_readback")return value;
            } catch(IOException) { }
            return null;
        }
        public void Finish(string path,string state) { Finish(path,state,null); }
        internal void Finish(string path,string state,TaskReceipt receipt)
        {
            if(!File.Exists(path))return;
            if(state!="completed" && state!="failed" && state!="cancelled" && state!="interrupted")
                throw new ArgumentException("Invalid terminal state");
            Directory.CreateDirectory(history);
            string id=IdOf(path);
            // Render only known valid IDs in Studio. Preserve older manifests in the local history.
            string dest=Path.Combine(history,Path.GetFileNameWithoutExtension(path)+"."+state);
            if(ValidId(id)){
                if(receipt==null)receipt=new TaskReceipt {
                    schema="reflexcore.task.receipt.v1",task_id=id,run_id=id,stage="queue",
                    outcome=state=="completed"?"unverified":state,verification=state=="interrupted"?"unknown":"not_confirmed",
                    reason=state=="completed"?"process_exited":state=="cancelled"?"operator_cancelled":state=="interrupted"?"interrupted":"process_failed"
                };
                string[] manifest=File.ReadAllLines(path);
                if(manifest.Length>=2){
                    string staging=path+"."+Guid.NewGuid().ToString("N")+".tmp";
                    try {
                        File.WriteAllLines(staging,new[]{manifest[0],manifest[1],new JavaScriptSerializer().Serialize(receipt)});
                        File.Replace(staging,path,null);
                    } finally { File.Delete(staging); }
                }
            }
            File.Move(path,dest);
            DeleteMarker(Path.ChangeExtension(path,"receipt.json"));
            if(ValidId(id) && Directory.Exists(requests)){
                DeleteMarker(Marker(id,"cancel")); DeleteMarker(Marker(id,"approve"));
            }
            var files=new DirectoryInfo(history).GetFiles().Where(f=>ValidId(IdOf(f.Name)) && Terminal(f.Extension.TrimStart('.')))
                .OrderByDescending(f=>f.Name,StringComparer.Ordinal).Skip(HistoryLimit);
            foreach(var file in files)file.Delete();
        }
        public void Recover()
        {
            string running=Path.Combine(bridge,"running");
            if(Directory.Exists(running))foreach(var path in Directory.GetFiles(running,"*.job"))Finish(path,"interrupted");
            if(!Directory.Exists(requests))return;
            foreach(var path in Directory.GetFiles(requests)){
                string id=IdOf(path);
                if(!ValidId(id) || (Path.GetExtension(path)!=".cancel" && Path.GetExtension(path)!=".approve"))continue;
                if(!File.Exists(Path.Combine(bridge,"pending",id+".job")))File.Delete(path);
                else if(Path.GetExtension(path)==".approve")File.Delete(path); // Fresh approval for each tray session.
            }
        }
        public void CancelPending()
        {
            if(!Directory.Exists(requests))return;
            foreach(string marker in Directory.GetFiles(requests,"*.cancel")){
                string id=IdOf(marker);
                if(ValidId(id))Finish(Path.Combine(bridge,"pending",id+".job"),"cancelled");
            }
        }
        static IEnumerable<string> Files(string dir,string glob){
            return Directory.Exists(dir)?Directory.GetFiles(dir,glob):new string[0];
        }
        static bool Terminal(string state){
            return state=="completed" || state=="cancelled" || state=="failed" || state=="interrupted";
        }
        public List<QueueEntry> Snapshot()
        {
            var result=new List<QueueEntry>();
            var seen=new HashSet<string>(StringComparer.Ordinal);
            var retained=new HashSet<string>(StringComparer.Ordinal);
            foreach(string state in new[]{"running","pending","history"}){
                bool ended=state=="history";
                string dir=ended?history:Path.Combine(bridge,state);
                var paths=Files(dir,ended?"*":"*.job");
                paths=ended?paths.OrderByDescending(x=>x,StringComparer.Ordinal):paths.OrderBy(x=>x,StringComparer.Ordinal);
                foreach(string path in paths.Take(100)){
                    string id=IdOf(path);
                    if(!ValidId(id))continue;
                    string label=ended?Path.GetExtension(path).TrimStart('.'):state;
                    if((ended && !Terminal(label)) || !seen.Add(id))continue;
                    string kind;
                    if(!ended || !terminalKinds.TryGetValue(id,out kind))kind=ReadKind(path);
                    if(ended){retained.Add(id);terminalKinds[id]=kind;}
                    if(label=="running" && Requested(path,"cancel"))label="stopping";
                    TaskReceipt receipt=null;
                    if(ended && !terminalReceipts.TryGetValue(id,out receipt))try {
                        if(new FileInfo(path).Length<=2048){
                            var lines=File.ReadAllLines(path);
                            if(lines.Length==3)receipt=ParseReceipt(lines[2],id);
                        }
                        terminalReceipts[id]=receipt;
                    } catch(IOException) { }
                    result.Add(new QueueEntry{Id=id,Task=kind,State=label,Verification=receipt==null?"not_confirmed":receipt.verification,
                        Reason=receipt==null?"":receipt.reason});
                }
            }
            foreach(string id in terminalKinds.Keys.Where(key=>!retained.Contains(key)).ToArray()){
                terminalKinds.Remove(id);
                terminalReceipts.Remove(id);
            }
            return result;
        }
    }
}
