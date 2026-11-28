use crate::{
    neural_runtime::{Model, PULSES},
    skill_registry::{self, Capability, Operation},
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{hint::black_box, time::Instant};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
const SEED: u64 = 701_242;
// The controller's near-target limit was tuned on +110/+120, which are excluded.
const GROUND_TEST_SEED: u64 = SEED + 9_110;
const ARENA_TEST_SEED: u64 = SEED + 9_120;
const REPLAY_PER_FIXTURE: usize = 900;
const VALIDATION_CASES: usize = 256;
const TARGET_TOLERANCE: f32 = 0.09;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Mode {
    Off,
    ObserveOnly,
    Adaptive,
    ExperimentalNeural,
}

impl Mode {
    pub(crate) fn configured() -> Result<Self> {
        Ok(match std::env::var("REFLEX_LEARNING_MODE").as_deref() {
            Err(std::env::VarError::NotPresent) | Ok("adaptive") => Self::Adaptive,
            Ok("off") => Self::Off,
            Ok("observe") => Self::ObserveOnly,
            Ok("neural") => Self::ExperimentalNeural,
            _ => {
                return Err("REFLEX_LEARNING_MODE must be off, observe, adaptive, or neural".into())
            }
        })
    }

    pub(crate) fn records(self) -> bool {
        self != Self::Off
    }
    pub(crate) fn adapts(self) -> bool {
        matches!(self, Self::Adaptive | Self::ExperimentalNeural)
    }
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> f32 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1);
        (self.0 >> 40) as f32 / 16_777_216.0
    }
}

#[derive(Clone, Copy)]
enum Fixture {
    Ground,
    Arena,
}

impl Fixture {
    fn id(self) -> &'static str {
        match self {
            Self::Ground => "ground_v1",
            Self::Arena => "arena_v1",
        }
    }
}

trait EnvironmentAdapter {
    fn capabilities(&self) -> &'static [Capability];
    fn probe(&self) -> f32;
    fn remaining(&self) -> f32;
    fn delay_ms(&self) -> f32;
    fn apply(&mut self, pulse: f32) -> f32;
    fn verify(&self) -> bool;
}

#[derive(Clone, Copy)]
struct Segment {
    fixture: Fixture,
    error: f32,
    gain: f32,
    delay: f32,
}
impl Segment {
    fn sample(fixture: Fixture, rng: &mut Rng) -> Self {
        Self {
            fixture,
            error: 0.18 + rng.next() * 2.0,
            gain: 0.27 + 1.07 * rng.next(),
            delay: 14.0 + 108.0 * rng.next(),
        }
    }

    fn displacement(&self, pulse: f32) -> f32 {
        match self.fixture {
            Fixture::Ground => self.gain * pulse * (1.0 - self.delay * 0.0013),
            Fixture::Arena => {
                self.gain * (0.61 * pulse + 0.29 * pulse.powi(2)) * (1.0 - self.delay * 0.0006)
            }
        }
    }

    fn features(&self, probe: f32) -> [f32; 3] {
        [
            self.remaining().abs().min(1.25),
            probe / PULSES[1],
            self.delay_ms() / 130.0,
        ]
    }
}
impl EnvironmentAdapter for Segment {
    fn capabilities(&self) -> &'static [Capability] {
        &[
            Capability::ObserveMotion,
            Capability::ProbeMotion,
            Capability::ApplyBoundedPulse,
        ]
    }
    fn probe(&self) -> f32 {
        self.displacement(PULSES[1])
    }
    fn remaining(&self) -> f32 {
        self.error
    }
    fn delay_ms(&self) -> f32 {
        self.delay
    }
    fn apply(&mut self, pulse: f32) -> f32 {
        let movement = self.displacement(pulse).copysign(self.error);
        self.error -= movement;
        movement.abs()
    }
    fn verify(&self) -> bool {
        self.error.abs() <= TARGET_TOLERANCE
    }
}

#[derive(Clone, Serialize)]
pub(crate) struct Experience {
    pub environment: &'static str,
    pub features: [f32; 3],
    pub action: usize,
    pub expected_effect: f32,
    pub actual_effect: f32,
    pub verified: bool,
    pub reward: f32,
}

