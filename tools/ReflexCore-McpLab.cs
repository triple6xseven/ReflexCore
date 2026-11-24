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

    internal sealed class CombatRun
    {
        public string schema {get;set;}
        public string run_id {get;set;}
        public string suite_id {get;set;}
        public string map {get;set;}
        public string scenario {get;set;}
        public string policy {get;set;}
        public string termination {get;set;}
        public string reason {get;set;}
        public string verifier {get;set;}
        public string memory_status {get;set;}
        public int? attacker_requests {get;set;}
        public int? discharges {get;set;}
        public int? damage_events {get;set;}
        public int? selection_errors {get;set;}
        public long? reaction_us {get;set;}
        public double? observation_age_ms {get;set;}
        public int? primary_attack_events {get;set;}
        public int? playback_events {get;set;}
        public int? attack_command_events {get;set;}
        public int? action_id {get;set;}
        public int? generation {get;set;}
        public int? clip_before {get;set;}
        public int? clip_after {get;set;}
        public double? player_timer_ms {get;set;}
        public double? weapon_timer_ms {get;set;}
        public double? target_displacement {get;set;}
        public int? health_loss {get;set;}
        public bool cancellation_acknowledged {get;set;}
        public bool cancellation_boundary_verified {get;set;}
        public long? peak_worker_bytes {get;set;}
        public int model_calls {get;set;}
    }

    internal static class LabEvidence
    {
        static bool RunId(string value)
        {
            return Regex.IsMatch(value??"", @"\A[a-f0-9]{32}\z");
        }

        static string CombatDirectory(string root)
        {
            return Path.Combine(root,"data","private","mcp-combat");
        }

        static CombatRun ReadCombatFile(FileInfo file)
        {
            try
            {
                if(!file.Exists || file.Length>8192 || (file.Attributes&FileAttributes.ReparsePoint)!=0)return null;
                var json=new JavaScriptSerializer {MaxJsonLength=8192,RecursionLimit=4};
                var run=json.Deserialize<CombatRun>(File.ReadAllText(file.FullName));
                if(run==null || !RunId(run.run_id) || !RunId(run.suite_id) || file.Name!=run.run_id+".json" ||
                   run.schema!="reflexcore.lab.combat.v1" || run.map!="de_reflex_lab" || run.model_calls!=0 ||
                   run.verifier!="goldsrc_weapon_trace_v1" ||
                   !new[]{"stationary","moving","friendly","occluded","heldout_moving","heldout_occluded"}.Contains(run.scenario) ||
                   !new[]{"baseline","candidate"}.Contains(run.policy) ||
                   !new[]{"completed","cancelled","timeout","lost_evidence","infrastructure_failure"}.Contains(run.termination) ||
                   !new[]{"fixture_setup","setup","weapon_observation","cancel_barrier","attack_request","worker_deadline",
                        "foreign_trace","discharge_evidence_disagrees","identity_changed","friendly_target","occluded_target",
                        "wrong_weapon","empty_clip","clip_decreased","weapon_timer_active",
                        "primary_not_observed","primary_without_discharge"}.Contains(run.reason) ||
                   !new[]{"not_requested","ineligible","recorded","write_failed","off"}.Contains(run.memory_status) ||
                   run.attacker_requests<0 || run.attacker_requests>1 || (run.termination=="completed" && (!run.discharges.HasValue || run.discharges<0 || run.discharges>1 || run.playback_events!=run.discharges)) ||
                   (run.termination=="completed" && (run.attacker_requests!=1 || !run.action_id.HasValue ||
                    !run.generation.HasValue || !run.reaction_us.HasValue || !run.observation_age_ms.HasValue)) ||
                   (run.cancellation_boundary_verified && (!run.cancellation_acknowledged || run.termination!="cancelled" ||
                    run.attacker_requests!=0)))return null;
                return run;
            }
            catch(IOException){return null;}
            catch(UnauthorizedAccessException){return null;}
            catch(ArgumentException){return null;}
            catch(InvalidOperationException){return null;}
        }

        public static CombatRun[] ReadCombatRecent(string root)
        {
            var directory=new DirectoryInfo(CombatDirectory(root));
            if(!directory.Exists || (directory.Attributes&FileAttributes.ReparsePoint)!=0)return new CombatRun[0];
            return directory.EnumerateFiles("*.json").Where(file=>RunId(Path.GetFileNameWithoutExtension(file.Name)))
                .OrderByDescending(file=>file.LastWriteTimeUtc).Take(20)
                .Select(ReadCombatFile).Where(run=>run!=null).ToArray();
        }

        public static CombatRun ReadCombat(string root,string id)
        {
            if(!RunId(id))throw new ArgumentException("Enter a combat run ID from list_combat_runs.");
            var directory=new DirectoryInfo(CombatDirectory(root));
            if(!directory.Exists || (directory.Attributes&FileAttributes.ReparsePoint)!=0)
                throw new ArgumentException("No comparable combat evidence has been published.");
            var run=ReadCombatFile(new FileInfo(Path.Combine(directory.FullName,id+".json")));
            if(run==null)throw new ArgumentException("The selected run has no validated combat evidence.");
            return run;
        }

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
