//! Read-only benchmark over the private GoldSrc game server log.
use crate::Result;
use serde::Serialize;
use std::{fs::File, io::Read, path::Path};

const MAX_LOG_BYTES: u64 = 8 * 1024 * 1024;
const MAX_ROUNDS: usize = 512;
const FREEZE_LIMIT_SECONDS: i64 = 60;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Team {
    Terrorist,
    CounterTerrorist,
    Other,
}

struct Actor {
    id: u32,
    bot: bool,
    team: Team,
}

fn actor(input: &str) -> Option<(Actor, &str)> {
    let (identity, rest) = input.strip_prefix('"')?.split_once('"')?;
    let mut fields = identity.strip_suffix('>')?.rsplitn(4, '<');
    let team = match fields.next()? {
        "TERRORIST" => Team::Terrorist,
        "CT" => Team::CounterTerrorist,
        _ => Team::Other,
    };
    let auth = fields.next()?.strip_suffix('>')?;
    let id = fields.next()?.strip_suffix('>')?.parse().ok()?;
    if fields.next()?.is_empty() {
        return None;
    }
    Some((
        Actor {
            id,
            bot: auth == "BOT",
            team,
        },
        rest,
    ))
}

#[derive(Clone, Copy)]
enum Event {
    RoundStart,
    RoundEnd,
    CaptureBoundary,
    Reset,
    Difficulty(u8),
    C4 { owned: bool, spawned: bool },
    Drop,
    Plant,
    Death,
    BotKill,
    TerroristWin,
    CounterTerroristWin,
}

fn is_trigger(input: &str, expected: &str) -> bool {
    input
        .strip_prefix(" triggered \"")
        .and_then(|value| value.split_once('"'))
        .is_some_and(|(verb, _)| verb == expected)
}

fn game_event(line: &str, player: u32) -> Option<Event> {
    match line {
        "World triggered \"Round_Start\"" => return Some(Event::RoundStart),
        "World triggered \"Round_End\"" => return Some(Event::RoundEnd),
        "World triggered \"Game_Commencing\"" => return Some(Event::Reset),
        "Log file closed" => return Some(Event::CaptureBoundary),
        _ => {}
    }
    if line.starts_with("Loading map \"")
        || line.starts_with("Started map \"")
        || line.starts_with("World triggered \"Restart_Round_(")
    {
        return Some(Event::Reset);
    }
    if line.starts_with("Log file started ") {
        return Some(Event::CaptureBoundary);
    }
    if let Some(value) = line.strip_prefix("Server cvar \"bot_difficulty\" = \"") {
        let value = value.strip_suffix('"')?.parse().ok()?;
        return (value <= 3).then_some(Event::Difficulty(value));
    }
    if let Some(rest) = line.strip_prefix("Team \"TERRORIST\"") {
        for outcome in ["Terrorists_Win", "Target_Bombed"] {
            if is_trigger(rest, outcome) {
                return Some(Event::TerroristWin);
            }
        }
    }
    if let Some(rest) = line.strip_prefix("Team \"CT\"") {
        for outcome in ["CTs_Win", "Target_Saved", "Bomb_Defused"] {
            if is_trigger(rest, outcome) {
                return Some(Event::CounterTerroristWin);
            }
        }
    }
    let (source, rest) = actor(line)?;
    let selected = source.id == player;
    if source.team == Team::Terrorist {
        if is_trigger(rest, "Spawned_With_The_Bomb") {
            return Some(Event::C4 {
                owned: selected,
                spawned: true,
            });
        }
        if is_trigger(rest, "Got_The_Bomb") {
            return Some(Event::C4 {
                owned: selected,
                spawned: false,
            });
        }
        if selected && is_trigger(rest, "Dropped_The_Bomb") {
            return Some(Event::Drop);
        }
        if selected && is_trigger(rest, "Planted_The_Bomb") {
            return Some(Event::Plant);
        }
    }
    let (victim, weapon) = actor(rest.strip_prefix(" killed ")?)?;
    if !weapon.starts_with(" with \"") {
        return None;
    }
    if victim.id == player && victim.team == Team::Terrorist {
        return Some(Event::Death);
    }
    if selected
        && source.team == Team::Terrorist
        && victim.bot
        && victim.team == Team::CounterTerrorist
    {
        return Some(Event::BotKill);
    }
    None
}