fn collect(fixture: Fixture, seed: u64) -> (Vec<Experience>, Vec<([f32; 3], usize)>) {
    let mut rng = Rng(seed);
    let mut replay = Vec::with_capacity(REPLAY_PER_FIXTURE * PULSES.len());
    let mut labels = Vec::with_capacity(REPLAY_PER_FIXTURE);
    for _ in 0..REPLAY_PER_FIXTURE {
        let mut segment = Segment::sample(fixture, &mut rng);
        segment.error = 0.1 + rng.next() * 1.35;
        let probe = segment.probe();
        let x = segment.features(probe);
        let mut best = (f32::NEG_INFINITY, 0);
        for (action, pulse) in PULSES.into_iter().enumerate() {
            // Explore all bounded pulses on cloned fixtures only. Labels are based
            // on settled readback after the action, not on the requested duration.
            let mut trial = segment;
            let actual_effect = trial.apply(pulse);
            let verified = trial.verify();
            let reward = if verified {
                1.0
            } else {
                -trial.remaining().abs()
            } - pulse * 0.09
                - if trial.remaining() < -TARGET_TOLERANCE {
                    0.34
                } else {
                    0.0
                };
            replay.push(Experience {
                environment: fixture.id(),
                features: x,
                action,
                expected_effect: (pulse / PULSES[1] * probe).min(segment.error),
                actual_effect,
                verified,
                reward,
            });
            if reward > best.0 {
                best = (reward, action);
            }
        }
        labels.push((x, best.1));
    }
    (replay, labels)
}

#[derive(Clone, Copy)]
enum Policy<'a> {
    Fixed,
    Calibrated,
    Neural(&'a Model),
}

fn calibrated(features: [f32; 3]) -> usize {
    let [remaining, gain, _] = features;
    (0..PULSES.len())
        .min_by(|&a, &b| {
            let cost = |i: usize| {
                let error = remaining - PULSES[i] * gain;
                error.abs() + if error < -TARGET_TOLERANCE { 0.24 } else { 0.0 }
            };
            cost(a).total_cmp(&cost(b))
        })
        .unwrap_or(1)
}

#[derive(Default, Serialize)]
struct Metrics {
    cases: usize,
    successes: usize,
    errors: usize,
    overshoots: usize,
    pulses: usize,
    mean_simulated_ms: f64,
    mean_decision_ns: u128,
}

fn evaluate(fixture: Fixture, seed: u64, policy: Policy<'_>) -> Result<Metrics> {
    let mut rng = Rng(seed);
    let template = Segment::sample(fixture, &mut Rng(seed));
    let plan = skill_registry::plan(template.capabilities(), !matches!(policy, Policy::Fixed))?;
    let mut metrics = Metrics {
        cases: VALIDATION_CASES,
        ..Metrics::default()
    };
    let mut elapsed = 0.0f64;
    let mut nanos = 0;
    for _ in 0..VALIDATION_CASES {
        let mut segment = Segment::sample(fixture, &mut rng);
        let mut probe = None;
        for skill in &plan {
            if skill.operation == Operation::Probe {
                let gain = segment.probe();
                if gain.is_finite() && gain > 0.0 {
                    probe = Some(gain);
                }
                elapsed += f64::from(segment.delay_ms() + 43.0);
                continue;
            }
            for _ in 0..16 {
                if segment.verify() {
                    break;
                }
                let start = Instant::now();
                let choice = black_box(match (policy, probe) {
                    (Policy::Calibrated, Some(gain)) => calibrated(segment.features(gain)),
                    (Policy::Neural(model), Some(gain)) => model.choose(segment.features(gain)),
                    _ if segment.remaining().abs() < 0.29 => 0,
                    _ => 1,
                });
                let old = segment.remaining();
                // Neither a checkpoint nor the adaptive selector can bypass the
                // shared motion limit. The measured gain bounds near-target pulses.
                let pulse = match probe {
                    Some(measured) => {
                        let upper_gain = measured / PULSES[1] * 1.22;
                        PULSES[choice].min((old.abs() + TARGET_TOLERANCE * 0.65) / upper_gain)
                    }
                    None => PULSES[choice],
                };
                nanos += start.elapsed().as_nanos();
                segment.apply(pulse);
                if old.signum() != segment.remaining().signum() && !segment.verify() {
                    metrics.overshoots += 1;
                }
                metrics.pulses += 1;
                elapsed += f64::from(segment.delay_ms() + 100.0 * pulse);
            }
        }
        if segment.verify() {
            metrics.successes += 1;
        }
    }
    metrics.errors = metrics.cases - metrics.successes;
    metrics.mean_simulated_ms = elapsed / metrics.cases as f64;
    metrics.mean_decision_ns = nanos / metrics.pulses.max(1) as u128;
    Ok(metrics)
}

