use crate::{
    cs16_route::{Decision, Navigator, Pose, Route, Site, StopReason},
    Result,
};
use serde::Serialize;
use std::{
    cell::Cell,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::windows::process::CommandExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const MOVE: u8 = 2;
const STOP: u8 = 3;
const PLANT_BUTTON: u8 = 1;
const WAIT: Duration = Duration::from_millis(35);
const COMMAND_DEADLINE: Duration = Duration::from_secs(3);
const PLANT_SETTLE_DEADLINE: Duration = Duration::from_secs(1);
const ATTEMPT_DEADLINE: Duration = Duration::from_secs(120);

#[derive(Clone)]
struct State {
    map: String,
    seq: u32,
    tick: f64,
    id: u32,
    alive: bool,
    team: u8,
    pos: [f64; 3],
    yaw: f64,
    c4: bool,
    zone: bool,
    equipped: bool,
    planted: bool,
    won: bool,
    bots: u8,
    status: String,
}

fn flag(s: &str) -> Result<bool> {
    match s {
        "0" => Ok(false),
        "1" => Ok(true),
        _ => Err("Invalid practice state flag".into()),
    }
}

impl State {
    fn parse(text: &str) -> Result<Self> {
        let fields: Vec<_> = text.split_ascii_whitespace().collect();
        let [schema, map, seq, tick, id, alive, team, x, y, z, yaw, c4, zone, equipped, planted, won, bots, status] =
            fields.as_slice()
        else {
            return Err("Incomplete practice observation".into());
        };
        if *schema != "reflexcore_cs16_practice_v1"
            || map.is_empty()
            || map.len() > 32
            || !map
                .bytes()
                .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == b'_')
        {
            return Err("Invalid practice observation schema or map".into());
        }
        let won = flag(won)?;
        let bots: u8 = bots.parse()?;
        if bots > 1 {
            return Err("Practice supports at most one stationary fixture opponent".into());
        }
        let parsed = Self {
            map: (*map).to_owned(),
            seq: seq.parse()?,
            tick: tick.parse()?,
            id: id.parse()?,
            alive: flag(alive)?,
            team: team.parse()?,
            pos: [x.parse()?, y.parse()?, z.parse()?],
            yaw: yaw.parse()?,
            c4: flag(c4)?,
            zone: flag(zone)?,
            equipped: flag(equipped)?,
            planted: flag(planted)?,
            won,
            bots,
            status: (*status).to_owned(),
        };
        if !parsed.tick.is_finite()
            || parsed.tick < 0.0
            || parsed.team > 3
            || !parsed.pos.iter().all(|p| p.abs() <= 32768.0)
            || !parsed.yaw.is_finite()
            || !matches!(
                parsed.status.as_str(),
                "ready"
                    | "added"
                    | "moved"
                    | "stopped"
                    | "rejected"
                    | "unavailable"
                    | "equipped"
                    | "restarting"
                    | "passive_ct"
                    | "match_ct"
                    | "fired"
            )
        {
            return Err("Invalid practice observation values".into());
        }
        Ok(parsed)
    }

    fn pose(&self, sample_id: u64) -> Pose {
        Pose {
            sample_id,
            x: self.pos[0],
            y: self.pos[1],
            z: self.pos[2],
            yaw_degrees: self.yaw.rem_euclid(360.0),
        }
    }
}

struct RoundObservation {
    sequence: u32,
    generation: u32,
    live: bool,
    tick: f64,
}

impl RoundObservation {
    fn parse(text: &str) -> Result<Self> {
        let mut fields = text.split_ascii_whitespace();
        if fields.next() != Some("reflexcore_cs16_round_v1") {
            return Err("Invalid practice round observation".into());
        }
        let sequence = fields.next().ok_or("Missing round sequence")?.parse()?;
        let generation = fields.next().ok_or("Missing round generation")?.parse()?;
        let live = flag(fields.next().ok_or("Missing round phase")?)?;
        let tick: f64 = fields.next().ok_or("Missing round tick")?.parse()?;
        if !tick.is_finite() || tick < 0.0 || fields.next().is_some() {
            return Err("Unexpected practice round data".into());
        }
        Ok(Self {
            sequence,
            generation,
            live,
            tick,
        })
    }

    fn confirms_restart(&self, previous: u32, tick: f64) -> bool {
        self.live && self.generation > previous && self.tick == tick
    }
}

#[derive(Clone, Copy, Debug, Serialize)]
struct RoundCombat {
    generation: u32,
    tick: f64,
    actor: u32,
    closed: bool,
    weapon: u8,
    clip: i32,
    shots: u32,
    hits: u32,
    preplant_shots: u32,
    defender_shots: u32,
    defender_preplant_shots: u32,
    defender_distance: u32,
    actor_died: bool,
}

struct MatchObservation {
    sequence: u32,
    opponent: u32,
    visible: bool,
    defeated: bool,
    round_live: bool,
    combat: Option<RoundCombat>,
}

