using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace ReflexCore.Bridge
{
    // A manifest moves atomically between states. Its basename is also its command identity.
    public sealed class QueueEntry
    {
        public string Id { get; set; }
        public string Task { get; set; }
        public string State { get; set; }
        public string Progress {get;set;}
        public string Verification { get; set; }
        public string Reason { get; set; }
        public TaskReceipt Receipt { get; set; }
    }
    public sealed class HandoffMetrics
    {
        public long? queue_wait_us {get; set;}
        public long? worker_startup_us {get; set;}
        public long check_us {get; set;}
        public long write_us {get; set;}
        public long readback_us {get; set;}
        public long worker_us {get; set;}
        public long bytes_hashed {get; set;}
        public long? peak_private_bytes {get; set;}
        public int model_calls {get; set;}
    }
    public sealed class HandoffSummary
    {
        public bool ready { get; set; }
        public int present { get; set; }
        public int missing { get; set; }
        public int mismatched { get; set; }
        public int unreadable { get; set; }
        public int changed { get; set; }
    }
    public sealed class FolderResultLink
    {
        public string folder { get; set; }
        public string checklist { get; set; }
        public string report { get; set; }
        public string checklist_sha256 { get; set; }
        public string old_extension { get; set; }
        public string new_extension { get; set; }
    }
    public sealed class SkillEvidence
    {
        public string schema {get;set;}
        public string run_id {get;set;}
        public string skill_id {get;set;}
        public int skill_version {get;set;}
        public string adapter {get;set;}
        public int adapter_version {get;set;}
        public int verifier_version {get;set;}
        public string outcome {get;set;}
        public long? readback_us {get;set;}
        internal static bool HasWireTypes(object raw)
        {
            var fields=raw as IDictionary<string,object>;
            object value;
            if(fields==null || !fields.TryGetValue("readback_us",out value) ||
                !(value is int || value is long))return false;
            foreach(string key in new[]{"skill_version","adapter_version","verifier_version"})
                if(!fields.TryGetValue(key,out value) || !(value is int))return false;
            return true;
        }
        internal bool Matches(TaskReceipt receipt)
        {
            return schema=="reflexcore.skill.evidence.v1" && run_id==receipt.run_id &&
                skill_id=="artifact.verify_saved_text" && skill_version==1 && verifier_version==1 &&
                adapter_version==1 && readback_us>=0 && outcome=="verified" &&
                receipt.outcome=="verified" && receipt.verification=="verified" &&
                ((adapter=="winforms" && receipt.stage=="goal" && receipt.reason=="verified_goal") ||
                 (adapter=="notepad" && receipt.stage=="notepad" && receipt.reason=="disk_readback"));
        }
    }
    public sealed class CompositionInput
    {
        public int version {get;set;}
        public string goal {get;set;}
        public string editor {get;set;}
        public string destination {get;set;}
        public string suffix {get;set;}
        public string second_destination {get;set;}
        public string second_suffix {get;set;}
        public bool Valid(){
            bool chain=goal=="editor.derive_chain";
            return version==1 && (chain || goal=="editor.derive_copy") &&
                new[]{"winforms","winforms-background","notepad"}.Contains(editor) &&
                SafeDestination(destination) && !String.IsNullOrEmpty(suffix) &&
                (chain ? SafeDestination(second_destination) && !String.IsNullOrEmpty(second_suffix) &&
                  String.Equals(Path.GetDirectoryName(destination),Path.GetDirectoryName(second_destination),StringComparison.OrdinalIgnoreCase) &&
                  !String.Equals(destination,second_destination,StringComparison.OrdinalIgnoreCase)
                 : second_destination==null && second_suffix==null) &&
                System.Text.Encoding.UTF8.GetByteCount(suffix+(second_suffix??""))<=4096;
        }
        static bool SafeDestination(string path){
            return !String.IsNullOrEmpty(path) && path.Length<1024 && Regex.IsMatch(path,@"\A[A-Za-z]:\\") &&
                path==Path.GetFullPath(path) && String.Equals(Path.GetExtension(path),".txt",StringComparison.OrdinalIgnoreCase);
        }
    }
    internal sealed class EditorAttempt
    {
        public readonly string RunId;
        internal CompositionInput Composition;
        readonly string adapter;
        EditorAttempt(string adapter,int bytes)
        {
            this.adapter=adapter;
            var nonce=new byte[bytes];
            using(var random=RandomNumberGenerator.Create())random.GetBytes(nonce);
            RunId=BitConverter.ToString(nonce).Replace("-","").ToLowerInvariant();
        }
        internal static EditorAttempt ForScript(string script)
        {
            // Preserve the existing run ID formats for UIA exchange and Notepad document tokens.
            if(script=="agent-background.ps1")return new EditorAttempt("winforms",28);
            if(script=="notepad-save.ps1" || script=="notepad-visual.ps1")return new EditorAttempt("notepad",16);
            return null;
        }
        internal static EditorAttempt ForComposition(CompositionInput input){
            return new EditorAttempt(input.editor,input.editor=="notepad"?16:28){Composition=input};
        }
        internal bool Accepts(TaskReceipt receipt)
        {
            if(receipt.run_id!=RunId)return false;
            if(Composition!=null){
                int count=Composition.goal=="editor.derive_chain"?2:1;
                return receipt.stage=="composition" && receipt.goal==Composition.goal && receipt.editor==Composition.editor &&
                    receipt.version==1 && receipt.published_outputs>=0 && receipt.published_outputs<=count &&
                    (receipt.outcome=="verified"?receipt.verification=="verified" && receipt.reason=="verified_goal" &&
                    receipt.completed_steps==2+2*count && receipt.published_outputs==count :
                    (receipt.outcome=="failed" || receipt.outcome=="cancelled") && receipt.verification=="unknown");
            }
            if(receipt.outcome!="verified")return receipt.verification!="verified" && receipt.skill==null;
            return receipt.skill!=null && receipt.skill.adapter==adapter && receipt.skill.Matches(receipt);
        }
    }
    public sealed class TaskReceipt
    {
        public HandoffSummary handoff { get; set; }
        public string goal {get;set;}
        public string editor {get;set;}
        public int? version {get;set;}
        public int? completed_steps {get;set;}
        public int? published_outputs {get;set;}
        public SkillEvidence skill {get;set;}
        public int? renamed { get; set; }
        public HandoffMetrics metrics { get; set; }
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
        string HandoffInput(string id) { return Path.Combine(Path.GetDirectoryName(bridge),"private","handoff",id+".json"); }
        public string SubmitComposition(CompositionInput input){
            if(input==null || !input.Valid())throw new ArgumentException("Invalid composition request");
            return Submit("compose-text",false,new JavaScriptSerializer().Serialize(input));
        }
        public string ReviewComposition(string id){
            if(!ValidId(id) || ReadKind(Path.Combine(bridge,"pending",id+".job"))!="composition")return null;
            return ReadPrivateInput(id);
        }
        string ReadPrivateInput(string id){
            var info=new FileInfo(HandoffInput(id));
            if(!info.Exists || info.Length>24576 || (info.Attributes&FileAttributes.ReparsePoint)!=0)throw new IOException("Invalid private request");
            return File.ReadAllText(info.FullName);
        }
        static string Digest(string text){
            using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(System.Text.Encoding.UTF8.GetBytes(text))).Replace("-","").ToLowerInvariant();
        }
        public bool ApproveComposition(string id,string reviewed){
            if(!ValidId(id) || reviewed==null)return false;
            return UnderDecisionLock(id,()=>{
                if(ReviewComposition(id)!=reviewed)return false;
                var value=new JavaScriptSerializer().Deserialize<CompositionInput>(reviewed);
                if(!value.Valid())return false;
                Directory.CreateDirectory(requests);
                using(var writer=new StreamWriter(new FileStream(Marker(id,"approve"),FileMode.CreateNew,FileAccess.Write,FileShare.None)))
                    writer.Write(Digest(id+"\n"+reviewed));
                return true;
            });
        }
        internal EditorAttempt ClaimComposition(string path){
            string id=IdOf(path),text=ReadPrivateInput(id),digest=Digest(id+"\n"+text);
            if(File.ReadAllText(Marker(id,"approve"))!=digest)throw new IOException("Approval changed");
            var input=new JavaScriptSerializer().Deserialize<CompositionInput>(text);
            if(!input.Valid())throw new IOException("Invalid approved request");
            var attempt=EditorAttempt.ForComposition(input);
            using(var writer=new StreamWriter(new FileStream(Path.ChangeExtension(path,"claim.json"),FileMode.CreateNew,FileAccess.Write,FileShare.None)))
                writer.Write(new JavaScriptSerializer().Serialize(new {task=id,attempt=attempt.RunId,digest=digest}));
            return attempt;
        }
        public string SubmitHandoff(string folder,string checklist,string report)
        {
            return Submit("verify-handoff",true,new JavaScriptSerializer().Serialize(new {folder,checklist,report}));
        }
        string ResultLink(string id) { return Path.Combine(Path.GetDirectoryName(bridge),"private","folder-results",id+".json"); }
        public string SubmitFolderCheck(FolderResultLink link,bool run=true)
        {
            var json=new JavaScriptSerializer();
            return Submit("verify-handoff",run,
                json.Serialize(new {link.folder,link.checklist,link.report,link.checklist_sha256}),json.Serialize(link));
        }
        public FolderResultLink ReadFolderResult(string id)
        {
            if(!ValidId(id))return null;
            try {
                var file=new FileInfo(ResultLink(id));
                if(!file.Exists || file.Length>16384 || (file.Attributes&FileAttributes.ReparsePoint)!=0)return null;
                return new JavaScriptSerializer{MaxJsonLength=16384}.Deserialize<FolderResultLink>(File.ReadAllText(file.FullName));
            } catch(IOException) { return null; }
              catch(UnauthorizedAccessException) { return null; }
              catch(ArgumentException) { return null; }
              catch(InvalidOperationException) { return null; }
        }
        public string SubmitRename(string folder,string source,string destination,string fingerprint,FolderResultLink guard)
        {
            return Submit("rename-extensions",true,new JavaScriptSerializer().Serialize(new {folder,source,destination,fingerprint,guard}));
        }
        public string Submit(string task,bool run) { return Submit(task,run,null); }
        string Submit(string task,bool run,string input,string resultLink=null)
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
                if(input!=null){
                    var privatePath=HandoffInput(id);
                    Directory.CreateDirectory(Path.GetDirectoryName(privatePath));
                    using(var writer=new StreamWriter(new FileStream(privatePath,FileMode.CreateNew,FileAccess.Write,FileShare.None))){writer.Write(input);}
                }
                if(resultLink!=null){
                    var linkPath=ResultLink(id);
                    Directory.CreateDirectory(Path.GetDirectoryName(linkPath));
                    using(var writer=new StreamWriter(new FileStream(linkPath,FileMode.CreateNew,FileAccess.Write,FileShare.None))){writer.Write(resultLink);}
                }
                File.WriteAllText(staging,(run?"RUN":"REVIEW")+"\n"+task+".ps1");
                File.Move(staging,dest);
            }catch{if(input!=null)DeleteMarker(HandoffInput(id));if(resultLink!=null)DeleteMarker(ResultLink(id));throw;}
            finally{if(File.Exists(staging))File.Delete(staging);}
            return id;
        }
        static string ReadKind(string path)
        {
            try{
                var info=new FileInfo(path);
                if((info.Attributes&FileAttributes.ReparsePoint)!=0 || info.Length>2048)return "local";
                string[] lines=File.ReadAllLines(path);
                if(lines.Length==2 || lines.Length==3)switch(lines[1]){
                    case "compose-text.ps1":return "composition";
                    case "verify-handoff.ps1":return "handoff";
                    case "rename-extensions.ps1":return "rename";
                    case "agent-demo.ps1":return "uia";
                    case "agent-background.ps1":return "uia-background";
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
            return UnderDecisionLock(id,()=>RequestLocked(id,command,marker));
        }
        // Studio and Tray can run in different processes. Order a stop acknowledgement
        // against publication of the terminal job, including when the worker just exited.
        static T UnderDecisionLock<T>(string id,Func<T> operation)
        {
            using(var mutex=new Mutex(false,@"Local\ReflexCoreQueueDecision-"+id)){
                try { if(!mutex.WaitOne(50))return default(T); } catch(AbandonedMutexException) { }
                try { return operation(); } finally { mutex.ReleaseMutex(); }
            }
        }
        bool RequestLocked(string id,string command,string marker)
        {
            string name=id+".job";
            if(command=="approve" && File.Exists(Path.Combine(bridge,"pending",name)) && ReadKind(Path.Combine(bridge,"pending",name))=="composition")return false;
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
                var serializer=new JavaScriptSerializer { MaxJsonLength=1024,RecursionLimit=4 };
                var fields=serializer.DeserializeObject(json) as IDictionary<string,object>;
                object raw;
                if(fields==null || (fields.TryGetValue("skill",out raw) && raw!=null && !SkillEvidence.HasWireTypes(raw)))return null;
                if(fields.TryGetValue("stage",out raw) && Object.Equals(raw,"composition")){
                    foreach(string key in new[]{"version","published_outputs"})
                        if(!fields.TryGetValue(key,out raw) || !(raw is int))return null;
                    if(!fields.TryGetValue("completed_steps",out raw) || (raw!=null && !(raw is int)))return null;
                    if(fields.Keys.Any(k=>!new[]{"schema","task_id","run_id","stage","outcome","verification","reason","goal","version","editor","completed_steps","published_outputs","metrics","handoff","skill","renamed"}.Contains(k)))return null;
                    foreach(string k in new[]{"metrics","handoff","skill","renamed"})if(fields.TryGetValue(k,out raw) && raw!=null)return null;
                }
                var value=serializer.ConvertToType<TaskReceipt>(fields);
                if(value==null || value.schema!="reflexcore.task.receipt.v1" || value.task_id!=id ||
                    (value.run_id!=id && !Regex.IsMatch(value.run_id??"",@"\A(?:[a-f0-9]{32}|[a-f0-9]{56})\z")) ||
                    !new[]{"goal","notepad","queue","handoff","rename","composition"}.Contains(value.stage) ||
                    !new[]{"verified","unverified","failed","cancelled","interrupted","partial"}.Contains(value.outcome) ||
                    !new[]{"verified","failed","unknown","not_confirmed"}.Contains(value.verification) ||
                    !new[]{"verified_goal","disk_readback","rename_completed","rename_partial","verification_failed","precondition_failed","focus_lost","infrastructure_error","operator_cancelled",
                        "cancelled_effect_unknown","effect_unknown","no_effect_evidence","process_exited","process_failed","cleanup_unconfirmed","interrupted"}.Contains(value.reason))return null;
                return value.skill==null || value.skill.Matches(value)?value:null;
            } catch(ArgumentException) { return null; }
              catch(InvalidOperationException) { return null; }
              catch(Exception error) {
                // The .NET Framework converter can wrap scalar conversion failures in System.Exception.
                var cause=error.GetBaseException();
                if(cause is FormatException || cause is OverflowException || cause is InvalidCastException ||
                    cause is NullReferenceException || cause is NotSupportedException)return null;
                throw;
              }
        }
        TaskReceipt ReadWorkerReceipt(string claim,EditorAttempt attempt)
        {
            string kind=ReadKind(claim);
            if(kind=="local")return null;
            string path=Path.ChangeExtension(claim,"receipt.json");
            try {
                var file=new FileInfo(path);
                if(!file.Exists || file.Length>1024 || (file.Attributes&FileAttributes.ReparsePoint)!=0)return null;
                var value=ParseReceipt(File.ReadAllText(path),IdOf(claim));
                if(value==null)return null;
                if(attempt!=null && !attempt.Accepts(value))return null;
                if(kind=="composition")return attempt!=null && attempt.Composition!=null?value:null;
                if(kind=="handoff" && value.stage=="handoff" && value.run_id==IdOf(claim) &&
                   value.metrics!=null && value.metrics.model_calls==0 &&
                   (value.outcome!="verified" || (value.verification=="verified" && value.reason=="disk_readback")))return value;
                if(kind=="rename" && value.stage=="rename" && value.run_id==IdOf(claim) &&
                   value.renamed.HasValue && value.renamed.Value>=0 && value.renamed.Value<=4096 &&
                   (value.outcome=="verified" || value.outcome=="partial" || value.outcome=="cancelled" || value.outcome=="failed"))return value;
                if((kind=="uia" || kind=="uia-background") && value.stage=="goal")return value;
                if((kind=="notepad" || kind=="visual") && value.stage=="notepad" && value.reason=="disk_readback")return value;
            } catch(IOException) { }
            return null;
        }
        internal string FinishWorker(string path,EditorAttempt attempt,int code,bool stopping,bool forced,out bool verified)
        {
            string id=IdOf(path);
            bool confirmed=false;
            string state=UnderDecisionLock(id,()=>{
                TaskReceipt receipt=ReadWorkerReceipt(path,attempt);
                bool cancelled=stopping || ((attempt!=null || code!=0) && Requested(path,"cancel"));
                confirmed=code==0 && receipt!=null && receipt.outcome=="verified" && receipt.verification=="verified" &&
                    (attempt==null || !cancelled);
                string terminal=confirmed?"completed":cancelled?"cancelled":code==0?"completed":"failed";
                if(!confirmed && cancelled && (receipt==null || receipt.outcome!="cancelled")){
                    receipt=new TaskReceipt {
                        schema="reflexcore.task.receipt.v1",task_id=id,run_id=attempt==null?id:attempt.RunId,stage="queue",outcome="cancelled",
                        published_outputs=receipt==null?null:receipt.published_outputs,
                        verification=code==2&&!forced?"not_confirmed":"unknown",
                        reason=forced?"cleanup_unconfirmed":code==2?"operator_cancelled":"cancelled_effect_unknown"
                    };
                } else if(!confirmed && !cancelled && receipt!=null){
                    if(receipt.outcome=="unverified" || receipt.outcome=="partial")terminal="completed";
                    else if(receipt.outcome=="verified" || receipt.outcome=="cancelled")receipt=null;
                }
                if(attempt!=null && !cancelled && receipt==null){
                    receipt=new TaskReceipt {schema="reflexcore.task.receipt.v1",task_id=id,run_id=attempt.RunId,
                        stage="queue",outcome=code==0?"unverified":"failed",verification="unknown",
                        reason=code==0?"no_effect_evidence":"process_failed"};
                }
                if(attempt!=null && receipt!=null && receipt.outcome=="failed")terminal="failed";
                Finish(path,terminal,receipt);
                return terminal;
            });
            verified=confirmed;
            return state;
        }
        public void Finish(string path,string state) { Finish(path,state,null); }
#if REFLEX_QUEUE_COMMIT_FIXTURE
        public static Action<string> BeforeFixtureTerminalMove;
#endif
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
#if REFLEX_QUEUE_COMMIT_FIXTURE
            if(BeforeFixtureTerminalMove!=null)BeforeFixtureTerminalMove(id);
#endif
            File.Move(path,dest);
            if(ValidId(id))DeleteMarker(HandoffInput(id));
            DeleteMarker(Path.ChangeExtension(path,"receipt.json"));
            DeleteMarker(Path.ChangeExtension(path,"claim.json"));
            DeleteMarker(Path.ChangeExtension(path,"spent"));
            DeleteMarker(Path.ChangeExtension(path,"progress"));
            DeleteMarker(Path.ChangeExtension(path,"progress.tmp"));
            if(ValidId(id) && Directory.Exists(requests)){
                DeleteMarker(Marker(id,"cancel")); DeleteMarker(Marker(id,"approve"));
            }
            var files=new DirectoryInfo(history).GetFiles().Where(f=>ValidId(IdOf(f.Name)) && Terminal(f.Extension.TrimStart('.')))
                .OrderByDescending(f=>f.Name,StringComparer.Ordinal).Skip(HistoryLimit);
            foreach(var file in files){file.Delete();DeleteMarker(ResultLink(IdOf(file.Name)));}
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
            DeleteMarker(ResultLink(id));
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
                int shown=0;
                foreach(string path in paths){
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
                    string progress=null;
                    if(!ended && kind=="composition" && state=="running")try{
                        var file=new FileInfo(Path.ChangeExtension(path,"progress"));
                        if(file.Exists && file.Length<=160 && (file.Attributes&FileAttributes.ReparsePoint)==0){
                            var fields=File.ReadAllLines(file.FullName);
                            if(fields.Length==3 && Regex.IsMatch(fields[1],@"\A[1-6]\z") && new[]{"editor.create_document","artifact.verify_saved_text","artifact.derive_text","artifact.verify_derived"}.Contains(fields[2]))progress="Step "+fields[1]+" · "+fields[2];
                        }
                    }catch(IOException){}
                    result.Add(new QueueEntry{Id=id,Task=kind,State=label,Progress=progress,Verification=receipt==null?"not_confirmed":receipt.verification,
                        Reason=receipt==null?"":receipt.reason,Receipt=receipt});
                    if(++shown==100)break;
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
