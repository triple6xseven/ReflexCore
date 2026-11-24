using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;

namespace ReflexCore.Bridge
{
    public sealed class McpServer
    {
        readonly string root, settings;
        readonly QueueStore queue;
        readonly JavaScriptSerializer json=new JavaScriptSerializer {MaxJsonLength=262144,RecursionLimit=20};
        bool initialized, ready;

        McpServer(string project)
        {
            root=project;
            settings=Path.Combine(root,"data","settings");
            queue=new QueueStore(root);
        }

        public static void Run(string project)
        {
            var server=new McpServer(project);
            var line=new StringBuilder();
            int next;
            while((next=Console.In.Read())!=-1)
            {
                if(next=='\n')
                {
                    server.Handle(line.ToString());
                    line.Clear();
                }
                else
                {
                    if(line.Length>=65536)throw new InvalidDataException("MCP message exceeds the local limit.");
                    line.Append((char)next);
                }
            }
        }

        static Dictionary<string,object> Object(object value)
        {
            var result=value as Dictionary<string,object>;
            if(result==null)throw new ArgumentException("Expected an object.");
            return result;
        }

        static object Get(Dictionary<string,object> item,string key)
        {
            object value;
            return item.TryGetValue(key,out value)?value:null;
        }

        static string StringArg(Dictionary<string,object> item,string key)
        {
            var value=Get(item,key) as string;
            if(String.IsNullOrWhiteSpace(value) || value.Length>2048)throw new ArgumentException("Missing or invalid "+key+".");
            return value;
        }

        void Reply(object id,object result)
        {
            Console.WriteLine(json.Serialize(new {jsonrpc="2.0",id,result}));
        }

        void Error(object id,int code,string message)
        {
            Console.WriteLine(json.Serialize(new {jsonrpc="2.0",id,error=new {code,message}}));
        }

        void Handle(string line)
        {
            object id=null;
            bool request=false;
            try
            {
                object parsed;
                try { parsed=json.DeserializeObject(line); }
                catch(ArgumentException){Error(null,-32700,"Parse error.");return;}
                catch(InvalidOperationException){Error(null,-32700,"Parse error.");return;}
                var message=parsed as Dictionary<string,object>;
                if(message==null){Error(null,-32600,"Invalid request.");return;}
                id=Get(message,"id");
                request=message.ContainsKey("id");
                if(!Equals(Get(message,"jsonrpc"),"2.0")){Error(id,-32600,"Invalid request.");return;}
                var method=StringArg(message,"method");
                if(!request)
                {
                    if(initialized && method=="notifications/initialized")ready=true;
                    return;
                }
                if(method=="initialize" && !initialized)
                {
                    var version=StringArg(Object(Get(message,"params")),"protocolVersion");
                    initialized=true;
                    Reply(id,new {protocolVersion=version=="2024-11-05" || version=="2025-11-25"?version:"2025-06-18",
                        capabilities=new {tools=new {}},serverInfo=new {name="reflexcore",version="0.2.0"}});
                    return;
                }
                if(method=="ping"){Reply(id,new {});return;}
                if(!ready){Error(id,-32002,"Complete initialization first.");return;}
                if(method=="tools/list"){Reply(id,new {tools=Tools()});return;}
                if(method!="tools/call"){Error(id,-32601,"Method not found.");return;}
                try
                {
                    var call=Object(Get(message,"params"));
                    if(!File.Exists(Path.Combine(settings,"mcp.enabled")))
                        throw new ArgumentException("MCP is off. Enable it in ReflexCore Studio.");
                    var result=Call(StringArg(call,"name"),Object(Get(call,"arguments")??new Dictionary<string,object>()));
                    Reply(id,new {structuredContent=result,content=new[]{new {type="text",text=json.Serialize(result)}}});
                }
                catch(ArgumentException error)
                {
                    Reply(id,new {isError=true,content=new[]{new {type="text",text=error.Message}}});
                }
                catch(Exception)
                {
                    Reply(id,new {isError=true,content=new[]{new {type="text",text="ReflexCore could not complete the tool call."}}});
                }
            }
            catch(ArgumentException){if(request)Error(id,-32602,"Invalid parameters.");}
            catch(InvalidOperationException){if(request)Error(id,-32600,"Invalid request.");}
        }