impl MatchObservation {
    fn parse(text: &str) -> Result<Self> {
        let mut fields = text.split_ascii_whitespace();
        let is_adversarial = match fields.next() {
            Some("reflexcore_cs16_match_v1") => false,
            Some("reflexcore_cs16_match_v2") => true,
            _ => return Err("Invalid offline match observation".into()),
        };
        let sequence = fields.next().ok_or("Missing match sequence")?.parse()?;
        let opponent = fields.next().ok_or("Missing opponent id")?.parse()?;
        let visible = flag(fields.next().ok_or("Missing opponent visibility")?)?;
        let defeated = flag(fields.next().ok_or("Missing opponent status")?)?;
        let round_live = flag(fields.next().ok_or("Missing round start signal")?)?;
        let pitch: f64 = fields.next().ok_or("Missing pitch")?.parse()?;
        let yaw: f64 = fields.next().ok_or("Missing yaw")?.parse()?;
        macro_rules! next {
            () => {
                fields.next().ok_or("Missing combat observation field")?
            };
        }
        let combat = if is_adversarial {
            let observation = RoundCombat {
                generation: next!().parse()?,
                tick: next!().parse()?,
                actor: next!().parse()?,
                closed: flag(next!())?,
                weapon: next!().parse()?,
                clip: next!().parse()?,
                shots: next!().parse()?,
                hits: next!().parse()?,
                preplant_shots: next!().parse()?,
                defender_shots: next!().parse()?,
                defender_preplant_shots: next!().parse()?,
                defender_distance: next!().parse()?,
                actor_died: flag(next!())?,
            };
            if !observation.tick.is_finite()
                || observation.tick < 0.0
                || !(-1..=255).contains(&observation.clip)
                || observation.weapon > 30
                || observation.preplant_shots > observation.shots
                || observation.defender_preplant_shots > observation.defender_shots
                || (observation.closed && round_live)
            {
                return Err("Invalid combat observation".into());
            }
            Some(observation)
        } else {
            None
        };
        if opponent == 0 || !(pitch.abs() <= 90.0 && yaw.abs() <= 360.0) || fields.next().is_some()
        {
            return Err("Invalid offline match observation fields".into());
        }
        Ok(Self {
            sequence,
            opponent,
            visible,
            defeated,
            round_live,
            combat,
        })
    }
}

struct Lock(PathBuf);
impl Drop for Lock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

struct Mailbox {
    dir: PathBuf,
    cancel_file: Option<PathBuf>,
    last_submitted: Cell<u32>,
    combat_generation: Cell<Option<u32>>,
    _lock: Lock,
}

#[derive(Clone, Copy)]
struct Pulse {
    yaw: f64,
    forward: i16,
    buttons: u8,
    msec: u8,
}

impl Mailbox {
    fn open(dir: &Path, cancel_file: Option<PathBuf>) -> Result<Self> {
        let dir = dir.canonicalize()?;
        if !dir.ends_with(Path::new("addons/amxmodx/data/reflexcore")) {
            return Err("Specify the isolated practice plugin mailbox directory".into());
        }
        let lock = dir.join("controller.lock");
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&lock)?;
        let mailbox = Self {
            dir,
            cancel_file,
            last_submitted: Cell::new(0),
            combat_generation: Cell::new(None),
            _lock: Lock(lock),
        };
        if mailbox.cancel_requested()? {
            return Err("Practice cancellation file already exists".into());
        }
        if mailbox.dir.join("command.txt").exists() {
            return Err(
                "A pending command is present. Start a fresh practice server before retrying"
                    .into(),
            );
        }
        Ok(mailbox)
    }

    fn cancel_requested(&self) -> Result<bool> {
        match &self.cancel_file {
            Some(path) => Ok(path.try_exists()?),
            None => Ok(false),
        }
    }

    fn check_cancel(&self) -> Result<()> {
        if self.cancel_requested()? {
            return Err("Offline practice cancelled".into());
        }
        Ok(())
    }

    fn read(&self) -> Result<State> {
        let mut text = String::new();
        File::open(self.dir.join("state.txt"))?
            .take(513)
            .read_to_string(&mut text)?;
        if text.len() > 512 || !text.ends_with('\n') {
            return Err("Incomplete or oversized practice observation".into());
        }
        State::parse(&text)
    }

    fn round_observation(&self, sequence: u32) -> Option<RoundObservation> {
        let mut text = String::new();
        File::open(self.dir.join("round-state.txt"))
            .ok()?
            .take(100)
            .read_to_string(&mut text)
            .ok()?;
        if !text.ends_with('\n') {
            return None;
        }
        let observed = RoundObservation::parse(&text).ok()?;
        (observed.sequence == sequence).then_some(observed)
    }

    fn match_observation(&self, sequence: u32) -> Option<MatchObservation> {
        let mut text = String::new();
        File::open(self.dir.join("match-state.txt"))
            .ok()?
            .take(256)
            .read_to_string(&mut text)
            .ok()?;
        if !text.ends_with('\n') {
            return None;
        }
        let observed = MatchObservation::parse(&text).ok()?;
        (observed.sequence == sequence).then_some(observed)
    }

    fn wait_for(&self, timeout: Duration, accept: impl FnMut(&State) -> bool) -> Result<State> {
        self.wait_for_state(timeout, accept, true)
    }

    fn wait_for_state(
        &self,
        timeout: Duration,
        mut accept: impl FnMut(&State) -> bool,
        interruptible: bool,
    ) -> Result<State> {
        let started = Instant::now();
        while started.elapsed() < timeout {
            if interruptible {
                self.check_cancel()?;
            }
            if let Ok(state) = self.read() {
                if accept(&state) {
                    return Ok(state);
                }
            }
            thread::sleep(WAIT);
        }
        Err("The local practice server did not deliver a valid live observation".into())
    }

    fn command(&self, before: &State, op: u8, pulse: Option<Pulse>) -> Result<State> {
        if op != STOP {
            self.check_cancel()?;
        }
        let seq = before.seq.checked_add(1).ok_or("Practice sequence limit")?;
        let pulse = pulse.unwrap_or(Pulse {
            yaw: 0.0,
            forward: 0,
            buttons: 0,
            msec: 0,
        });
        let unique = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let temp = self.dir.join(format!("controller-{unique}.tmp"));
        let pending = self.dir.join("command.txt");
        if pending.exists() {
            return Err("Practice command collision".into());
        }
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temp)?;
        let generation = if matches!(op, MOVE | 4 | 8 | 9) {
            self.combat_generation.get()
        } else {
            None
        };
        let suffix = generation
            .map(|value| format!(" {value}"))
            .unwrap_or_default();
        let written = writeln!(
            file,
            "{seq} {op} {:.3} {} 0 {} {}{suffix}",
            pulse.yaw, pulse.forward, pulse.buttons, pulse.msec
        );
        drop(file);
        let moved = written.and_then(|()| fs::rename(&temp, pending));
        if moved.is_err() {
            let _ = fs::remove_file(temp);
        }
        moved?;
        self.last_submitted.set(seq);
        let state = self.wait_for_state(
            COMMAND_DEADLINE,
            |s| s.map == before.map && s.seq >= seq,
            op != STOP,
        )?;
        if state.seq != seq
            || state.tick < before.tick
            || matches!(state.status.as_str(), "rejected" | "unavailable")
        {
            return Err(
                "The isolated practice server rejected the command or lost its session".into(),
            );
        }
        Ok(state)
    }

    fn stop_subject(&self, known: &State) {
        let seq = self.last_submitted.get();
        if seq == 0 {
            return;
        }
        if let Ok(latest) = self.wait_for_state(
            COMMAND_DEADLINE,
            |s| {
                s.map == known.map
                    && s.seq >= seq
                    && s.id != 0
                    && (known.id == 0 || s.id == known.id)
                    && s.tick >= known.tick
            },
            false,
        ) {
            let _ = self.command(&latest, STOP, None);
        }
    }
}