fn decimal(value: &str) -> Option<i64> {
    (!value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()))
        .then(|| value.parse().ok())
        .flatten()
}

// The game logs local civil time in whole seconds. Durations avoid converting through the host timezone.
fn log_line(line: &str) -> Option<(i64, &str)> {
    let line = line.strip_prefix("L ")?;
    let (date, rest) = line.split_once(" - ")?;
    let (clock, message) = rest.split_once(": ")?;
    let mut date = date.split('/');
    let month = decimal(date.next()?)?;
    let day = decimal(date.next()?)?;
    let year = decimal(date.next()?)?;
    let mut clock = clock.split(':');
    let hour = decimal(clock.next()?)?;
    let minute = decimal(clock.next()?)?;
    let second = decimal(clock.next()?)?;
    if date.next().is_some()
        || clock.next().is_some()
        || !(1970..=9999).contains(&year)
        || !(1..=12).contains(&month)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let lengths = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let month_index = (month - 1) as usize;
    if !(1..=lengths[month_index]).contains(&day) {
        return None;
    }
    let prior = year - 1;
    let days = 365 * prior + prior / 4 - prior / 100
        + prior / 400
        + lengths[..month_index].iter().sum::<i64>()
        + day
        - 1;
    Some((days * 86400 + hour * 3600 + minute * 60 + second, message))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum Close {
    RoundEnd,
    CaptureEnd,
    RestartOrMapChange,
    MissingRoundEnd,
    ClockDiscontinuity,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum Outcome {
    Planted,
    PlayerDied,
    NoPlant,
    NoPlayerC4Evidence,
    IncompleteEvidence,
}

#[derive(Clone, Copy)]
struct C4 {
    at: i64,
    spawned: bool,
}

struct ActiveRound {
    start: i64,
    acquired: Option<C4>,
    holds_c4: bool,
    plant: Option<i64>,
    death: Option<i64>,
    bot_kill: Option<i64>,
    terrorist_win: Option<bool>,
    difficulty: Option<u8>,
}

impl ActiveRound {
    fn new(start: i64, acquired: Option<C4>, difficulty: Option<u8>) -> Self {
        Self {
            start,
            acquired,
            holds_c4: acquired.is_some(),
            plant: None,
            death: None,
            bot_kill: None,
            terrorist_win: None,
            difficulty,
        }
    }

    fn apply(&mut self, at: i64, event: Event) {
        match event {
            Event::C4 { owned, spawned } if self.plant.is_none() => {
                self.holds_c4 = owned && self.death.is_none();
                if self.holds_c4 {
                    self.acquired.get_or_insert(C4 { at, spawned });
                }
            }
            Event::Drop => self.holds_c4 = false,
            Event::Plant
                if self.holds_c4 && self.death.is_none() && self.terrorist_win.is_none() =>
            {
                self.plant.get_or_insert(at);
                self.holds_c4 = false;
            }
            Event::Death if self.terrorist_win.is_none() => {
                self.death.get_or_insert(at);
                self.holds_c4 = false;
            }
            Event::BotKill if self.death.is_none() && self.terrorist_win.is_none() => {
                self.bot_kill.get_or_insert(at);
            }
            Event::TerroristWin => {
                self.terrorist_win.get_or_insert(true);
            }
            Event::CounterTerroristWin => {
                self.terrorist_win.get_or_insert(false);
            }
            Event::Difficulty(difficulty) if self.difficulty != Some(difficulty) => {
                self.difficulty = None;
            }
            _ => {}
        }
    }

    fn summarize(self, number: usize, at: i64, close: Close) -> RoundReport {
        let valid = matches!(close, Close::RoundEnd | Close::CaptureEnd);
        let outcome = if !valid {
            Outcome::IncompleteEvidence
        } else if self.plant.is_some() {
            Outcome::Planted
        } else if self.acquired.is_none() {
            Outcome::NoPlayerC4Evidence
        } else if self.death.is_some() {
            Outcome::PlayerDied
        } else if close == Close::RoundEnd {
            Outcome::NoPlant
        } else {
            Outcome::IncompleteEvidence
        };
        let offset = |time: Option<i64>| time.map(|t| t - self.start);
        RoundReport {
            round: number,
            close,
            outcome,
            c4_acquired_from_round_start_seconds: offset(self.acquired.map(|item| item.at)),
            spawned_with_c4: self.acquired.is_some_and(|item| item.spawned),
            round_start_to_plant_seconds: offset(self.plant),
            spawn_to_plant_seconds: self
                .acquired
                .filter(|item| item.spawned)
                .and_then(|spawn| self.plant.map(|plant| plant - spawn.at)),
            player_death_from_round_start_seconds: offset(self.death),
            ct_bot_kill_from_round_start_seconds: offset(self.bot_kill),
            terrorist_win: if close == Close::RoundEnd {
                self.terrorist_win
            } else {
                None
            },
            bot_difficulty: self.difficulty,
            round_elapsed_seconds: (at - self.start).max(0),
        }
    }
}

#[derive(Serialize)]
struct RoundReport {
    round: usize,
    close: Close,
    outcome: Outcome,
    c4_acquired_from_round_start_seconds: Option<i64>,
    spawned_with_c4: bool,
    round_start_to_plant_seconds: Option<i64>,
    spawn_to_plant_seconds: Option<i64>,
    player_death_from_round_start_seconds: Option<i64>,
    ct_bot_kill_from_round_start_seconds: Option<i64>,
    terrorist_win: Option<bool>,
    bot_difficulty: Option<u8>,
    round_elapsed_seconds: i64,
}

#[derive(Serialize)]
struct Timing {
    samples: usize,
    p50_seconds: i64,
    p95_seconds: i64,
}

fn timing(mut samples: Vec<i64>) -> Option<Timing> {
    if samples.is_empty() {
        return None;
    }
    samples.sort_unstable();
    let percentile = |p: usize| samples[(samples.len() * p).div_ceil(100_usize) - 1];
    Some(Timing {
        samples: samples.len(),
        p50_seconds: percentile(50),
        p95_seconds: percentile(95),
    })
}

#[derive(Serialize)]
struct Report {
    schema: &'static str,
    evidence: &'static str,
    timestamp_precision_seconds: u8,
    rounds_observed: usize,
    player_c4_rounds: usize,
    verified_plants: usize,
    verified_spawn_to_plant: usize,
    verified_easy_bot_round_wins: usize,
    verified_plant_bot_round_wins: usize,
    verified_completed_actor_rounds: usize,
    verified_completed_actor_wins: usize,
    round_start_to_plant: Option<Timing>,
    spawn_to_plant: Option<Timing>,
    rounds: Vec<RoundReport>,
}

fn close_round(
    rounds: &mut Vec<RoundReport>,
    active: &mut Option<ActiveRound>,
    at: i64,
    close: Close,
) -> Result<()> {
    if let Some(round) = active.take() {
        if rounds.len() == MAX_ROUNDS {
            return Err("Benchmark log has too many rounds".into());
        }
        rounds.push(round.summarize(rounds.len() + 1, at, close));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const PLAYER: &str = r#""Runner<12><STEAM_ID_LAN><TERRORIST>""#;
    const BOT: &str = r#""Opponent<6><BOT><CT>""#;
    const OTHER_T: &str = r#""Someone Else<13><STEAM_ID_LAN><TERRORIST>""#;
    const START: &str = r#"World triggered "Round_Start""#;
    const END: &str = r#"World triggered "Round_End""#;

    fn event(actor: &str, trigger: &str) -> String {
        format!(r#"{actor} triggered "{trigger}""#)
    }

    fn fixture(events: &[(u32, &str)]) -> Report {
        let log = events
            .iter()
            .map(|(second, event)| format!("L 12/21/2025 - 10:01:{second:02}: {event}\n"))
            .collect::<String>();
        analyze(&log, 12).unwrap()
    }

    #[test]
    fn scores_real_event_shape_and_preserves_private_identities() {
        let spawn = event(PLAYER, "Spawned_With_The_Bomb");
        let plant = event(PLAYER, "Planted_The_Bomb");
        let kill = format!(r#"{PLAYER} killed {BOT} with "glock""#);
        let report = fixture(&[
            (1, r#"Server cvar "bot_difficulty" = "0""#),
            (3, &spawn),
            (5, START),
            (30, &plant),
            (36, &kill),
            (
                36,
                r#"Team "TERRORIST" triggered "Terrorists_Win" (CT "0") (T "1")"#,
            ),
            (36, END),
        ]);
        assert_eq!(report.verified_plants, 1);
        assert_eq!(report.verified_spawn_to_plant, 1);
        assert_eq!(report.verified_easy_bot_round_wins, 1);
        assert_eq!(report.verified_plant_bot_round_wins, 1);
        let round = &report.rounds[0];
        assert_eq!(round.round_start_to_plant_seconds, Some(25));
        assert_eq!(round.spawn_to_plant_seconds, Some(27));
        assert_eq!(round.ct_bot_kill_from_round_start_seconds, Some(31));
        let json = serde_json::to_string(&report).unwrap();
        for private in ["Runner", "Opponent", "STEAM_ID_LAN", "<12>"] {
            assert!(!json.contains(private));
        }
    }

    #[test]
    fn requires_actual_plant_from_the_selected_terrorist() {
        let spawn = event(PLAYER, "Spawned_With_The_Bomb");
        let other_plant = event(OTHER_T, "Planted_The_Bomb");
        let chat = format!(r#"{PLAYER} say "Planted_The_Bomb""#);
        let report = fixture(&[
            (3, &spawn),
            (5, START),
            (7, &chat),
            (11, &other_plant),
            (19, END),
        ]);
        assert_eq!(report.verified_plants, 0);
        assert_eq!(report.rounds[0].outcome, Outcome::NoPlant);
    }

    #[test]
    fn discards_a_possession_lost_before_plant() {
        let got = event(PLAYER, "Got_The_Bomb");
        let dropped = event(PLAYER, "Dropped_The_Bomb");
        let plant = event(PLAYER, "Planted_The_Bomb");
        let death = format!(r#"{BOT} killed {PLAYER} with "usp""#);
        let report = fixture(&[
            (2, START),
            (3, &got),
            (4, &dropped),
            (10, &plant),
            (11, &death),
            (15, END),
            (16, START),
            (18, &plant),
            (22, END),
        ]);
        assert_eq!(report.verified_plants, 0);
        assert_eq!(report.rounds[0].outcome, Outcome::PlayerDied);
        assert_eq!(report.rounds[1].outcome, Outcome::NoPlayerC4Evidence);
    }

    #[test]
    fn evaluates_a_plant_before_capture_ends_without_claiming_a_round_win() {
        let got = event(PLAYER, "Got_The_Bomb");
        let plant = event(PLAYER, "Planted_The_Bomb");
        let report = fixture(&[(1, START), (3, &got), (21, &plant)]);
        assert_eq!(report.verified_plants, 1);
        assert_eq!(report.verified_spawn_to_plant, 0);
        assert_eq!(report.verified_easy_bot_round_wins, 0);
        assert_eq!(report.rounds[0].close, Close::CaptureEnd);
        assert_eq!(report.rounds[0].terrorist_win, None);
    }

    #[test]
    fn restart_or_second_start_cannot_reuse_prior_possession() {
        let spawn = event(PLAYER, "Spawned_With_The_Bomb");
        let plant = event(PLAYER, "Planted_The_Bomb");
        for reset in [r#"World triggered "Restart_Round_(1_second)""#, START] {
            let last = if reset == START { 0 } else { 1 };
            let mut events = vec![(1, &*spawn), (2, START), (3, reset)];
            if last == 1 {
                events.push((4, START));
            }
            events.push((6, &plant));
            events.push((7, END));
            let report = fixture(&events);
            assert_eq!(report.verified_plants, 0);
            assert_eq!(report.rounds[0].outcome, Outcome::IncompleteEvidence);
        }
    }

    #[test]
    fn validates_calendar_and_midnight_elapsed() {
        assert!(log_line("L 02/29/2024 - 00:00:00: valid").is_some());
        assert!(log_line("L 02/29/2025 - 00:00:00: invalid").is_none());
        let log = format!(
            "L 12/31/2026 - 23:59:57: {}\nL 12/31/2026 - 23:59:59: {START}\nL 01/01/2027 - 00:00:22: {}\n",
            event(PLAYER, "Spawned_With_The_Bomb"), event(PLAYER, "Planted_The_Bomb")
        );
        let report = analyze(&log, 12).unwrap();
        assert_eq!(report.rounds[0].round_start_to_plant_seconds, Some(23));
        assert_eq!(report.rounds[0].spawn_to_plant_seconds, Some(25));
    }

    #[test]
    fn bot_evidence_needs_kill_easy_difficulty_and_round_end() {
        let kill = format!(r#"{PLAYER} killed {BOT} with "glock""#);
        let win = r#"Team "TERRORIST" triggered "Target_Bombed" (CT "0") (T "1")"#;
        let report = fixture(&[(1, START), (4, &kill), (5, win), (5, END)]);
        assert_eq!(
            report.rounds[0].ct_bot_kill_from_round_start_seconds,
            Some(3)
        );
        assert_eq!(report.rounds[0].terrorist_win, Some(true));
        assert_eq!(report.verified_easy_bot_round_wins, 0);
        let easy = r#"Server cvar "bot_difficulty" = "0""#;
        let report = fixture(&[(1, easy), (2, START), (4, &kill), (5, win)]);
        assert_eq!(report.verified_easy_bot_round_wins, 0);
    }

    #[test]
    fn rejects_cross_round_or_rewound_times() {
        let got = event(PLAYER, "Got_The_Bomb");
        let plant = event(PLAYER, "Planted_The_Bomb");
        let report = fixture(&[(12, START), (14, &got), (10, &plant), (17, END)]);
        assert_eq!(report.verified_plants, 0);
        assert_eq!(report.rounds[0].close, Close::ClockDiscontinuity);
    }
}

fn analyze(log: &str, player: u32) -> Result<Report> {
    let mut rounds = Vec::new();
    let mut active: Option<ActiveRound> = None;
    let mut pending_c4: Option<C4> = None;
    let mut difficulty = None;
    let mut last_at = None;
    for line in log.lines() {
        let Some((at, message)) = log_line(line.trim_start_matches('\u{feff}')) else {
            continue;
        };
        let Some(event) = game_event(message, player) else {
            continue;
        };
        if last_at.is_some_and(|prior| at < prior) {
            close_round(
                &mut rounds,
                &mut active,
                last_at.unwrap_or(at),
                Close::ClockDiscontinuity,
            )?;
            pending_c4 = None;
            difficulty = None;
        }
        last_at = Some(at);
        match event {
            Event::RoundStart => {
                if active.is_some() {
                    close_round(&mut rounds, &mut active, at, Close::MissingRoundEnd)?;
                    pending_c4 = None;
                }
                let fresh_c4 = pending_c4
                    .take()
                    .filter(|item| at - item.at <= FREEZE_LIMIT_SECONDS);
                active = Some(ActiveRound::new(at, fresh_c4, difficulty));
            }
            Event::RoundEnd => {
                close_round(&mut rounds, &mut active, at, Close::RoundEnd)?;
                pending_c4 = None;
            }
            Event::CaptureBoundary => {
                close_round(&mut rounds, &mut active, at, Close::CaptureEnd)?;
                pending_c4 = None;
                difficulty = None;
            }
            Event::Reset => {
                close_round(&mut rounds, &mut active, at, Close::RestartOrMapChange)?;
                pending_c4 = None;
            }
            Event::Difficulty(value) => {
                difficulty = Some(value);
                if let Some(round) = &mut active {
                    round.apply(at, event);
                }
            }
            event => {
                if let Some(round) = &mut active {
                    round.apply(at, event);
                } else {
                    match event {
                        Event::C4 {
                            owned: true,
                            spawned,
                        } => {
                            if spawned || !pending_c4.is_some_and(|item| item.spawned) {
                                pending_c4 = Some(C4 { at, spawned });
                            }
                        }
                        Event::C4 { owned: false, .. }
                        | Event::Drop
                        | Event::Plant
                        | Event::Death => pending_c4 = None,
                        _ => {}
                    }
                }
            }
        }
    }
    if let Some(at) = last_at {
        close_round(&mut rounds, &mut active, at, Close::CaptureEnd)?;
    }

    let mut round_start_to_plant = Vec::new();
    let mut spawn_to_plant = Vec::new();
    let mut verified_easy_bot_round_wins = 0;
    let mut verified_plant_bot_round_wins = 0;
    let mut player_c4_rounds = 0;
    for round in &rounds {
        if round.c4_acquired_from_round_start_seconds.is_some() {
            player_c4_rounds += 1;
        }
        if round.outcome == Outcome::Planted {
            if let Some(elapsed) = round.round_start_to_plant_seconds {
                round_start_to_plant.push(elapsed);
            }
            if let Some(elapsed) = round.spawn_to_plant_seconds {
                spawn_to_plant.push(elapsed);
            }
        }
        if round.terrorist_win == Some(true) && round.ct_bot_kill_from_round_start_seconds.is_some()
        {
            if round.bot_difficulty == Some(0) {
                verified_easy_bot_round_wins += 1;
            }
            if round.outcome == Outcome::Planted {
                verified_plant_bot_round_wins += 1;
            }
        }
    }
    let completed = |round: &&RoundReport| {
        matches!(round.close, Close::RoundEnd)
            && round.terrorist_win.is_some()
            && round.c4_acquired_from_round_start_seconds.is_some()
    };
    let verified_completed_actor_rounds = rounds.iter().filter(completed).count();
    let verified_completed_actor_wins = rounds
        .iter()
        .filter(completed)
        .filter(|round| round.terrorist_win == Some(true))
        .count();
    Ok(Report {
        schema: "reflexcore.cs16.benchmark.v1",
        evidence: "goldsrc_server_log",
        timestamp_precision_seconds: 1,
        rounds_observed: rounds.len(),
        player_c4_rounds,
        verified_plants: round_start_to_plant.len(),
        verified_spawn_to_plant: spawn_to_plant.len(),
        verified_easy_bot_round_wins,
        verified_plant_bot_round_wins,
        verified_completed_actor_rounds,
        verified_completed_actor_wins,
        round_start_to_plant: timing(round_start_to_plant),
        spawn_to_plant: timing(spawn_to_plant),
        rounds,
    })
}

fn analyze_file(path: &Path, player: u32) -> Result<Report> {
    let file = File::open(path).map_err(|_| "Cannot open local server log")?;
    let metadata = file.metadata().map_err(|_| "Cannot inspect server log")?;
    if !metadata.is_file() || metadata.len() > MAX_LOG_BYTES {
        return Err("Expected a server log file of no more than 8 MiB".into());
    }
    let mut bytes = Vec::new();
    file.take(MAX_LOG_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "Cannot read server log")?;
    if bytes.len() as u64 > MAX_LOG_BYTES {
        return Err("Server log grew beyond the 8 MiB limit".into());
    }
    // A writer may still have a partial final line buffered. Ignore it.
    let end = bytes
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map_or(0, |index| index + 1);
    analyze(&String::from_utf8_lossy(&bytes[..end]), player)
}

pub fn run(args: &[String]) -> Result<()> {
    let args: Vec<_> = args.iter().map(String::as_str).collect();
    let ["benchmark", path, "--player", player, rest @ ..] = args.as_slice() else {
        return Err(
            "Usage: reflexcore cs16 benchmark <server.log> --player <userid> [--require-bot-win|--require-plant-kill-win]"
                .into(),
        );
    };
    if !matches!(
        rest,
        [] | ["--require-bot-win"] | ["--require-plant-kill-win"]
    ) {
        return Err("Invalid CS16 benchmark arguments".into());
    }
    let player = decimal(player)
        .and_then(|id| u32::try_from(id).ok())
        .filter(|id| *id > 0)
        .ok_or("Player must be a positive server userid")?;
    let report = analyze_file(Path::new(path), player)?;
    println!("{}", serde_json::to_string_pretty(&report)?);
    if report.verified_plants == 0 {
        return Err("No verified plant found in the selected player's rounds".into());
    }
    if rest == ["--require-bot-win"] && report.verified_easy_bot_round_wins == 0 {
        return Err("No verified easy-bot kill and Terrorist round win found".into());
    }
    if rest == ["--require-plant-kill-win"] && report.verified_plant_bot_round_wins == 0 {
        return Err("No round with a verified plant, bot kill and Terrorist win found".into());
    }
    Ok(())
}
