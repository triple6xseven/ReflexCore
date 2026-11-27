use serde::Serialize;
pub(crate) mod saved_text;
pub(crate) mod composition;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Capability {
    ObserveMotion,
    ProbeMotion,
    ApplyBoundedPulse,
    OwnedGoldsrcPractice,
    OwnedArtifact,
    ReopenDisk,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Operation {
    Probe,
    FixedPulse,
    CalibratedPulse,
    GoldsrcPulse,
    VerifySavedText,
}

#[derive(Serialize)]
pub(crate) struct Skill {
    pub id: &'static str,
    pub version: u32,
    category: &'static str,
    from: &'static str,
    to: &'static str,
    requires: &'static [Capability],
    inputs: &'static [&'static str],
    effect: &'static str,
    verifier: &'static str,
    cost: u32,
    pub operation: Operation,
}

pub(crate) const GOLDSRC_PULSE_ID: &str = "cs16.advance";

impl Skill {
    pub(crate) fn catalog_entry(&self) -> serde_json::Value {
        let mut entry = serde_json::json!(self);
        if self.operation == Operation::VerifySavedText {
            entry["description"] = "Verify the exact text saved by the requested editor".into();
            entry["status"] = "executable".into();
            entry["domain"] = "artifact".into();
            entry["contract_version"] = 1.into();
            entry["bindings"] = serde_json::json!(saved_text::BINDINGS);
            entry["output"] = "reflexcore.skill.evidence.v1".into();
            entry["permission"] = "read_owned_output".into();
            entry["max_bytes"] = saved_text::LIMIT.into();
        } else {
            entry["status"] = "experimental_lab".into();
            entry["domain"] = if self.operation == Operation::GoldsrcPulse {
                "goldsrc"
            } else {
                "motion"
            }
            .into();
        }
        entry
    }
}

pub(crate) const SKILLS: &[Skill] = &[
    Skill {
        id: saved_text::ID,
        version: 1,
        category: "universal",
        from: "save_issued",
        to: "saved_text_confirmed",
        requires: &[Capability::OwnedArtifact, Capability::ReopenDisk],
        inputs: &["owned_saved_file", "expected_text"],
        effect: "saved_text_equals_expected",
        verifier: "bounded_ordinal_disk_readback_v1",
        cost: 1,
        operation: Operation::VerifySavedText,
    },
    Skill {
        id: "motion.probe",
        version: 1,
        category: "universal",
        from: "start",
        to: "calibrated",
        requires: &[Capability::ObserveMotion, Capability::ProbeMotion],
        inputs: &["bounded_probe"],
        effect: "measured_progress",
        verifier: "finite_positive_probe_readback",
        cost: 1,
        operation: Operation::Probe,
    },
    Skill {
        id: "motion.fixed",
        version: 1,
        category: "universal",
        from: "start",
        to: "arrived",
        requires: &[Capability::ObserveMotion, Capability::ApplyBoundedPulse],
        inputs: &["remaining_distance"],
        effect: "target_reached",
        verifier: "settled_position_in_tolerance",
        cost: 50,
        operation: Operation::FixedPulse,
    },
    Skill {
        id: "motion.calibrated",
        version: 1,
        category: "universal",
        from: "calibrated",
        to: "arrived",
        requires: &[Capability::ObserveMotion, Capability::ApplyBoundedPulse],
        inputs: &[
            "remaining_distance",
            "measured_progress",
            "observation_delay",
        ],
        effect: "target_reached",
        verifier: "settled_position_in_tolerance",
        cost: 10,
        operation: Operation::CalibratedPulse,
    },
    Skill {
        id: GOLDSRC_PULSE_ID,
        version: 1,
        category: "environment",
        from: "goldsrc_ready",
        to: "goldsrc_motion_observed",
        requires: &[
            Capability::OwnedGoldsrcPractice,
            Capability::ApplyBoundedPulse,
        ],
        inputs: &["forward_pulse_ms"],
        effect: "horizontal_displacement",
        verifier: "fresh_owned_actor_readback",
        cost: 10,
        operation: Operation::GoldsrcPulse,
    },
];

pub(crate) fn plan(
    capabilities: &[Capability],
    allow_calibration: bool,
) -> Result<Vec<&'static Skill>, Box<dyn std::error::Error>> {
    let eligible: Vec<_> = SKILLS
        .iter()
        .filter(|skill| {
            (allow_calibration || skill.operation == Operation::FixedPulse)
                && skill
                    .requires
                    .iter()
                    .all(|required| capabilities.contains(required))
        })
        .collect();
    let edges: Vec<_> = eligible
        .iter()
        .map(|s| (s.id, s.from, s.to, s.cost))
        .collect();
    let path = crate::agent::plan_edges("start", "arrived", &edges)?;
    Ok(path.into_iter().map(|i| eligible[i]).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn composes_capable_skills_and_refuses_missing_actuator() {
        let limited = [Capability::ObserveMotion, Capability::ApplyBoundedPulse];
        assert_eq!(
            plan(&limited, true).unwrap()[0].operation,
            Operation::FixedPulse
        );
        let full = [limited[0], limited[1], Capability::ProbeMotion];
        let choices: Vec<_> = plan(&full, true)
            .unwrap()
            .iter()
            .map(|s| s.operation)
            .collect();
        assert_eq!(choices, [Operation::Probe, Operation::CalibratedPulse]);
        assert!(plan(&[Capability::ObserveMotion], true).is_err());
    }
}