#[derive(Serialize)]
struct Report {
    schema: &'static str,
    map: String,
    engine_subject_id: u32,
    spawn: Option<[f64; 3]>,
    setup_ms: u64,
    navigation_ms: u64,
    plant_ms: u64,
    total_ms: u64,
    move_commands: u32,
    plant_commands: u32,
    stationary_opponent: bool,
    reached_plant_zone: bool,
    route_site: Option<Site>,
    recovery_attempts: u8,
    route_stop: Option<&'static str>,
    verified_plant: bool,
    match_mode: bool,
    verified_bot_defeat: bool,
    verified_round_win: bool,
    match_shots: u32,
    adversarial: bool,
    contacts: u32,
    preplant_contacts: u32,
    actor_died: bool,
    round_completed: bool,
    combat: Option<RoundCombat>,
    #[serde(skip)]
    observation_samples: Vec<u64>,
    #[serde(skip)]
    decision_samples: Vec<u64>,
    observation_us: Latency,
    decision_us: Latency,
    outcome: &'static str,
}

#[derive(Default, Serialize)]
struct Latency {
    samples: usize,
    p50: Option<u64>,
    p95: Option<u64>,
}
impl Latency {
    fn from_samples(samples: &mut [u64]) -> Self {
        samples.sort_unstable();
        let count = samples.len();
        let percentile = |rank| {
            if count == 0 {
                None
            } else {
                Some(samples[(count * rank as usize).div_ceil(100) - 1])
            }
        };
        Self {
            samples: count,
            p50: percentile(50),
            p95: percentile(95),
        }
    }
}

fn millis(start: Instant) -> u64 {
    start.elapsed().as_millis() as u64
}

fn practice_options(mut options: &[String]) -> Result<(bool, bool, Option<PathBuf>)> {
    let mut stationary_opponent = false;
    let mut match_mode = false;
    let mut cancel_file = None;
    while let Some((option, rest)) = options.split_first() {
        options = match option.as_str() {
            "--stationary-opponent" if !stationary_opponent => {
                stationary_opponent = true;
                rest
            }
            "--match" if !match_mode => {
                match_mode = true;
                rest
            }
            "--cancel-file" if cancel_file.is_none() => {
                let (path, remaining) = rest
                    .split_first()
                    .ok_or("Missing practice cancellation path")?;
                if path.starts_with("--") || Path::new(path).file_name().is_none() {
                    return Err("Invalid practice cancellation path".into());
                }
                cancel_file = Some(PathBuf::from(path));
                remaining
            }
            _ => return Err("Invalid practice options".into()),
        };
    }
    if match_mode && stationary_opponent {
        return Err("Select either a match or the stationary opponent fixture".into());
    }
    Ok((stationary_opponent, match_mode, cancel_file))
}