fn train(model: &mut Model, old: &[([f32; 3], usize)], new: &[([f32; 3], usize)], rng: &mut Rng) {
    const BATCH_SIZE: usize = 16;
    for _ in 0..1250 {
        let batch: [_; BATCH_SIZE] = std::array::from_fn(|index| {
            let pool = if index % 2 == 0 { old } else { new };
            pool[(rng.next() * pool.len() as f32) as usize]
        });
        model.train_batch(&batch);
    }
}

fn version(model: &Model) -> Result<(String, Vec<u8>)> {
    let bytes = serde_json::to_vec(model)?;
    Ok((format!("{:x}", Sha256::digest(&bytes)), bytes))
}

fn peak_working_set() -> Option<usize> {
    use windows::Win32::System::{
        ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS},
        Threading::GetCurrentProcess,
    };
    let size = std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32;
    let mut counters = PROCESS_MEMORY_COUNTERS {
        cb: size,
        ..Default::default()
    };
    // The current-process pseudo-handle is valid for the stack buffer above.
    unsafe { GetProcessMemoryInfo(GetCurrentProcess(), &mut counters, size) }.ok()?;
    Some(counters.PeakWorkingSetSize)
}

fn experiment(persist: bool) -> Result<()> {
    let (ground_replay, ground) = collect(Fixture::Ground, SEED + 10);
    let (arena_replay, arena) = collect(Fixture::Arena, SEED + 20);
    let mut rng = Rng(SEED);
    let baseline_model = Model::seeded(&mut || rng.next());
    let (baseline_hash, _) = version(&baseline_model)?;
    let mut candidate = baseline_model.clone();
    let started = Instant::now();
    train(&mut candidate, &ground, &ground, &mut rng);
    let source_training_us = started.elapsed().as_micros();
    let baseline_arena = evaluate(Fixture::Arena, ARENA_TEST_SEED, Policy::Fixed)?;
    let transfer = evaluate(Fixture::Arena, ARENA_TEST_SEED, Policy::Neural(&candidate))?;
    let started = Instant::now();
    train(&mut candidate, &ground, &arena, &mut rng);
    let replay_training_us = started.elapsed().as_micros();
    let (candidate_hash, checkpoint) = version(&candidate)?;
    let baseline_ground = evaluate(Fixture::Ground, GROUND_TEST_SEED, Policy::Fixed)?;
    let held_ground = evaluate(
        Fixture::Ground,
        GROUND_TEST_SEED,
        Policy::Neural(&candidate),
    )?;
    let held_arena = evaluate(Fixture::Arena, ARENA_TEST_SEED, Policy::Neural(&candidate))?;
    let passed = candidate_hash != baseline_hash
        && quality_gate(&baseline_ground, &baseline_arena, &held_ground, &held_arena);
    let report = serde_json::json!({
        "schema": "reflexcore.learning.report.v1", "seed": SEED,
        "validation_seeds": {"ground": GROUND_TEST_SEED, "arena": ARENA_TEST_SEED},
        "scope": "two synthetic settled-pulse simulators; no CS16, Citadel or desktop input",
        "baseline_weights": baseline_hash, "candidate_weights": candidate_hash,
        "accepted_for_lab": passed, "active_in_core": false,
        "parameters": 87, "batch_size": 16, "training_examples": ground.len() + arena.len(),
        "source_training_us": source_training_us, "replay_training_us": replay_training_us,
        "checkpoint_bytes": checkpoint.len(), "gpu_used": false,
        "peak_process_working_set_bytes": peak_working_set(),
        "ground": {"fixed": baseline_ground, "random_weights": evaluate(Fixture::Ground, GROUND_TEST_SEED, Policy::Neural(&baseline_model))?,
                   "calibrated": evaluate(Fixture::Ground, GROUND_TEST_SEED, Policy::Calibrated)?, "learned": held_ground},
        "arena": {"fixed": baseline_arena, "random_weights": evaluate(Fixture::Arena, ARENA_TEST_SEED, Policy::Neural(&baseline_model))?,
                  "calibrated": evaluate(Fixture::Arena, ARENA_TEST_SEED, Policy::Calibrated)?,
                  "transfer_from_ground_only": transfer, "learned": held_arena}
    });
    if persist {
        crate::agent::memory::record_motion(
            ground_replay.iter().chain(&arena_replay),
            if passed {
                Some((&candidate_hash, &checkpoint))
            } else {
                None
            },
            "motion.calibrated",
        )?;
    }
    println!("{}", serde_json::to_string_pretty(&report)?);
    Ok(())
}

