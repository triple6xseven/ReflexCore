---
name: offline-lab-evidence
description: Inspect ReflexCore's published evidence from owned offline game experiments and explain what the results support.
---

For a combat run ID call `get_combat_run`. Use `list_combat_runs` to discover available trials and `compare_combat_runs` for a matched baseline and candidate from the same scenario and suite. Use `list_lab_runs` for ordinary offline match summaries. Identify the run ID and map. Keep shot requests, confirmed discharges, damage events, and the independent round result separate. A missing measurement is unknown. A truncated, cancelled, or infrastructure-failed run is not an independently confirmed match. A plant or round win alone does not demonstrate combat improvement.

For comparisons use the same compatible fixture and count every attempt. Report what the evidence cannot establish. This workflow reads published summaries and does not launch a match.

Use the earliest confirmed failure stage. An accepted attack command can reach the game while the weapon remains on cooldown. A discharge requires corroborating clip consumption and playback evidence. Damage remains separate from discharge. Pass any AI policy proposal back as a documented experiment. An observation or proposal does not activate a policy.