pub(crate) fn run(args: &[String]) -> Result<()> {
    let [verb, mailbox, route, consent, options @ ..] = args else {
        return Err("Usage: cs16 practice <isolated-mailbox> <route.json|auto> --allow-offline [--stationary-opponent|--match] [--cancel-file <file>]".into());
    };
    if verb != "practice" || consent != "--allow-offline" {
        return Err("The isolated CS 1.6 practice runner requires --allow-offline".into());
    }
    let (stationary_opponent, match_mode, cancel_file) = practice_options(options)?;
    let fixed_route = if route == "auto" {
        if !stationary_opponent && !match_mode {
            return Err(
                "Automatic BSP routes require the stationary local opponent fixture".into(),
            );
        }
        None
    } else {
        Some(Route::load(Path::new(route))?)
    };
    let box_ = Mailbox::open(Path::new(mailbox), cancel_file)?;
    let started = Instant::now();
    let first = box_.wait_for(COMMAND_DEADLINE, |_| true)?;
    let mut state = box_.wait_for(COMMAND_DEADLINE, |s| {
        s.map == first.map && s.seq == first.seq && s.tick > first.tick
    })?;
    let adversarial = route == "auto" && match_mode;
    if adversarial && state.map != "de_dust2" {
        return Err("Automatic matches are scoped to the owned Dust II fixture".into());
    }
    if !adversarial && match_mode && state.map != "de_reflex_lab" {
        return Err("Saved match mode requires the original lab map".into());
    }
    let nav = fixed_route
        .map(|route| Navigator::new(route, &state.map))
        .transpose()?;
    let mut report = Report {
        schema: "reflexcore.cs16.practice.result.v1",
        map: state.map.clone(),
        engine_subject_id: 0,
        spawn: None,
        setup_ms: 0,
        navigation_ms: 0,
        plant_ms: 0,
        total_ms: 0,
        move_commands: 0,
        plant_commands: 0,
        stationary_opponent,
        reached_plant_zone: false,
        route_site: None,
        recovery_attempts: 0,
        route_stop: None,
        verified_plant: false,
        match_mode,
        verified_bot_defeat: false,
        verified_round_win: false,
        match_shots: 0,
        adversarial,
        contacts: 0,
        preplant_contacts: 0,
        actor_died: false,
        round_completed: false,
        combat: None,
        observation_samples: Vec::new(),
        decision_samples: Vec::new(),
        observation_us: Latency::default(),
        decision_us: Latency::default(),
        outcome: "setup_failed",
    };
    let mut experience = crate::learning::Mode::configured()
        .ok()
        .filter(|mode| mode.records())
        .map(|_| Vec::with_capacity(512));
    let execution = attempt(
        &box_,
        &mut state,
        nav,
        &mut report,
        started,
        experience.as_mut(),
    );
    if execution.is_err() && box_.cancel_requested().unwrap_or(false) {
        report.outcome = "cancelled";
    }
    box_.stop_subject(&state);
    report.total_ms = millis(started);
    report.observation_us = Latency::from_samples(&mut report.observation_samples);
    report.decision_us = Latency::from_samples(&mut report.decision_samples);
    if let Some(samples) = experience.as_ref().filter(|samples| !samples.is_empty()) {
        if crate::agent::memory::record_motion(
            samples,
            None,
            crate::skill_registry::GOLDSRC_PULSE_ID,
        )
        .is_err()
        {
            eprintln!("Could not retain local motion outcomes");
        }
    }
    println!("{}", serde_json::to_string_pretty(&report)?);
    execution
}

fn automatic_route(
    mail: &Mailbox,
    spawn: &State,
    recovery: Option<(f64, Option<Site>)>,
) -> Result<Navigator> {
    if !spawn.map.starts_with("de_") {
        return Err("Automatic plant drills require a demolition map".into());
    }
    let maps = mail
        .dir
        .ancestors()
        .nth(4)
        .ok_or("Incomplete practice path")?
        .join("maps");
    let maps = fs::canonicalize(maps)?;
    let file = fs::canonicalize(maps.join(format!("{}.bsp", spawn.map)))?;
    if file.parent() != Some(maps.as_path()) {
        return Err("BSP must be in the owned server maps directory".into());
    }
    let planner = Path::new("examples/plan_cs16_bsp_route.py");
    let coordinates = spawn.pos.map(|coord| coord.to_string());
    let mut command = Command::new("py.exe");
    command
        .args(["-3", "-I"])
        .arg(planner)
        .arg(file)
        .args(["--auto", "--start"])
        .args(coordinates);
    if let Some((heading, avoid_site)) = recovery {
        command.args(["--resume", "--spacing", "16"]);
        command.arg(format!("--blocked-heading={heading}"));
        if let Some(site) = avoid_site {
            command.args([
                "--avoid-site",
                match site {
                    Site::A => "A",
                    Site::B => "B",
                },
            ]);
        }
    }
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .creation_flags(0x08000000)
        .spawn()?;
    let pipe = child.stdout.take().ok_or("Missing BSP planner output")?;
    let reader = thread::spawn(move || {
        let mut result = Vec::new();
        pipe.take(65_537).read_to_end(&mut result).map(|_| result)
    });
    let start = Instant::now();
    let result: Result<std::process::ExitStatus> = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Ok(None)
                if start.elapsed() < Duration::from_secs(24) && mail.check_cancel().is_ok() =>
            {
                thread::sleep(WAIT);
            }
            Ok(None) => break Err("BSP planning cancelled or exceeded its deadline".into()),
            Err(error) => break Err(error.into()),
        }
    };
    let status = match result {
        Ok(status) => status,
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error);
        }
    };
    let bytes = reader.join().map_err(|_| "BSP output reader failed")??;
    if !status.success() {
        return Err("No supported standing route from the observed spawn to a bombsite".into());
    }
    // Recheck the subject after planning. The navigator still verifies the spawn anchor.
    let current = mail.read()?;
    if current.map != spawn.map
        || current.id != spawn.id
        || current.seq != spawn.seq
        || !current.alive
        || !current.c4
        || current.planted
    {
        return Err("Practice subject changed during BSP planning".into());
    }
    Ok(Navigator::new(Route::parse(&bytes)?, &spawn.map)?.with_precise_steering())
}

