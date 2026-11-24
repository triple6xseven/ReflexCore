use crate::{
    cs16_route::{Decision, Navigator, Pose, Route},
    Result,
};
use serde::Serialize;
use std::{
    cell::Cell,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
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
        flag(won)?;
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

    fn wait_for(&self, timeout: Duration, accept: impl Fn(&State) -> bool) -> Result<State> {
        self.wait_for_state(timeout, accept, true)
    }

    fn wait_for_state(
        &self,
        timeout: Duration,
        accept: impl Fn(&State) -> bool,
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
        let written = writeln!(
            file,
            "{seq} {op} {:.3} {} 0 {} {}",
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
    setup_ms: u64,
    navigation_ms: u64,
    plant_ms: u64,
    total_ms: u64,
    move_commands: u32,
    plant_commands: u32,
    stationary_opponent: bool,
    verified_plant: bool,
    outcome: &'static str,
}

fn millis(start: Instant) -> u64 {
    start.elapsed().as_millis() as u64
}

fn practice_options(mut options: &[String]) -> Result<(bool, Option<PathBuf>)> {
    let mut stationary_opponent = false;
    let mut cancel_file = None;
    while let Some((option, rest)) = options.split_first() {
        options = match option.as_str() {
            "--stationary-opponent" if !stationary_opponent => {
                stationary_opponent = true;
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
    Ok((stationary_opponent, cancel_file))
}

pub(crate) fn run(args: &[String]) -> Result<()> {
    let [verb, mailbox, route, consent, options @ ..] = args else {
        return Err("Usage: cs16 practice <isolated-mailbox> <route.json> --allow-offline [--stationary-opponent] [--cancel-file <file>]".into());
    };
    if verb != "practice" || consent != "--allow-offline" {
        return Err("The isolated CS 1.6 practice runner requires --allow-offline".into());
    }
    let (stationary_opponent, cancel_file) = practice_options(options)?;
    let route = Route::load(Path::new(route))?;
    let box_ = Mailbox::open(Path::new(mailbox), cancel_file)?;
    let started = Instant::now();
    let first = box_.wait_for(COMMAND_DEADLINE, |_| true)?;
    let mut state = box_.wait_for(COMMAND_DEADLINE, |s| {
        s.map == first.map && s.seq == first.seq && s.tick > first.tick
    })?;
    let mut nav = Navigator::new(route, &state.map)?;
    let mut report = Report {
        schema: "reflexcore.cs16.practice.result.v1",
        map: state.map.clone(),
        engine_subject_id: 0,
        setup_ms: 0,
        navigation_ms: 0,
        plant_ms: 0,
        total_ms: 0,
        move_commands: 0,
        plant_commands: 0,
        stationary_opponent,
        verified_plant: false,
        outcome: "setup_failed",
    };
    let execution = attempt(&box_, &mut state, &mut nav, &mut report, started);
    if execution.is_err() && box_.cancel_requested().unwrap_or(false) {
        report.outcome = "cancelled";
    }
    box_.stop_subject(&state);
    report.total_ms = millis(started);
    println!("{}", serde_json::to_string_pretty(&report)?);
    execution
}

fn attempt(
    mail: &Mailbox,
    state: &mut State,
    nav: &mut Navigator,
    report: &mut Report,
    started: Instant,
) -> Result<()> {
    if state.id == 0 {
        *state = mail.command(state, 1, None)?;
    }
    if state.bots == 0 && report.stationary_opponent {
        *state = mail.command(state, 6, None)?;
    }
    if state.bots != u8::from(report.stationary_opponent) {
        return Err("Server does not match the requested opponent fixture".into());
    }
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
    })?;
    report.engine_subject_id = state.id;
    report.setup_ms = millis(started);
    let actor = state.id;
    let navigation_start = Instant::now();
    report.outcome = "route_failed";
    loop {
        if started.elapsed() > ATTEMPT_DEADLINE || state.id != actor || !state.alive || !state.c4 {
            return Err("Practice route lost the live C4 carrier or reached the deadline".into());
        }
        let yaw = state.yaw.rem_euclid(360.0);
        let pulse = match nav.step(state.pose(u64::from(state.seq))) {
            Decision::Arrived { .. } => break,
            Decision::Stopped { reason } => {
                return Err(format!("Practice route stopped: {reason:?}").into())
            }
            Decision::Turn { delta_degrees } => Pulse {
                yaw: (yaw + delta_degrees + 180.0).rem_euclid(360.0) - 180.0,
                forward: 0,
                buttons: 0,
                msec: 45,
            },
            Decision::Advance { millis } => Pulse {
                yaw: (yaw + 180.0).rem_euclid(360.0) - 180.0,
                forward: 240,
                buttons: 0,
                msec: millis.min(100) as u8,
            },
        };
        *state = mail.command(state, MOVE, Some(pulse))?;
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
    let plant_start = Instant::now();
    report.outcome = "c4_equip_failed";
    *state = mail.command(state, 4, None)?;
    let seq = state.seq;
    *state = mail.wait_for(COMMAND_DEADLINE, |s| {
        s.map == map && s.seq == seq && s.id == actor && s.alive && s.zone && s.c4 && s.equipped
    })?;
    report.outcome = "plant_event_missing";
    while plant_start.elapsed() < Duration::from_secs(12) && started.elapsed() < ATTEMPT_DEADLINE {
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
        report.outcome = "verified";
        return Ok(());
    }
    Err("No actor-scoped C4 plant event was observed in the local game".into())
}

#[cfg(test)]
mod tests {
    use super::*;

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
                (true, Some(PathBuf::from("private-run.cancel")))
            );
        }
        let missing = ["--cancel-file", "--stationary-opponent"].map(str::to_owned);
        assert!(practice_options(&missing).is_err());
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