        static object Tool(string name,string description,string[] output,string[] fields=null,string[] optional=null,bool readOnly=true)
        {
            fields=fields??new string[0];
            var properties=fields.ToDictionary(field=>field,field=>new {type="string"});
            foreach(var field in optional??new string[0])properties.Add(field,new {type="string"});
            var resultProperties=output.ToDictionary(key=>key,key=>new {type=
                new[]{"projects","skills","bounded_replay_statistics","workflows","runs"}.Contains(key)?(object)"array":
                key=="cancellation_requested"?"boolean":key=="handoff_feedback"?"object":key=="receipt"?new[]{"object","null"}:(object)"string"});
            return new {name,description,inputSchema=new {type="object",required=fields,additionalProperties=false,properties},
                outputSchema=new {type="object",required=output,properties=resultProperties},
                annotations=new {readOnlyHint=readOnly,destructiveHint=false,openWorldHint=false}};
        }

        static object[] Tools()
        {
            return new[]{
                Tool("list_skills","Read experimental skills, local movement evidence, and executable workflow contracts.",new[]{"skills","bounded_replay_statistics","memory_state","memory_source","workflows","handoff_feedback"}),
                Tool("list_projects","Discover configured projects and locally saved handoff presets. A preset can be run without entering paths.",new[]{"projects"}),
                Tool("submit_handoff_check","Submit a handoff check for Studio approval. All paths are relative to the selected project.",new[]{"task_id","state","next_action"},
                    new[]{"folder","checklist","report"},new[]{"project"},false),
                Tool("submit_saved_handoff","Request a saved check for Studio approval. Choose a project and preset returned by list_projects.",new[]{"task_id","state","next_action"},
                    new[]{"project","preset"},null,false),
                Tool("get_task_result","Read status, the next operator step, and the typed handoff receipt for a queue task.",new[]{"task_id","state","next_action","receipt"},new[]{"task_id"}),
                Tool("cancel_task","Request cancellation. Read get_task_result for terminal confirmation.",new[]{"task_id","cancellation_requested"},new[]{"task_id"},null,false),
                Tool("list_lab_runs","Read recent summaries from owned offline experiments. Shot requests and actual shots are separate measurements.",new[]{"runs"})};
        }

        object Call(string name,Dictionary<string,object> args)
        {
            switch(name)
            {
                case "list_skills": return ReadRegistry();
                case "list_projects":
                    var presets=Presets();
                    return new {projects=Projects().OrderBy(item=>item.Key,StringComparer.OrdinalIgnoreCase)
                        .Select(item=>new {project=item.Key,capability="verify_handoff",available=Directory.Exists(item.Value),
                            presets=PresetNames(presets,item.Key)}).ToArray()};
                case "submit_saved_handoff":
                    return SubmitSaved(StringArg(args,"project"),StringArg(args,"preset"));
                case "submit_handoff_check":
                    var projects=Projects();
                    var project=Get(args,"project") as string;
                    if(project==null && projects.Count==1)project=projects.Keys.Single();
                    var scope=ProjectRoot(project,projects);
                    var folder=Scoped(scope,StringArg(args,"folder"),false);
                    var checklist=Scoped(scope,StringArg(args,"checklist"),false);
                    var report=Scoped(scope,StringArg(args,"report"),true);
                    return SubmitCheck(folder,checklist,report);
                case "list_lab_runs":
                    return new {runs=LabEvidence.ReadRecent(root)};
                case "get_task_result":
                case "cancel_task":
                    var id=StringArg(args,"task_id");
                    if(!QueueStore.ValidId(id))throw new ArgumentException("Invalid task ID.");
                    var row=queue.Snapshot().FirstOrDefault(item=>item.Id==id && item.Task=="handoff");
                    if(row==null)throw new ArgumentException("Handoff task was not found in the retained queue.");
                    if(name=="cancel_task")return new {task_id=id,cancellation_requested=queue.Request(id,"cancel")};
                    string state=row.State;
                    if(state=="pending")
                    {
                        var manifest=Path.Combine(root,"data","bridge","pending",id+".job");
                        if(File.Exists(manifest) && File.ReadLines(manifest).FirstOrDefault()=="REVIEW")
                            state=queue.Requested(manifest,"approve")?"queued":"pending_approval";
                    }
                    var next=state=="pending_approval"?"approve_in_studio":
                        new[]{"queued","pending","running","stopping"}.Contains(state)?"wait_for_status":"review_result";
                    string verdict=row.Receipt!=null && row.Receipt.handoff!=null?
                        (row.Receipt.handoff.ready?"ready":"needs_attention"):null;
                    return new {task_id=id,state,next_action=next,receipt=row.Receipt,folder_verdict=verdict,
                        workflow=new {id="verify_handoff",version=1}};
                default: throw new ArgumentException("Unknown tool.");
            }
        }