fn attempt(
    mail: &Mailbox,
    state: &mut State,
    nav: Option<Navigator>,
    report: &mut Report,
    started: Instant,
    mut experience: Option<&mut Vec<crate::learning::Experience>>,
) -> Result<()> {
    if state.id == 0 {
        *state = mail.command(state, 1, None)?;
    }
    if report.match_mode {
        // A new match claims one known practice defender. Do not repurpose an
        // arbitrary opponent already running on the server.
        *state = mail.command(state, 7, None)?;
        if state.status != "match_ct" {
            return Err(
                "Start this match on the isolated ReflexCore lab with the current plugin".into(),
            );
        }
        let seq = state.seq;
        *state = mail
            .wait_for(Duration::from_secs(2), |sample| {
                sample.seq == seq
                    && sample.status == "match_ct"
                    && mail.match_observation(seq).is_some_and(|observation| {
                        observation.combat.is_some() == report.adversarial
                    })
            })
            .map_err(|_| "The isolated server did not publish a compatible match observation")?;
    } else if state.bots == 0 && report.stationary_opponent {
        *state = mail.command(state, 6, None)?;
    }
    if state.bots != u8::from(report.stationary_opponent || report.match_mode) {
        return Err("Server does not match the requested opponent fixture".into());
    }
    if nav.is_none() {
        report.outcome = "round_unverified";
    }
    let initial_round = if nav.is_none() {
        Some(
            mail.round_observation(state.seq)
                .ok_or("Install the current practice plugin to verify automatic-route spawns")?
                .generation,
        )
    } else {
        None
    };
    *state = mail.command(state, 5, None)?;
    let reset_at = state.tick;
    let map = state.map.clone();
    let seq = state.seq;
    *state = mail.wait_for(Duration::from_secs(18), |s| {
        s.map == map
            && s.seq == seq
            && s.id > 0
            && s.alive
            && s.team == 1
            && s.c4
            && !s.planted
            && s.tick >= reset_at + 1.5
            && initial_round.is_none_or(|previous| {
                mail.round_observation(s.seq)
                    .is_some_and(|round| round.confirms_restart(previous, s.tick))
            })
            && (!report.match_mode || mail.match_observation(s.seq).is_some_and(|m| m.round_live))
    })?;
    report.engine_subject_id = state.id;
    report.spawn = Some(state.pos);
    let mut engagement = if report.adversarial {
        let (opponent, combat) = fresh_combat(mail, state)?;
        if !opponent.round_live {
            return Err("The adversarial round is not live".into());
        }
        mail.combat_generation.set(Some(combat.generation));
        let engagement = Engagement {
            actor: state.id,
            enemy: opponent.opponent,
            generation: combat.generation,
            in_contact: false,
        };
        *state = mail.command(state, 8, None)?;
        let (_, combat) = fresh_combat(mail, state)?;
        if combat.weapon != 28 || combat.clip <= 0 {
            return Err("The owned actor did not equip a loaded AK-47".into());
        }
        Some(engagement)
    } else {
        None
    };
    report.setup_ms = millis(started);
    let actor = state.id;
    report.outcome = "route_planning_failed";
    let can_replan = nav.is_none();
    let mut nav = match nav {
        Some(route) => route,
        None => automatic_route(mail, state, None)?,
    };
    report.route_site = Some(nav.site());
    let navigation_start = Instant::now();
    report.outcome = "route_failed";
    loop {
        if started.elapsed() > ATTEMPT_DEADLINE {
            return Err("Practice round exceeded the overall deadline".into());
        }
        if let Some(combat) = engagement.as_mut() {
            if combat.refresh(mail, state, report)? {
                return combat.finish(mail, state, report);
            }
            if combat.react(mail, state, report)? {
                continue;
            }
        }
        if started.elapsed() > ATTEMPT_DEADLINE || state.id != actor || !state.alive || !state.c4 {
            return Err("Practice route lost the live C4 carrier or reached the deadline".into());
        }
        let yaw = state.yaw.rem_euclid(360.0);
        let decision = nav.step(state.pose(u64::from(state.seq)));
        // A verified engine zone is authoritative for automatic routes. Still reject
        // stale/discontinuous pose evidence before accepting an early arrival.
        if can_replan
            && state.zone
            && !matches!(decision, Decision::Stopped { reason } if reason != StopReason::Stalled)
        {
            break;
        }
        let pulse = match decision {
            Decision::Arrived { .. } => break,
            Decision::Stopped {
                reason: StopReason::Stalled,
            } if can_replan && report.recovery_attempts < 2 && nav.blocked_heading().is_some() => {
                let heading = nav.blocked_heading().ok_or("Missing stalled heading")?;
                let avoid_site = (report.recovery_attempts > 0).then(|| nav.site());
                report.route_stop = Some("stalled");
                report.recovery_attempts += 1;
                report.outcome = "route_recovery_failed";
                nav = automatic_route(mail, state, Some((heading, avoid_site)))?;
                report.route_site = Some(nav.site());
                report.route_stop = None;
                report.outcome = "route_failed";
                continue;
            }
            Decision::Stopped { reason } => {
                report.route_stop = Some(reason.code());
                return Err(format!("Practice route stopped: {reason:?}").into());
            }
            Decision::Turn { delta_degrees } => Pulse {
                yaw: (yaw + delta_degrees + 180.0).rem_euclid(360.0) - 180.0,
                forward: 0,
                buttons: 0,
                msec: 45,
            },
            Decision::Advance { millis } => Pulse {
                yaw: (yaw + 180.0).rem_euclid(360.0) - 180.0,
                forward: if can_replan && millis < 95 { 150 } else { 240 },
                buttons: 0,
                msec: millis.min(100) as u8,
            },
        };
        let sent = Instant::now();
        let after = mail.command(state, MOVE, Some(pulse))?;
        if let Some(samples) = experience
            .as_deref_mut()
            .filter(|samples| samples.len() < 1024)
        {
            if pulse.forward > 0 && after.id == actor && after.alive && after.tick > state.tick {
                samples.push(motion_sample(state, &after, pulse.msec, millis(sent)));
            }
        }
        *state = after;
        report.move_commands += 1;
        report.navigation_ms = millis(navigation_start);
    }
    report.navigation_ms = millis(navigation_start);
    report.outcome = "plant_zone_unverified";
    let seq = state.seq;
    *state = mail
        .wait_for(Duration::from_secs(2), |s| {
            s.map == map && s.seq == seq && s.id == actor && s.alive && s.c4 && s.zone
        })
        .map_err(|_| "The engine did not confirm a plant zone at the final waypoint")?;
    report.reached_plant_zone = true;
    let plant_start = Instant::now();
    report.outcome = "c4_equip_failed";
    *state = mail.command(state, 4, None)?;
    let seq = state.seq;
    *state = mail.wait_for(COMMAND_DEADLINE, |s| {
        s.map == map && s.seq == seq && s.id == actor && s.alive && s.zone && s.c4 && s.equipped
    })?;
    report.outcome = "plant_event_missing";
    while plant_start.elapsed() < Duration::from_secs(12) && started.elapsed() < ATTEMPT_DEADLINE {
        if let Some(combat) = engagement.as_mut() {
            if combat.refresh(mail, state, report)? {
                return combat.finish(mail, state, report);
            }
            if state.planted {
                break;
            }
            if combat.react(mail, state, report)? {
                continue;
            }
            if state.c4 && !state.equipped {
                *state = mail.command(state, 4, None)?;
                continue;
            }
        }
        if state.id != actor || !state.alive || state.team != 1 || state.planted {
            break;
        }
        if !state.zone || !state.c4 || !state.equipped {
            if !state.c4 && report.plant_commands > 0 {
                // The game can remove C4 before the server's plant callback runs.
                let seq = state.seq;
                let remaining = ATTEMPT_DEADLINE.saturating_sub(started.elapsed());
                if let Ok(confirmed) = mail.wait_for(PLANT_SETTLE_DEADLINE.min(remaining), |s| {
                    s.map == map && s.seq == seq && s.id == actor && s.planted
                }) {
                    *state = confirmed;
                }
            }
            break;
        }
        *state = mail.command(
            state,
            MOVE,
            Some(Pulse {
                yaw: (state.yaw + 180.0).rem_euclid(360.0) - 180.0,
                forward: 0,
                buttons: PLANT_BUTTON,
                msec: 100,
            }),
        )?;
        report.plant_commands += 1;
    }
    report.plant_ms = millis(plant_start);
    if state.map == map && state.id == actor && state.planted {
        report.verified_plant = true;
        if let Some(combat) = engagement.as_mut() {
            return combat.finish(mail, state, report);
        }
        if report.match_mode {
            finish_match(mail, state, report)?;
        }
        report.outcome = "verified";
        return Ok(());
    }
    Err("No actor-scoped C4 plant event was observed in the local game".into())
}

