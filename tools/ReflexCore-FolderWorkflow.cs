using System;
using System.IO;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace ReflexCore.Control
{
    using ReflexCore.Bridge;
    public static class FolderWorkflow
    {
        const RegexOptions Options = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;
        static readonly Regex Then = new Regex(@"(?:[,;]\s*|\s+)(?:then|затем|потом)\s+", Options);
        static readonly Regex ShortRename = new Regex(
            @"\A(?:(?:change|rename)\s+|(?:поменяй|измени|переименуй)\s+)(?<old>\.[a-z0-9][a-z0-9_-]{0,31})\s+(?:to|на)\s+(?<new>\.[a-z0-9][a-z0-9_-]{0,31})[.!]?\z", Options);

        public static bool TryBuild(string request,out string[] checklist,out string source,out string destination)
        {
            checklist=null; source=destination="";
            if(String.IsNullOrWhiteSpace(request) || request.Length>8192)return false;
            foreach(Match separator in Then.Matches(request)){
                string[] candidate;
                if(HandoffDraft.Build(request.Substring(0,separator.Index),out candidate)!=HandoffDraftState.Draft)continue;
                string tail=request.Substring(separator.Index+separator.Length).Trim();
                if(!ExtensionRename.TryParse(tail,out source,out destination)){
                    var match=ShortRename.Match(tail);
                    if(!match.Success)continue;
                    source=match.Groups["old"].Value; destination=match.Groups["new"].Value;
                }
                checklist=candidate;
                return true;
            }
            return false;
        }

        public static bool CanContinue(TaskReceipt receipt,FolderResultLink link,bool validReport)
        {
            return validReport && receipt!=null && receipt.stage=="handoff" && receipt.run_id==receipt.task_id &&
                receipt.outcome=="verified" && receipt.verification=="verified" && receipt.reason=="disk_readback" &&
                receipt.handoff!=null && receipt.handoff.ready && receipt.handoff.present>0 &&
                receipt.handoff.missing==0 && receipt.handoff.mismatched==0 && receipt.handoff.unreadable==0 &&
                receipt.handoff.changed==0 && link!=null && !String.IsNullOrEmpty(link.new_extension);
        }

        sealed class ReportDocument
        {
            public string schema { get; set; }
            public string run_id { get; set; }
            public string verdict { get; set; }
            public ReportChecklist checklist { get; set; }
            public ReportEntry[] results { get; set; }
        }
        sealed class ReportChecklist
        {
            public string schema { get; set; }
            public ReportFile[] files { get; set; }
        }
        sealed class ReportFile { public string path { get; set; } }
        sealed class ReportEntry { public string status { get; set; }
        }

        public static bool MatchesReport(string file,TaskReceipt receipt)
        {
            if(String.IsNullOrEmpty(file) || receipt==null || receipt.stage!="handoff" || receipt.handoff==null)return false;
            try {
                var info=new FileInfo(file);
                if(!info.Exists || (info.Attributes&FileAttributes.ReparsePoint)!=0)return false;
                using(var input=File.Open(file,FileMode.Open,FileAccess.Read,FileShare.Read)){
                    if(input.Length>4*1024*1024)return false;
                    using(var reader=new StreamReader(input)){
                        var report=new JavaScriptSerializer{MaxJsonLength=4*1024*1024,RecursionLimit=12}
                            .Deserialize<ReportDocument>(reader.ReadToEnd());
                        if(report==null || report.schema!="reflexcore.handoff.report.v1" || report.run_id!=receipt.run_id ||
                           report.verdict!=(receipt.handoff.ready?"Ready":"Needs attention") || report.results==null ||
                           report.checklist==null || report.checklist.schema!="reflexcore.handoff.checklist.v1" ||
                           report.checklist.files==null || report.results.Length!=report.checklist.files.Length ||
                           report.results.Length==0 || report.results.Length>1024)return false;
                        var counts=new System.Collections.Generic.Dictionary<string,int>(StringComparer.Ordinal){
                            {"present",0},{"missing",0},{"mismatched",0},{"unreadable",0},{"changed",0}
                        };
                        for(int i=0;i<report.results.Length;i++){
                            var finding=report.results[i];
                            var item=report.checklist.files[i];
                            if(finding==null || finding.status==null || !counts.ContainsKey(finding.status) ||
                               item==null || String.IsNullOrEmpty(item.path))return false;
                            counts[finding.status]++;
                        }
                        var expected=receipt.handoff;
                        return counts["present"]==expected.present && counts["missing"]==expected.missing &&
                            counts["mismatched"]==expected.mismatched && counts["unreadable"]==expected.unreadable &&
                            counts["changed"]==expected.changed;
                    }
                }
            } catch(IOException) { return false; }
              catch(UnauthorizedAccessException) { return false; }
              catch(ArgumentException) { return false; }
              catch(InvalidOperationException) { return false; }
        }
    }
}