        static bool SafeName(string name)
        {
            return System.Text.RegularExpressions.Regex.IsMatch(name??"",@"\A[a-zA-Z0-9_-]{1,48}\z");
        }

        static string ProjectRoot(string key,Dictionary<string,string> projects)
        {
            string scope;
            if(key==null || !projects.TryGetValue(key,out scope))
                throw new ArgumentException("Select a configured project from list_projects.");
            return Path.GetFullPath(scope);
        }

        Dictionary<string,Dictionary<string,string>> Presets()
        {
            var file=new FileInfo(Path.Combine(settings,"mcp-handoff-presets.json"));
            var presets=new Dictionary<string,Dictionary<string,string>>(StringComparer.OrdinalIgnoreCase);
            if(!file.Exists)return presets;
            if(file.Length>16384 || (file.Attributes&FileAttributes.ReparsePoint)!=0)
                throw new ArgumentException("The saved checklist registry is invalid.");
            foreach(var entry in json.Deserialize<Dictionary<string,Dictionary<string,string>>>(File.ReadAllText(file.FullName)))
                presets.Add(entry.Key,new Dictionary<string,string>(entry.Value,StringComparer.OrdinalIgnoreCase));
            return presets;
        }

        static string[] PresetNames(Dictionary<string,Dictionary<string,string>> presets,string key)
        {
            Dictionary<string,string> saved;
            return presets.TryGetValue(key,out saved)?saved.Keys.Where(SafeName).OrderBy(name=>name,StringComparer.OrdinalIgnoreCase).ToArray():new string[0];
        }

        object SubmitSaved(string project,string preset)
        {
            var scope=ProjectRoot(project,Projects());
            Dictionary<string,string> saved;
            string relativeFolder;
            if(!SafeName(project) || !SafeName(preset) || !Presets().TryGetValue(project,out saved) ||
                !saved.TryGetValue(preset,out relativeFolder))
                throw new ArgumentException("Choose a saved preset from list_projects.");
            var folder=Scoped(scope,relativeFolder,false);
            var privateDir=Scoped(Path.Combine(root,"data"),"private",false);
            var checklist=Scoped(privateDir,Path.Combine("mcp-checklists",project+"."+preset+".json"),false);
            var reportDir=Path.Combine(privateDir,"mcp-reports");
            Directory.CreateDirectory(reportDir);
            var report=Scoped(privateDir,Path.Combine("mcp-reports",Guid.NewGuid().ToString("N")+".json"),true);
            return SubmitCheck(folder,checklist,report);
        }