fn motion_sample(
    before: &State,
    after: &State,
    command_ms: u8,
    ack_ms: u64,
) -> crate::learning::Experience {
    let dx = after.pos[0] - before.pos[0];
    let dy = after.pos[1] - before.pos[1];
    let measured = dx.hypot(dy);
    let displacement = measured.min(64.0) as f32;
    let verified = (0.75..=64.0).contains(&measured);
    crate::learning::Experience {
        environment: "cs16_offline_v1",
        features: [
            f32::from(command_ms),
            ((after.tick - before.tick) * 1000.0).min(3000.0) as f32,
            ack_ms.min(3000) as f32,
        ],
        action: usize::from(command_ms),
        expected_effect: 0.75,
        actual_effect: displacement,
        verified,
        reward: if verified { 1.0 } else { -1.0 },
    }
}

fn fresh_combat(mail: &Mailbox, state: &mut State) -> Result<(MatchObservation, RoundCombat)> {
    let mut complete = None;
    let expected = (state.id, state.map.clone(), state.seq, state.tick);
    *state = mail.wait_for_state(
        COMMAND_DEADLINE,
        |observed| {
            if observed.id != expected.0
                || observed.map != expected.1
                || observed.seq != expected.2
                || observed.tick < expected.3
            {
                return false;
            }
            let Some(sample) = mail.match_observation(observed.seq) else {
                return false;
            };
            let Some(combat) = sample.combat else {
                return false;
            };
            if combat.actor != observed.id || combat.tick != observed.tick {
                return false;
            }
            complete = Some((sample, combat));
            true
        },
        true,
    )?;
    complete.ok_or_else(|| "Missing synchronized combat state".into())
}

