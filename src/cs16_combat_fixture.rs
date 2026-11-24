use super::*;

const SCENARIOS: [&str; 6] = [
    "stationary",
    "moving",
    "friendly",
    "occluded",
    "heldout_moving",
    "heldout_occluded",
];

#[derive(Serialize)]
struct EngineTrace {
    scenario_code: u8,
    policy_code: u8,
    action_id: u32,
    generation: u32,
    tick: f64,
    placed: bool,
    target_id: u32,
    target_team: u8,
    weapon: u8,
    deploy_timer_seconds: f64,
    target_displacement: f64,
    reason: String,
    clip_before: i32,
    clip_after: i32,
    attack_command_events: u32,
    primary_attack_events: u32,
    playback_events: u32,
    damage_events: u32,
    target_health_before: i32,
    target_health_after: i32,
    player_timer_before_attack: f64,
    weapon_timer_before_attack: f64,
    accepted_tick: f64,
    target_x: f64,
    target_y: f64,
}

impl EngineTrace {
    fn parse(text: &str) -> Option<Self> {
        if !text.ends_with('\n') {
            return None;
        }
        let mut fields = text.split_whitespace();
        if fields.next()? != "reflexcore_cs16_fixture_v1" {
            return None;
        }
        macro_rules! field {
            () => {
                fields.next()?.parse().ok()?
            };
        }
        let value = Self {
            scenario_code: field!(),
            policy_code: field!(),
            action_id: field!(),
            generation: field!(),
            tick: field!(),
            placed: flag(fields.next()?).ok()?,
            target_id: field!(),
            target_team: field!(),
            weapon: field!(),
            deploy_timer_seconds: field!(),
            target_displacement: field!(),
            reason: fields.next()?.to_owned(),
            clip_before: field!(),
            clip_after: field!(),
            attack_command_events: field!(),
            primary_attack_events: field!(),
            playback_events: field!(),
            damage_events: field!(),
            target_health_before: field!(),
            target_health_after: field!(),
            player_timer_before_attack: field!(),
            weapon_timer_before_attack: field!(),
            accepted_tick: field!(),
            target_x: field!(),
            target_y: field!(),
        };
        if fields.next().is_some()
            || !(1..=6).contains(&value.scenario_code)
            || value.policy_code > 1
            || value.target_team > 2
            || !matches!(
                value.reason.as_str(),
                "waiting"
                    | "identity_changed"
                    | "friendly_target"
                    | "occluded_target"
                    | "wrong_weapon"
                    | "empty_clip"
                    | "clip_decreased"
                    | "weapon_timer_active"
                    | "primary_not_observed"
                    | "primary_without_discharge"
            )
            || ![
                value.tick,
                value.deploy_timer_seconds,
                value.target_displacement,
                value.player_timer_before_attack,
                value.weapon_timer_before_attack,
                value.accepted_tick,
                value.target_x,
                value.target_y,
            ]
            .iter()
            .all(|number| number.is_finite())
        {
            return None;
        }
        Some(value)
    }

    fn read(mail: &Mailbox, state: &State, scenario_code: u8, policy_code: u8) -> Option<Self> {
        let mut data = String::new();
        File::open(mail.dir.join("fixture-state.txt"))
            .ok()?
            .take(500)
            .read_to_string(&mut data)
            .ok()?;
        let observation = Self::parse(&data)?;
        (observation.action_id == state.seq
            && observation.scenario_code == scenario_code
            && observation.policy_code == policy_code
            && (observation.tick - state.tick).abs() <= 0.000002)
            .then_some(observation)
    }
}

#[derive(Serialize)]
struct Report {
    schema: &'static str,
    run_id: String,
    scenario: &'static str,
    policy: &'static str,
    termination: &'static str,
    stage: &'static str,
    actor_spawn: Option<[f64; 3]>,
    reported_target: Option<[f64; 2]>,
    target_team: Option<u8>,
    attack_requests: u32,
    reaction_us: Option<u128>,
    observation_age_ms: Option<f64>,
    final_trace: Option<EngineTrace>,
    cancellation_acknowledged: bool,
    last_submitted_at_cancel: Option<u32>,
    last_submitted_before_cleanup: u32,
    memory_status: &'static str,
    model_calls: u8,
}

