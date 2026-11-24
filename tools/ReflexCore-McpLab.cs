using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace ReflexCore.Bridge
{
    internal sealed class LabRun
    {
        public string schema {get;set;}
        public string run_id {get;set;}
        public string map {get;set;}
        public string termination {get;set;}
        public bool server_log_confirmed {get;set;}
        public int? contacts {get;set;}
        public int? shot_requests {get;set;}
        public int? discharges {get;set;}
        public int? hits {get;set;}
        public int? defender_discharges {get;set;}
        public bool? plant {get;set;}
        public bool? win {get;set;}
        public bool? death {get;set;}
        public long? observation_p95_us {get;set;}
        public long? decision_p95_us {get;set;}
    }

    internal static class LabEvidence
    {
        public static LabRun[] ReadRecent(string root)
        {
            string folder=Path.Combine(root,"data","private","mcp-lab");
            if(!Directory.Exists(folder) || (File.GetAttributes(folder)&FileAttributes.ReparsePoint)!=0)return new LabRun[0];
            var json=new JavaScriptSerializer {MaxJsonLength=8192,RecursionLimit=4};
            var runs=new List<LabRun>();
            foreach(var file in new DirectoryInfo(folder).EnumerateFiles("*.json")
                .Where(item=>Regex.IsMatch(item.Name,@"\A[a-f0-9]{32}\.json\z"))
                .OrderByDescending(item=>item.LastWriteTimeUtc).Take(20))
            {
                try
                {
                    if(file.Length>8192 || (file.Attributes&FileAttributes.ReparsePoint)!=0)continue;
                    var run=json.Deserialize<LabRun>(File.ReadAllText(file.FullName));
                    if(run==null || run.run_id+".json"!=file.Name || run.schema!="reflexcore.lab.run.v1" ||
                       !Regex.IsMatch(run.map??"",@"\Ade_[a-z0-9_]{1,29}\z") ||
                       !new[]{"completed","cancelled","truncated","infrastructure_failure"}.Contains(run.termination) ||
                       run.server_log_confirmed!=(run.termination=="completed") ||
                       (!run.server_log_confirmed && (run.plant.HasValue || run.win.HasValue || run.death.HasValue)) ||
                       (run.server_log_confirmed && (!run.plant.HasValue || !run.win.HasValue || !run.death.HasValue)) ||
                       new[]{run.contacts,run.shot_requests,run.discharges,run.hits,run.defender_discharges}.Any(value=>value<0) ||
                       run.observation_p95_us<0 || run.decision_p95_us<0)continue;
                    runs.Add(run);
                }
                catch(IOException){}
                catch(UnauthorizedAccessException){}
                catch(InvalidOperationException){}
                catch(ArgumentException){}
            }
            return runs.ToArray();
        }
    }
}