struct Engagement {
    actor: u32,
    enemy: u32,
    generation: u32,
    in_contact: bool,
}

impl Engagement {
    fn observe(
        &self,
        mail: &Mailbox,
        state: &mut State,
        report: &mut Report,
    ) -> Result<MatchObservation> {
        let started = Instant::now();
        let (sample, combat) = fresh_combat(mail, state)?;
        if report.observation_samples.len() < 4096 {
            report
                .observation_samples
                .push(started.elapsed().as_micros() as u64);
        }
        if combat.generation != self.generation
            || combat.actor != self.actor
            || sample.opponent != self.enemy
        {
            return Err("The adversarial round or owned actors changed".into());
        }
        report.combat = Some(combat);
        report.actor_died |= combat.actor_died;
        report.verified_plant |= state.planted;
        report.verified_bot_defeat |= sample.defeated;
        report.round_completed = combat.closed;
        report.verified_round_win = combat.closed && state.won;
        Ok(sample)
    }

    fn refresh(&self, mail: &Mailbox, state: &mut State, report: &mut Report) -> Result<bool> {
        let sample = self.observe(mail, state, report)?;
        Ok(report.round_completed || !state.alive || state.won || !sample.round_live)
    }

    fn react(&mut self, mail: &Mailbox, state: &mut State, report: &mut Report) -> Result<bool> {
        let sample = self.observe(mail, state, report)?;
        let decision_start = Instant::now();
        let action = self.choose_action(state, report, &sample);
        if report.decision_samples.len() < 4096 {
            report
                .decision_samples
                .push(decision_start.elapsed().as_micros() as u64);
        }
        if let Some(operation) = action? {
            *state = mail.command(state, operation, None)?;
            if operation == 9 {
                report.match_shots += 1;
            }
            return Ok(true);
        }
        Ok(!sample.round_live || report.round_completed || !state.alive || state.won)
    }

    fn choose_action(
        &mut self,
        state: &State,
        report: &mut Report,
        sample: &MatchObservation,
    ) -> Result<Option<u8>> {
        if !sample.round_live || report.round_completed || !state.alive || state.won {
            return Ok(None);
        }
        if sample.visible && !sample.defeated {
            if !self.in_contact {
                report.contacts += 1;
                if !state.planted {
                    report.preplant_contacts += 1;
                }
            }
            self.in_contact = true;
            let combat = report.combat.ok_or("Missing combat state")?;
            if report.match_shots >= 100 {
                return Ok(None);
            }
            if combat.weapon != 28 {
                return Ok(Some(8));
            }
            if combat.clip > 0 {
                return Ok(Some(9));
            }
        } else {
            self.in_contact = false;
        }
        Ok(None)
    }

    fn finish(&mut self, mail: &Mailbox, state: &mut State, report: &mut Report) -> Result<()> {
        let started = Instant::now();
        report.outcome = "round_end_unverified";
        while started.elapsed() < Duration::from_secs(45) {
            if self.refresh(mail, state, report)? && report.round_completed {
                report.outcome = "round_completed";
                return Ok(());
            }
            if !self.react(mail, state, report)? || !state.alive || state.won {
                thread::sleep(WAIT);
            }
        }
        Err("The owned round did not close before the deadline".into())
    }
}