fn exercise(
    mail: &Mailbox,
    state: &mut State,
    report: &mut Report,
    scenario: u8,
    policy: u8,
    wait_cancel: bool,
) -> Result<()> {
    if state.map != "de_reflex_lab" || state.id != 0 || state.bots != 0 {
        return Err("The combat fixture requires an empty, fresh owned lab".into());
    }
    *state = mail.command(state, 1, None)?;
    *state = mail.command(
        state,
        0,
        Some(Pulse {
            yaw: 0.0,
            forward: 0,
            buttons: policy,
            msec: scenario,
        }),
    )?;
    let previous_generation = mail
        .round_observation(state.seq)
        .ok_or("Missing round evidence")?
        .generation;
    *state = mail.command(state, 5, None)?;
    let restart_sequence = state.seq;
    let actor = state.id;
    let restarted = mail.wait_for(Duration::from_secs(12), |sample| {
        sample.seq == restart_sequence
            && sample.map == "de_reflex_lab"
            && sample.id == actor
            && sample.alive
            && sample.team == 1
            && mail
                .round_observation(sample.seq)
                .is_some_and(|round| round.generation > previous_generation && round.live)
            && EngineTrace::read(mail, sample, scenario, policy).is_some_and(|trace| trace.placed)
    });
    let generation = match restarted {
        Ok(restarted) => {
            *state = restarted;
            EngineTrace::read(mail, state, scenario, policy)
                .ok_or("Lost initial fixture evidence")?
                .generation
        }
        Err(error) => {
            report.termination = "timeout";
            return Err(error);
        }
    };
    report.actor_spawn = Some(state.pos);
    mail.combat_generation.set(Some(generation));
    *state = mail.command(state, 8, None)?;
    report.stage = "weapon_observation";
    let equipped = state.seq;
    *state = mail
        .wait_for(Duration::from_secs(4), |sample| {
            sample.seq == equipped
                && sample.id == actor
                && sample.alive
                && EngineTrace::read(mail, sample, scenario, policy).is_some_and(|trace| {
                    trace.generation == generation
                        && trace.target_id > 0
                        && trace.weapon == 28
                        && (policy == 0 || trace.deploy_timer_seconds <= 0.020)
                })
        })
        .map_err(|error| {
            report.termination = "timeout";
            error
        })?;
    let ready =
        EngineTrace::read(mail, state, scenario, policy).ok_or("Lost ready fixture observation")?;
    report.reported_target = Some([ready.target_x, ready.target_y]);
    report.target_team = Some(ready.target_team);
    if wait_cancel {
        report.stage = "cancel_barrier";
        let marker = mail
            .cancel_file
            .as_ref()
            .ok_or("Missing cancellation path")?;
        let mut ready = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(marker.with_extension("cancel.ready"))?;
        writeln!(ready, "{}", report.run_id)?;
        drop(ready);
        let started = Instant::now();
        while started.elapsed() < Duration::from_secs(6) {
            if mail.cancel_requested()? {
                report.cancellation_acknowledged = true;
                report.last_submitted_at_cancel = Some(mail.last_submitted.get());
                // Exercise the same dispatch boundary after accepting the stop marker.
                if mail.command(state, 9, None).is_ok()
                    || Some(mail.last_submitted.get()) != report.last_submitted_at_cancel
                {
                    return Err("Attack was submitted after accepted cancellation".into());
                }
                report.termination = "cancelled";
                return Ok(());
            }
            thread::sleep(WAIT);
        }
        report.termination = "timeout";
        return Err("No cancellation marker arrived".into());
    }
    report.stage = "attack_request";
    let action_id = state.seq.checked_add(1).ok_or("Fixture sequence limit")?;
    let started = Instant::now();
    let result = mail.command(state, 9, None);
    if mail.last_submitted.get() == action_id {
        report.attack_requests = 1;
    }
    let acknowledged = result.map_err(|error| {
        report.termination = if mail.cancel_requested().unwrap_or(false) {
            "cancelled"
        } else {
            "lost_evidence"
        };
        error
    })?;
    report.reaction_us = Some(started.elapsed().as_micros());
    let mut verified_trace = None;
    let latest = mail.wait_for(Duration::from_secs(1), |sample| {
        if sample.seq != action_id || sample.id != actor || sample.map != state.map {
            return false;
        }
        verified_trace = EngineTrace::read(mail, sample, scenario, policy).filter(|trace| {
            trace.generation == generation
                && trace.reason != "waiting"
                && trace.target_id == ready.target_id
                && trace.accepted_tick >= ready.tick
        });
        verified_trace.is_some()
    });
    let trace = match latest
        .and_then(|_| verified_trace.ok_or("Lost synchronized attack evidence".into()))
    {
        Ok(trace) => trace,
        Err(error) => {
            report.termination = "lost_evidence";
            return Err(error);
        }
    };
    report.observation_age_ms = Some((trace.accepted_tick - ready.tick) * 1000.0);
    report.final_trace = Some(trace);
    *state = acknowledged;
    report.stage = "verified_engine_trace";
    report.termination = "completed";
    Ok(())
}

