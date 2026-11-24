using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace ReflexCore.Bridge
{
    // A manifest moves atomically between states. Its basename is also its command identity.
    public sealed class QueueEntry
    {
        public string Id { get; set; }
        public string Task { get; set; }
        public string State { get; set; }
    }
    public sealed class QueueStore
    {
        readonly string bridge, history, requests, tasks;
        readonly Dictionary<string,string> terminalKinds=new Dictionary<string,string>(StringComparer.Ordinal);
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
                if((info.Attributes&FileAttributes.ReparsePoint)!=0 || info.Length>256)return "local";
                string[] lines=File.ReadAllLines(path);
                if(lines.Length==2)switch(lines[1]){
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
        public void Finish(string path,string state)
        {
            if(!File.Exists(path))return;
            if(state!="completed" && state!="failed" && state!="cancelled" && state!="interrupted")
                throw new ArgumentException("Invalid terminal state");
            Directory.CreateDirectory(history);
            string id=IdOf(path);
            // Render only known valid IDs in Studio. Preserve older manifests in the local history.
            string dest=Path.Combine(history,Path.GetFileNameWithoutExtension(path)+"."+state);
            File.Move(path,dest);
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
        public bool DeleteHistory(string id,string state)
        {
            if(!ValidId(id) || !Terminal(state))return false;
            var path=Path.Combine(history,id+"."+state);
            if(!File.Exists(path))return false;
            File.Delete(path);
            terminalKinds.Remove(id);
            return true;
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
                    result.Add(new QueueEntry{Id=id,Task=kind,State=label});
                }
            }
            foreach(string id in terminalKinds.Keys.Where(key=>!retained.Contains(key)).ToArray())terminalKinds.Remove(id);
            return result;
        }
    }
}