fn finish_match(mail: &Mailbox, state: &mut State, report: &mut Report) -> Result<()> {
    let actor = state.id;
    let original = mail
        .match_observation(state.seq)
        .ok_or("No owned practice opponent")?
        .opponent;
    report.outcome = "combat_equip_failed";
    *state = mail.command(state, 8, None)?;
    let started = Instant::now();
    report.outcome = "bot_defeat_unverified";
    while started.elapsed() < Duration::from_secs(28) && report.match_shots < 20 {
        mail.check_cancel()?;
        let state_now = mail.read();
        let Ok(observed) = state_now else {
            thread::sleep(WAIT);
            continue;
        };
        if observed.id != actor
            || !observed.alive
            || observed.team != 1
            || observed.map != state.map
        {
            return Err("The offline match lost its live terrorist".into());
        }
        let Some(opponent) = mail.match_observation(observed.seq) else {
            thread::sleep(WAIT);
            continue;
        };
        if opponent.opponent != original {
            return Err("The isolated defender changed during the match".into());
        }
        *state = observed;
        if opponent.defeated {
            report.verified_bot_defeat = true;
            break;
        }
        if opponent.visible {
            *state = mail.command(state, 9, None)?;
            report.match_shots += 1;
        } else {
            thread::sleep(WAIT);
        }
    }
    if !report.verified_bot_defeat {
        return Err("No actor-scoped Glock kill of the practice defender was observed".into());
    }
    report.outcome = "round_win_unverified";
    let map = state.map.clone();
    *state = mail.wait_for(Duration::from_secs(42), |s| {
        s.id == actor && s.map == map && s.won && s.planted
    })?;
    report.verified_round_win = true;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn combat_observation_distinguishes_requests_and_engine_evidence() {
        let row = "reflexcore_cs16_match_v2 9 2 1 0 1 0 0 3 10.125 1 0 28 27 3 1 2 4 2 150 0";
        let sample = MatchObservation::parse(row).unwrap();
        let evidence = sample.combat.unwrap();
        assert_eq!(
            (sample.sequence, sample.opponent, evidence.generation),
            (9, 2, 3)
        );
        assert_eq!(
            (evidence.shots, evidence.hits, evidence.preplant_shots),
            (3, 1, 2)
        );
        assert!(MatchObservation::parse(&row.replace("3 1 2 4 2 150", "3 1 4 4 2 150")).is_err());
        assert!(MatchObservation::parse(row.trim_end_matches('0')).is_err());
    }

    #[test]
    fn motion_evidence_records_displacement_and_latency_without_positions() {
        let mut before = State::parse(
            "reflexcore_cs16_practice_v1 de_fixture 3 10 7 1 1 10 -2 36 -90 1 1 1 0 0 0 moved",
        )
        .unwrap();
        let mut after = before.clone();
        after.tick = 10.1;
        let stall = motion_sample(&before, &after, 80, 91);
        assert!(!stall.verified);
        before.pos = [1024.0, 2048.0, 36.0];
        after.pos = [1028.0, 2051.0, 36.0];
        let moved = motion_sample(&before, &after, 80, 91);
        assert!(moved.verified);
        assert_eq!(moved.actual_effect, 5.0);
        after.pos[0] += 1024.0;
        assert!(!motion_sample(&before, &after, 80, 91).verified);
        let json = serde_json::to_value(moved).unwrap();
        assert_eq!(json["features"], serde_json::json!([80.0, 100.0, 91.0]));
        assert!(json.get("position").is_none());
        assert!(json.get("map").is_none());
    }

    #[test]
    fn accepts_owned_cancel_marker_in_either_option_order() {
        for options in [
            [
                "--stationary-opponent",
                "--cancel-file",
                "private-run.cancel",
            ],
            [
                "--cancel-file",
                "private-run.cancel",
                "--stationary-opponent",
            ],
        ] {
            let args = options.map(str::to_owned);
            assert_eq!(
                practice_options(&args).unwrap(),
                (true, false, Some(PathBuf::from("private-run.cancel")))
            );
        }
        let missing = ["--cancel-file", "--stationary-opponent"].map(str::to_owned);
        assert!(practice_options(&missing).is_err());
    }

    #[test]
    fn fresh_round_requires_a_new_generation_and_live_phase() {
        let old = RoundObservation::parse("reflexcore_cs16_round_v1 4 2 1 5.0\n").unwrap();
        assert_eq!(old.sequence, 4);
        assert!(!old.confirms_restart(2, 5.0));
        let pending = RoundObservation::parse("reflexcore_cs16_round_v1 4 3 0 5.0\n").unwrap();
        assert!(!pending.confirms_restart(2, 5.0));
        assert!(
            RoundObservation::parse("reflexcore_cs16_round_v1 4 3 1 5.0\n")
                .unwrap()
                .confirms_restart(2, 5.0)
        );
        assert!(
            !RoundObservation::parse("reflexcore_cs16_round_v1 4 3 1 5.0\n")
                .unwrap()
                .confirms_restart(2, 4.0)
        );
        assert!(RoundObservation::parse("reflexcore_cs16_round_v1 4 3 1 extra\n").is_err());
    }

    #[test]
    fn typed_state_accepts_only_uncontested_game() {
        let valid = "reflexcore_cs16_practice_v1 de_fixture 3 10.02 7 1 1 0.0 -2.0 36.0 -90.0 1 1 1 0 0 0 moved\n";
        let state = State::parse(valid).unwrap();
        assert_eq!(state.id, 7);
        assert_eq!(state.pose(8).yaw_degrees, 270.0);
        assert!(state.equipped && !state.planted);
        assert!(State::parse(&valid.replace("0 0 0 moved", "0 0 2 moved")).is_err());
        assert!(State::parse(&valid.replace("10.02", "NaN")).is_err());
        assert!(State::parse(&valid.replace("de_fixture", "../public")).is_err());
    }
}