pub(crate) fn run(args: &[String]) -> Result<()> {
    let [
        _,
        mailbox,
        name,
        policy,
        consent,
        cancel_flag,
        cancel_file,
        run_flag,
        run_id,
        rest @ ..,
    ] = args
    else {
        return Err("Usage: cs16 combat-fixture <mailbox> <scenario> <baseline|candidate> --allow-offline --cancel-file <path> --run-id <hex> [--wait-for-cancel|--remember]".into());
    };
    if consent != "--allow-offline"
        || cancel_flag != "--cancel-file"
        || run_flag != "--run-id"
        || run_id.len() != 32
        || !run_id
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        || !(rest.is_empty() || rest == ["--wait-for-cancel"] || rest == ["--remember"])
    {
        return Err("An isolated fixture and cancellation file are required".into());
    }
    let index = SCENARIOS
        .iter()
        .position(|value| *value == name)
        .ok_or("Unknown fixture scenario")?;
    let policy_code = match policy.as_str() {
        "baseline" => 0,
        "candidate" => 1,
        _ => return Err("Unknown fixture policy".into()),
    };
    let mail = Mailbox::open(Path::new(mailbox), Some(PathBuf::from(cancel_file)))?;
    let mut report = Report {
        schema: "reflexcore.cs16.combat-fixture.v1",
        run_id: run_id.clone(),
        scenario: SCENARIOS[index],
        policy: if policy_code == 0 {
            "baseline"
        } else {
            "candidate"
        },
        termination: "infrastructure_failure",
        stage: "setup",
        actor_spawn: None,
        reported_target: None,
        target_team: None,
        attack_requests: 0,
        reaction_us: None,
        observation_age_ms: None,
        final_trace: None,
        cancellation_acknowledged: false,
        last_submitted_at_cancel: None,
        last_submitted_before_cleanup: 0,
        memory_status: "not_requested",
        model_calls: 0,
    };
    let first = mail.wait_for(COMMAND_DEADLINE, |_| true)?;
    let mut state = mail.wait_for(COMMAND_DEADLINE, |sample| {
        sample.tick > first.tick && sample.seq == first.seq
    })?;
    let result = exercise(
        &mail,
        &mut state,
        &mut report,
        (index + 1) as u8,
        policy_code,
        rest == ["--wait-for-cancel"],
    );
    if result.is_err() && mail.cancel_requested().unwrap_or(false) {
        report.termination = "cancelled";
    }
    report.last_submitted_before_cleanup = mail.last_submitted.get();
    mail.stop_subject(&state);
    if rest == ["--remember"] {
        report.memory_status = "ineligible";
        if crate::learning::Mode::configured()?.records() {
            if let Some(trace) = &report.final_trace {
                let negative = matches!(
                    (report.scenario, trace.reason.as_str()),
                    ("friendly", "friendly_target")
                        | ("occluded" | "heldout_occluded", "occluded_target")
                ) && trace.attack_command_events == 0
                    && trace.playback_events == 0;
                let positive = !matches!(
                    report.scenario,
                    "friendly" | "occluded" | "heldout_occluded"
                ) && trace.clip_before - trace.clip_after == 1
                    && trace.primary_attack_events == 1
                    && trace.playback_events == 1;
                if negative || positive {
                    let sample = serde_json::json!({"action_id":trace.action_id,"generation":trace.generation,
                        "discharges":trace.playback_events,"damage_events":trace.damage_events,
                        "observation_age_ms":report.observation_age_ms});
                    report.memory_status = match crate::agent::memory::record_combat_fixture(
                        run_id,
                        report.scenario,
                        report.policy,
                        &sample,
                    ) {
                        Ok(()) => "recorded",
                        Err(_) => "write_failed",
                    };
                }
            }
        } else {
            report.memory_status = "off";
        }
    }
    println!("{}", serde_json::to_string_pretty(&report)?);
    result
}
