use super::{saved_text, Capability, Operation, Skill, SKILLS};
use serde::{Deserialize, Serialize};
use std::io::{self, Read};

const LIMIT: u64 = 4096;
const FIXTURE: &str = "reflexcore.document-preview-fixture.v1";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Descriptor {
    schema: String,
    applications: Vec<String>,
    operation: String,
    capabilities: Vec<Capability>,
    verifier: String,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
enum InputPort {
    OwnedSavedFile,
    ExpectedText,
}

fn validate(descriptor: &Descriptor) -> crate::Result<&'static Skill> {
    if descriptor.schema != "reflexcore.discovery.descriptor.v1" {
        return Err("Unsupported discovery descriptor schema".into());
    }
    if descriptor.applications.as_slice() != [FIXTURE] {
        return Err("Discovery requires one recognized fixture application".into());
    }
    let skill = SKILLS
        .iter()
        .find(|skill| {
            skill.operation == Operation::VerifySavedText && skill.id == descriptor.operation
        })
        .ok_or("Unsupported fixture operation")?;
    if descriptor.capabilities.len() != skill.requires.len()
        || !skill
            .requires
            .iter()
            .all(|cap| descriptor.capabilities.contains(cap))
    {
        return Err("Capability declaration does not match the registry contract".into());
    }
    if descriptor.verifier != skill.verifier {
        return Err("An independent registered verifier is required".into());
    }
    Ok(skill)
}

pub(crate) fn run() -> crate::Result<()> {
    crate::task_integrity::check_cancel()?;
    let mut bytes = Vec::new();
    io::stdin().lock().take(LIMIT + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > LIMIT {
        return Err("Discovery descriptor exceeds 4096 bytes".into());
    }
    // Windows PowerShell can prefix piped UTF-8 with a byte-order mark.
    let json = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&bytes);
    let descriptor = serde_json::from_slice(json)?;
    let skill = validate(&descriptor)?;
    let binding = saved_text::bind(skill.id, skill.version, saved_text::Adapter::Winforms, true)?;
    let observed = crate::flow::observe_discovery_fixture()?;
    crate::task_integrity::check_cancel()?;
    println!(
        "{}",
        serde_json::json!({
            "schema": "reflexcore.discovery.candidate.v1",
            "status": "candidate",
            "application": FIXTURE,
            "binding": binding,
            "binding_evidence": "owned_window_value_readback_v1",
            "operation": {"id": skill.id, "version": skill.version},
            "inputs": [InputPort::OwnedSavedFile, InputPort::ExpectedText],
            "output": "reflexcore.skill.evidence.v1",
            "capabilities": skill.requires,
            "verifier": skill.verifier,
            "effect_verification": "pending",
            "model_calls": 0,
            "observation_metrics": observed,
        })
    );
    Ok(())
}