fn quality_gate(a: &Metrics, b: &Metrics, new_a: &Metrics, new_b: &Metrics) -> bool {
    new_a.successes >= a.successes
        && new_b.successes >= b.successes
        && new_a.successes + new_b.successes > a.successes + b.successes
        && new_a.overshoots <= a.overshoots
        && new_b.overshoots <= b.overshoots
}

fn validate_saved(id: &str) -> Result<()> {
    if id.len() != 64
        || !id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err("Expected a lowercase SHA-256 checkpoint ID".into());
    }
    let bytes = crate::agent::memory::read_lab_checkpoint(id)?;
    let model: Model = serde_json::from_slice(&bytes)?;
    let a = evaluate(Fixture::Ground, GROUND_TEST_SEED, Policy::Fixed)?;
    let b = evaluate(Fixture::Arena, ARENA_TEST_SEED, Policy::Fixed)?;
    let new_a = evaluate(Fixture::Ground, GROUND_TEST_SEED, Policy::Neural(&model))?;
    let new_b = evaluate(Fixture::Arena, ARENA_TEST_SEED, Policy::Neural(&model))?;
    if !quality_gate(&a, &b, &new_a, &new_b) {
        return Err("Checkpoint failed evaluation and remains inactive".into());
    }
    println!(
        "{}",
        serde_json::json!({"checkpoint": id, "ground": new_a, "arena": new_b, "active_in_core": false})
    );
    Ok(())
}

pub(crate) fn run(args: &[String]) -> Result<()> {
    match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["verify-notepad", run, scope] => skill_registry::saved_text::verify_notepad(run, scope),
        ["bind", id, version, app, mode] => skill_registry::saved_text::describe_binding(id, version, app, mode),
        ["discover"] => skill_registry::discovery::run(),
        ["registry"] => {
            let reliability = crate::agent::memory::lab_reliability()?;
            println!("{}", serde_json::to_string_pretty(&serde_json::json!({
                "schema": "reflexcore.skill_catalog.v1",
                "compositions": skill_registry::composition::catalog(),
                "skills": skill_registry::SKILLS.iter().map(|s| s.catalog_entry()).collect::<Vec<_>>(),
                "bounded_replay_statistics": reliability.into_iter().map(|(environment, skill, trials, verified)| {
                    serde_json::json!({"environment": environment, "skill": skill, "version": 1, "trials": trials, "verified_one_pulse": verified})
                }).collect::<Vec<_>>()
            }))?);
            Ok(())
        }
        ["models"] => {
            println!("{}", serde_json::to_string_pretty(crate::neural_runtime::MODELS)?);
            Ok(())
        }
        ["experiment"] => experiment(false),
        ["validate", id] => validate_saved(id),
        ["experiment", "--persist"] if Mode::configured()? == Mode::ExperimentalNeural => experiment(true),
        _ => Err("Usage: learning discover | learning registry | learning models | learning experiment [--persist with REFLEX_LEARNING_MODE=neural] | learning validate <checkpoint-id>".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replay_updates_weights_and_preserves_held_out_scenarios() {
        let (_, old) = collect(Fixture::Ground, SEED + 10);
        let (_, new) = collect(Fixture::Arena, SEED + 20);
        let mut rng = Rng(SEED);
        let mut candidate = Model::seeded(&mut || rng.next());
        let before = version(&candidate).unwrap().0;
        train(&mut candidate, &old, &old, &mut rng);
        let source = evaluate(Fixture::Arena, ARENA_TEST_SEED, Policy::Neural(&candidate)).unwrap();
        let b = evaluate(Fixture::Arena, ARENA_TEST_SEED, Policy::Fixed).unwrap();
        assert!(source.successes > b.successes);
        train(&mut candidate, &old, &new, &mut rng);
        assert_ne!(version(&candidate).unwrap().0, before);
        let a = evaluate(Fixture::Ground, GROUND_TEST_SEED, Policy::Fixed).unwrap();
        let new_a = evaluate(
            Fixture::Ground,
            GROUND_TEST_SEED,
            Policy::Neural(&candidate),
        )
        .unwrap();
        let new_b = evaluate(Fixture::Arena, ARENA_TEST_SEED, Policy::Neural(&candidate)).unwrap();
        assert!(quality_gate(&a, &b, &new_a, &new_b));
        assert!(!quality_gate(&new_a, &new_b, &a, &b));
    }
}
