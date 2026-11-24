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
                        capabilities=new {tools=new {}},serverInfo=new {name="reflexcore",version="0.1.0"}});
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
                    Reply(id,new {content=new[]{new {type="text",text=json.Serialize(result)}}});
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

        static object Tool(string name,string description,params string[] fields)
        {
            return new {name,description,inputSchema=new {type="object",required=fields,additionalProperties=false,
                properties=fields.ToDictionary(field=>field,field=>new {type="string"})}};
        }

        static object[] Tools()
        {
            return new[]{
                Tool("list_skills","Read built-in skills and local movement evidence. Only handoff verification can be submitted by this server."),
                Tool("submit_handoff_check","Submit a handoff check for Studio approval. All paths are relative to the configured scope; use . for its root.","folder","checklist","report"),
                Tool("get_task_result","Read status and the typed handoff receipt for a queue task.","task_id"),
                Tool("cancel_task","Request cancellation of an active handoff task. Poll get_task_result for confirmation.","task_id")};
        }

        object Call(string name,Dictionary<string,object> args)
        {
            switch(name)
            {
                case "list_skills": return ReadRegistry();
                case "submit_handoff_check":
                    var config=new FileInfo(Path.Combine(settings,"mcp-scope.txt"));
                    if(!config.Exists || config.Length>4096)throw new ArgumentException("Choose an allowed folder in MCP settings.");
                    var scope=Path.GetFullPath(File.ReadAllText(config.FullName));
                    var folder=Scoped(scope,StringArg(args,"folder"),false);
                    var checklist=Scoped(scope,StringArg(args,"checklist"),false);
                    var report=Scoped(scope,StringArg(args,"report"),true);
                    if(!Directory.Exists(folder) || !File.Exists(checklist) || Path.GetExtension(report)!=".json")
                        throw new ArgumentException("Select a folder, an existing checklist and a new JSON report.");
                    var taskId=queue.SubmitFolderCheck(new FolderResultLink {folder=folder,checklist=checklist,report=report},false);
                    return new {task_id=taskId,state="pending_approval"};
                case "get_task_result":
                case "cancel_task":
                    var id=StringArg(args,"task_id");
                    if(!QueueStore.ValidId(id))throw new ArgumentException("Invalid task ID.");
                    var row=queue.Snapshot().FirstOrDefault(item=>item.Id==id && item.Task=="handoff");
                    if(row==null)throw new ArgumentException("Handoff task was not found in the retained queue.");
                    if(name=="cancel_task")return new {task_id=id,cancellation_requested=queue.Request(id,"cancel")};
                    return new {task_id=id,state=row.State,receipt=row.Receipt};
                default: throw new ArgumentException("Unknown tool.");
            }
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
            var start=new ProcessStartInfo(Path.Combine(root,"target","release","reflexcore.exe"),"learning registry")
            {WorkingDirectory=root,UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
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
                return json.DeserializeObject(output.GetAwaiter().GetResult());
            }
        }
    }
}