        object SubmitCheck(string folder,string checklist,string report)
        {
            if(!Directory.Exists(folder) || !File.Exists(checklist) || !String.Equals(Path.GetExtension(report),".json",StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("Select a folder, an existing checklist and a new JSON report.");
            string digest;
            using(var file=File.OpenRead(checklist))
            using(var sha=System.Security.Cryptography.SHA256.Create())
            {
                if(file.Length>512*1024)throw new ArgumentException("The checklist exceeds the supported size.");
                digest=BitConverter.ToString(sha.ComputeHash(file)).Replace("-","");
            }
            var id=queue.SubmitFolderCheck(new FolderResultLink {folder=folder,checklist=checklist,report=report,checklist_sha256=digest},false);
            return new {task_id=id,state="pending_approval",next_action="approve_in_studio"};
        }

        Dictionary<string,string> Projects()
        {
            var projects=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
            var config=new FileInfo(Path.Combine(settings,"mcp-projects.json"));
            if(config.Exists)
            {
                if(config.Length>16384)throw new ArgumentException("The project registry is too large.");
                foreach(var item in json.Deserialize<Dictionary<string,string>>(File.ReadAllText(config.FullName)))
                {
                    if(!SafeName(item.Key) ||
                       String.IsNullOrWhiteSpace(item.Value) || !System.Text.RegularExpressions.Regex.IsMatch(item.Value,@"\A[A-Za-z]:\\"))
                        throw new ArgumentException("Invalid project configuration.");
                    projects.Add(item.Key,item.Value);
                }
                return projects;
            }
            var fallback=new FileInfo(Path.Combine(settings,"mcp-scope.txt"));
            if(fallback.Exists && fallback.Length<=4096)projects.Add("default",File.ReadAllText(fallback.FullName));
            return projects;
        }

        static string Scoped(string scope,string relative,bool newFile)
        {
            if(Path.IsPathRooted(relative) || relative.Contains(":") ||
                relative.Split('\\','/').Any(part=>part==".." || (part!="." && part.EndsWith(".")) || part.EndsWith(" ")))
                throw new ArgumentException("Use a relative path inside the configured folder.");
            var path=Path.GetFullPath(Path.Combine(scope,relative));
            var prefix=scope.TrimEnd('\\')+"\\";
            if(path!=scope && !path.StartsWith(prefix,StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("Path is outside the configured folder.");
            if(newFile && (File.Exists(path) || Directory.Exists(path)))
                throw new ArgumentException("Choose a new report.");
            for(var part=newFile?Path.GetDirectoryName(path):path;part!=null;part=Path.GetDirectoryName(part))
                if((File.GetAttributes(part)&FileAttributes.ReparsePoint)!=0)
                    throw new ArgumentException("Linked paths are outside the MCP scope.");
            return path;
        }

        object ReadRegistry()
        {
            var memoryRoot=root;
            var config=new FileInfo(Path.Combine(settings,"mcp-memory-root.txt"));
            if(config.Exists)
            {
                if(config.Length>4096 || (config.Attributes&FileAttributes.ReparsePoint)!=0)
                    throw new ArgumentException("The selected skill memory source is invalid.");
                memoryRoot=Path.GetFullPath(File.ReadAllText(config.FullName).Trim());
                if(!Directory.Exists(memoryRoot))throw new ArgumentException("The selected skill memory installation is unavailable.");
            }
            var start=new ProcessStartInfo(Path.Combine(root,"target","release","reflexcore.exe"),"learning registry")
            {WorkingDirectory=memoryRoot,UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
            using(var child=Process.Start(start))
            {
                child.ErrorDataReceived+=delegate {};
                child.BeginErrorReadLine();
                var output=child.StandardOutput.ReadToEndAsync();
                if(!child.WaitForExit(5000))
                {
                    if(!child.HasExited)child.Kill();
                    throw new TimeoutException();
                }
                if(child.ExitCode!=0)throw new IOException();
                var registry=Object(json.DeserializeObject(output.GetAwaiter().GetResult()));
                registry["memory_source"]=config.Exists?"configured_installation":"server_installation";
                registry["memory_state"]=!File.Exists(Path.Combine(memoryRoot,"data","private","goal-memory-v1.sqlite3"))?
                    "database_missing":((System.Collections.IList)registry["bounded_replay_statistics"]).Count==0?"no_movement_samples":"available";
                registry["workflows"]=new[]{new {id="verify_handoff",version=1,approval="studio",
                    inputs=new[]{"project","preset"},verifier="independent_disk_readback",model_calls=0}};
                var attempts=queue.Snapshot().Where(row=>row.Task=="handoff" && row.Receipt!=null)
                    .Select(row=>row.Receipt).ToArray();
                var verified=attempts.Where(receipt=>receipt.stage=="handoff" && receipt.outcome=="verified" &&
                    receipt.verification=="verified" && receipt.reason=="disk_readback" && receipt.handoff!=null).ToArray();
                registry["handoff_feedback"]=new {workflow_version=1,retained_terminal=attempts.Length,
                    verified=verified.Length,verified_needs_attention=verified.Count(receipt=>!receipt.handoff.ready),
                    cancelled=attempts.Count(receipt=>receipt.outcome=="cancelled"),
                    interrupted=attempts.Count(receipt=>receipt.outcome=="interrupted"),
                    other_unverified=attempts.Length-verified.Length-
                        attempts.Count(receipt=>receipt.outcome=="cancelled" || receipt.outcome=="interrupted")};
                return registry;
            }
        }
    }
}
