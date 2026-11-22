//! ReflexCore Unified Brain 0.5.1: bounded local coordinator for CS 1.6.
//! IPC is explicit CLI arguments and a one-line stdout response. All fields
//! are enumerated; the Rust process never captures a screen or sends input.
//! Shared Control remains the only input executor and must verify focus,
//! human override and visual feedback before continuing.

use serde::{Deserialize, Serialize};
use std::{
    error::Error,
    fs::{self, OpenOptions},
    io::{self, Write, BufRead},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;
const PROTOCOL: &str = "reflexcore.unified.cli.v1";
const SESSION_SCHEMA: &str = "reflexcore.unified.session.v1";
const PRIVATE_DIR: &str = "data/private/unified";
const MAX_STEPS: u8 = 8;
const MAX_AGE_MS: u64 = 45 * 60 * 1000;
const MAX_STATE_BYTES: u64 = 4096;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Session {
    schema: String,
    id: String,
    phase: String,
    step: u8,
    pending: Option<String>,
    recent_moves: Vec<String>,
    visibly_changed_steps: u8,
    started_ms: u64,
    updated_ms: u64,
    stop_reason: Option<String>,
}

// Append-only structural events. Never store screenshots, prompts or window titles.
#[derive(Serialize)]
struct Event<'a> {
    schema: &'static str,
    session_id: &'a str,
    step: u8,
    kind: &'a str,
    code: &'a str,
    timestamp_ms: u64,
}
fn log_event(session: &Session, kind: &str, code: &str, time: u64) -> Result<()> {
    let path = Path::new(PRIVATE_DIR).join(format!("events-{}.jsonl", session.id));
    if path.exists() && fs::metadata(&path)?.len() > 16_384 {
        return Err("Unified event budget exceeded".into());
    }
    let value = Event {schema: "reflexcore.unified.event.v1", session_id: &session.id,
        step: session.step, kind, code, timestamp_ms: time};
    let mut file = OpenOptions::new().append(true).create(true).open(path)?;
    writeln!(file, "{}", serde_json::to_string(&value)?)?;
    file.flush()?;
    Ok(())
}

impl Session {
    fn new(id: &str, time: u64) -> Self {
        Self {
            schema: SESSION_SCHEMA.into(),
            id: id.into(),
            phase: "ready".into(),
            step: 0,
            pending: None,
            recent_moves: Vec::new(),
            visibly_changed_steps: 0,
            started_ms: time,
            updated_ms: time,
            stop_reason: None,
        }
    }

    fn validate(&self, id: &str, time: u64) -> Result<()> {
        if self.schema != SESSION_SCHEMA || self.id != id || self.step > MAX_STEPS
            || self.visibly_changed_steps > self.step || self.recent_moves.len() > 4
            || !matches!(self.phase.as_str(), "ready" | "awaiting_feedback" | "stopped")
            || self.pending.as_ref().is_some_and(|m| !is_move(m))
            || self.recent_moves.iter().any(|m| !is_move(m))
            || (self.phase == "awaiting_feedback") != self.pending.is_some()
            || time < self.started_ms || time - self.started_ms > MAX_AGE_MS
        {
            return Err("Unified session invalid or expired".into());
        }
        Ok(())
    }
}

fn is_move(s: &str) -> bool {
    matches!(s, "FORWARD" | "TURN_LEFT" | "TURN_RIGHT" | "STRAFE_LEFT" | "STRAFE_RIGHT")
}

fn valid_id(id: &str) -> bool {
    id.len() == 32 && id.bytes().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
}

fn now_ms() -> Result<u64> {
    Ok(u64::try_from(SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis())?)
}

fn session_path(id: &str) -> Result<PathBuf> {
    if !valid_id(id) { return Err("Invalid session identifier".into()); }
    Ok(Path::new(PRIVATE_DIR).join(format!("session-{id}.json")))
}

// The only planner for this boundary is an extension of the existing Goal Agent.
// ARRIVED is never translated into a verified goal without external evidence.
fn decide(s: &mut Session, sequence: u8, observed: &str, bombsite: &str) -> Result<String> {
    if s.phase != "ready" || sequence != s.step + 1 || sequence > MAX_STEPS {
        return Err("Unified sequence, phase or step limit rejected".into());
    }
    let skill = crate::agent::plan_cs16_step(observed, bombsite, &s.recent_moves)?;
    let Some(move_name) = skill else {
        s.phase = "stopped".into();
        s.stop_reason = Some(if observed == "ARRIVED" {
            "arrived_unverified".into()
        } else { "model_wait".into() });
        return Ok(if observed == "ARRIVED" { "STOP:ARRIVED_UNVERIFIED" } else { "STOP:WAIT" }.into());
    };
    s.step = sequence;
    s.pending = Some(move_name.into());
    s.phase = "awaiting_feedback".into();
    s.recent_moves.push(move_name.into());
    if s.recent_moves.len() > 4 { s.recent_moves.remove(0); }
    Ok(format!("ALLOW:{move_name}"))
}

// Visible pixel differences are only evidence of scene change, NOT movement.
fn feedback(s: &mut Session, sequence: u8, outcome: &str) -> Result<String> {
    if s.phase != "awaiting_feedback" || sequence != s.step || s.pending.is_none() {
        return Err("Unsolicited or replayed feedback rejected".into());
    }
    if !matches!(outcome, "VISIBLE_CHANGE" | "UNCHANGED" | "CAPTURE_FAILED" | "HUMAN") {
        return Err("Invalid feedback token".into());
    }
    s.pending = None;
    match outcome {
        "VISIBLE_CHANGE" => {
            s.visibly_changed_steps += 1;
            s.phase = "ready".into();
            Ok("CONTINUE:SCENE_CHANGED_UNVERIFIED".into())
        }
        "HUMAN" => {
            s.phase = "ready".into();
            // No visual result can be attributed to the agent after intervention.
            s.recent_moves.clear();
            Ok("CONTINUE:REOBSERVE_AFTER_HUMAN".into())
        }
        "UNCHANGED" => {
            s.phase = "stopped".into();
            s.stop_reason = Some("scene_unchanged".into());
            Ok("STOP:SCENE_UNCHANGED".into())
        }
        _ => {
            s.phase = "stopped".into();
            s.stop_reason = Some("capture_failed".into());
            Ok("STOP:CAPTURE_FAILED".into())
        }
    }
}

struct FileLock(PathBuf);
impl Drop for FileLock {
    fn drop(&mut self) { let _ = fs::remove_file(&self.0); }
}
fn lock(path: &Path) -> Result<FileLock> {
    let lock_path = path.with_extension("lock");
    OpenOptions::new().write(true).create_new(true).open(&lock_path)?;
    Ok(FileLock(lock_path))
}
fn read_session(path: &Path, id: &str, time: u64) -> Result<Session> {
    let meta = fs::metadata(path)?;
    if meta.len() == 0 || meta.len() > MAX_STATE_BYTES {
        return Err("Unified state file size invalid".into());
    }
    let state: Session = serde_json::from_slice(&fs::read(path)?)?;
    state.validate(id, time)?;
    Ok(state)
}
fn save_session(path: &Path, state: &Session, replace: bool) -> Result<()> {
    let data = serde_json::to_vec(state)?;
    if data.len() > MAX_STATE_BYTES as usize { return Err("Unified state too large".into()); }
    if replace {
        let tmp = path.with_extension(format!("{}.tmp", std::process::id()));
        let mut file = OpenOptions::new().create_new(true).write(true).open(&tmp)?;
        file.write_all(&data)?;
        file.sync_all()?;
        drop(file);
        if let Err(e) = fs::rename(&tmp, path) {
            let _ = fs::remove_file(&tmp);
            return Err(e.into());
        }
    } else {
        let mut file = OpenOptions::new().create_new(true).write(true).open(path)?;
        file.write_all(&data)?;
        file.sync_all()?;
    }
    Ok(())
}
fn parse_seq(s: &str) -> Result<u8> {
    if s.len() > 2 || s.starts_with('0') { return Err("Invalid sequence".into()); }
    let number: u8 = s.parse()?;
    if !(1..=MAX_STEPS).contains(&number) { return Err("Sequence out of bounds".into()); }
    Ok(number)
}

fn run_command(args: &[String]) -> Result<String> {
    if args.first().map(String::as_str) == Some("protocol") && args.len() == 1 {
        return Ok(PROTOCOL.into());
    }
    if args.first().map(String::as_str) == Some("self-test") && args.len() == 1 {
        // Pure policy smoke test with no Windows input and no runtime mutation.
        let mut state = Session::new("0123456789abcdef0123456789abcdef", now_ms()?);
        if decide(&mut state, 1, "FORWARD", "unknown")? != "ALLOW:FORWARD"
            || feedback(&mut state, 1, "VISIBLE_CHANGE")? != "CONTINUE:SCENE_CHANGED_UNVERIFIED"
            || state.visibly_changed_steps != 1 {
            return Err("Unified smoke test failed".into());
        }
        return Ok("SELF_TEST_OK".into());
    }
    if args.len() < 2 { return Err("Usage: unified begin|decide|feedback|cancel|status <32-hex-id> ...".into()); }
    let id = &args[1];
    let path = session_path(id)?;
    if args[0] == "begin" && args.len() == 2 {
        fs::create_dir_all(PRIVATE_DIR)?;
        let _held = lock(&path)?;
        let session = Session::new(id, now_ms()?);
        save_session(&path, &session, false)?;
        log_event(&session, "begin", "READY", session.started_ms)?;
        return Ok("READY".into());
    }
    if args[0] == "status" && args.len() == 2 {
        let state = read_session(&path, id, now_ms()?)?;
        return Ok(serde_json::to_string(&state)?);
    }
    let _held = lock(&path)?;
    let time = now_ms()?;
    let mut state = read_session(&path, id, time)?;
    let answer = match args[0].as_str() {
        "decide" if args.len() == 5 => decide(&mut state, parse_seq(&args[2])?, &args[3], &args[4])?,
        "feedback" if args.len() == 4 => feedback(&mut state, parse_seq(&args[2])?, &args[3])?,
        "cancel" if args.len() == 2 => {
            state.phase = "stopped".into();
            state.pending = None;
            state.stop_reason = Some("cancelled".into());
            "STOP:CANCELLED".into()
        },
        _ => return Err("Invalid unified command or argument count".into()),
    };
    state.updated_ms = time;
    save_session(&path, &state, true)?;
    let kind = match args[0].as_str() {
        "decide" => "decision", "feedback" => "verification", _ => "cancel"
    };
    log_event(&state, kind, &answer, time)?;
    Ok(answer)
}

pub fn run(args: &[String]) -> Result<()> {
    if args.len() == 1 && args[0] == "serve" { return serve_stdio(); }
    println!("{}", run_command(args)?);
    Ok(())
}


// 0.5.3 Runtime Foundation: one long-lived process, parent-only anonymous stdio.
// No listening socket, filesystem command queue, shell execution, or model-supplied arguments.
const RUNTIME_REQUEST: &str = "reflexcore.runtime.request.v1";
const RUNTIME_RESPONSE: &str = "reflexcore.runtime.response.v1";
const MAX_IPC_LINE: usize = 768;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RuntimeRequest {
    schema: String,
    id: String,
    op: String,
    session: Option<String>,
    sequence: Option<u8>,
    observed: Option<String>,
    zone: Option<String>,
    outcome: Option<String>,
}
#[derive(Clone, Debug, Default, Serialize)]
struct RuntimeWorld {
    mode: String,
    blocked_suspicions: u8,
    recovery_actions: u8,
    recent_visible_changes: u8,
    last_change_percent: Option<u8>,
    last_observed_action: Option<String>,
    recovery_pending: bool,
    // Does not claim coordinates or verified movement.
    movement_verified: bool,
}
struct RuntimeEngine {
    session: Option<Session>,
    world: RuntimeWorld,
}
impl RuntimeEngine {
    fn new() -> Self {
        Self { session: None, world: RuntimeWorld {
            mode: "auto".into(), ..RuntimeWorld::default()
        }}
    }
    fn dispatch(&mut self, r: RuntimeRequest) -> Result<String> {
        if r.schema != RUNTIME_REQUEST || !valid_id(&r.id) {return Err("Bad IPC schema or ID".into());}
        if r.op == "protocol" {
            if r.session.is_some() || r.sequence.is_some() || r.observed.is_some()
               || r.zone.is_some() || r.outcome.is_some() {return Err("Invalid protocol request".into());}
            return Ok(PROTOCOL.into());
        }
        if r.op == "begin" {
            if r.sequence.is_some() || r.observed.is_some() || r.zone.is_some() || r.outcome.is_some() {
                return Err("Invalid begin request".into());
            }
            let id = r.session.as_deref().ok_or("Missing session")?;
            if !valid_id(id) {return Err("Bad session id".into());}
            self.session = Some(Session::new(id, now_ms()?));
            self.world = RuntimeWorld {mode:"auto".into(), ..RuntimeWorld::default()};
            return Ok("READY".into());
        }
        let s = self.session.as_mut().ok_or("Session not started")?;
        let sid = r.session.as_deref().ok_or("Missing session")?;
        s.validate(sid, now_ms()?)?;
        if r.op == "cancel" {
            if r.sequence.is_some() || r.observed.is_some() || r.zone.is_some() || r.outcome.is_some() {
                return Err("Invalid cancel".into());
            }
            s.phase="stopped".into();s.pending=None;s.stop_reason=Some("cancelled".into());
            self.world.recovery_pending=false;
            return Ok("STOP:CANCELLED".into());
        }
        match r.op.as_str() {
            "mode" => {
                if r.sequence.is_some() || r.zone.is_some() || r.outcome.is_some() {return Err("Invalid mode request".into());}
                let mode=r.observed.as_deref().ok_or("Missing thinking mode")?;
                if !matches!(mode,"auto"|"reflex"|"focused"|"deep") {return Err("Unsupported mode".into());}
                if s.step!=0 || s.phase!="ready" {return Err("Mode change after start refused".into());}
                self.world.mode=mode.into();
                Ok(format!("MODE:{}",mode))
            }
            "decide" => {
                if r.outcome.is_some() || self.world.recovery_pending {return Err("Recovery required before new inference".into());}
                let sequence=r.sequence.ok_or("Missing sequence")?;
                let observed=r.observed.as_deref().ok_or("Missing action")?;
                let zone=r.zone.as_deref().ok_or("Missing zone")?;
                let value=decide(s,sequence,observed,zone)?;
                if value.starts_with("ALLOW:") {self.world.last_observed_action=Some(observed.into());}
                Ok(value)
            }
            "reflex" => {
                if r.outcome.is_some() || r.observed.is_some() || r.zone.is_some() || !self.world.recovery_pending {
                    return Err("Reflex not authorized".into());
                }
                let seq=r.sequence.ok_or("Missing reflex sequence")?;
                if self.world.recovery_actions>=2 {return Err("Recovery exhausted".into());}
                let move_name=if self.world.recovery_actions==0 {"TURN_RIGHT"} else {"TURN_LEFT"};
                self.world.recovery_pending=false;
                self.world.recovery_actions+=1;
                s.recent_moves.clear();
                let result=decide(s,seq,move_name,"unknown")?;
                self.world.last_observed_action=Some(move_name.into());
                Ok(result)
            }
            "feedback" => {
                if r.observed.is_some() || r.zone.is_some() {return Err("Invalid feedback request".into());}
                let seq=r.sequence.ok_or("Missing sequence")?;
                let outcome=r.outcome.as_deref().ok_or("Missing feedback")?;
                if s.phase!="awaiting_feedback" || s.step!=seq {return Err("Unsolicited feedback".into());}
                let last=s.pending.clone().ok_or("No pending action")?;
                if outcome=="UNCHANGED" && matches!(last.as_str(), "FORWARD"|"STRAFE_LEFT"|"STRAFE_RIGHT")
                   && self.world.mode=="auto" && self.world.recovery_actions<2 && s.step<MAX_STEPS {
                    s.pending=None;s.phase="ready".into();s.recent_moves.clear();
                    self.world.blocked_suspicions+=1;
                    self.world.recovery_pending=true;
                    self.world.last_change_percent=Some(0);
                    return Ok("CONTINUE:REFLEX_RECOVER".into());
                }
                let value=feedback(s,seq,outcome)?;
                if outcome=="VISIBLE_CHANGE" {self.world.recent_visible_changes+=1;}
                if outcome=="UNCHANGED" {self.world.blocked_suspicions+=1;}
                if outcome=="HUMAN" {self.world.recovery_pending=false;self.world.last_observed_action=None;}
                // A changed screenshot alone is never treated as verified movement.
                Ok(value)
            }
            "status" => {
                if r.sequence.is_some() || r.observed.is_some() || r.zone.is_some() || r.outcome.is_some() {
                    return Err("Invalid status request".into());
                }
                Ok(serde_json::to_string(&serde_json::json!({"session":s,"world":self.world}))?)
            }
            _ => Err("Unsupported IPC operation".into()),
        }
    }
}
fn read_bounded_line<R: BufRead>(reader: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut line=Vec::new();
    loop {
        let chunk=reader.fill_buf()?;
        if chunk.is_empty() {return if line.is_empty(){Ok(None)}else{Ok(Some(line))};}
        let end=chunk.iter().position(|v|*v==b'\n').map(|v|v+1);
        let amount=end.unwrap_or(chunk.len());
        if line.len()+amount>MAX_IPC_LINE {
            return Err(io::Error::new(io::ErrorKind::InvalidData,"IPC request exceeds line limit"));
        }
        line.extend_from_slice(&chunk[..amount]);
        reader.consume(amount);
        if end.is_some() {return Ok(Some(line));}
    }
}
fn serve_stdio() -> Result<()> {
    let mut runtime=RuntimeEngine::new();
    let stdin=io::stdin();
    let mut input=stdin.lock();
    let stdout=io::stdout();
    let mut output=stdout.lock();
    while let Some(line)=read_bounded_line(&mut input)? {
        let mut ok=false;
        let mut request_id=String::new();
        let mut value=String::new();
        if let Ok(request)=serde_json::from_slice::<RuntimeRequest>(&line) {
            request_id=request.id.clone();
            if let Ok(result)=runtime.dispatch(request) {ok=true;value=result;}
        }
        let response=serde_json::json!({
            "schema":RUNTIME_RESPONSE,"id":request_id,"ok":ok,
            "value":(if ok {value.as_str()} else {"REJECTED"})
        });
        writeln!(output,"{}",serde_json::to_string(&response)?)?;
        output.flush()?;
    }
    Ok(())
}

#[cfg(test)]
mod runtime_tests {
    use super::*;
    const SID:&str="0123456789abcdef0123456789abcdef";
    fn req(op:&str, seq:Option<u8>, value:Option<&str>) -> RuntimeRequest {
        RuntimeRequest {schema:RUNTIME_REQUEST.into(),id:SID.into(),op:op.into(),
            session:Some(SID.into()),sequence:seq,observed:value.map(str::to_owned),
            zone:None,outcome:None}
    }
    fn ready() -> RuntimeEngine {
        let mut e=RuntimeEngine::new();e.dispatch(req("begin",None,None)).unwrap();e
    }
    #[test] fn daemon_sequences_and_never_verifies_movement_from_pixels() {
        let mut e=ready();
        let mut d=req("decide",Some(1),Some("FORWARD"));d.zone=Some("unknown".into());
        assert_eq!(e.dispatch(d).unwrap(),"ALLOW:FORWARD");
        let mut f=req("feedback",Some(1),None);f.outcome=Some("VISIBLE_CHANGE".into());
        assert_eq!(e.dispatch(f).unwrap(),"CONTINUE:SCENE_CHANGED_UNVERIFIED");
        assert!(!e.world.movement_verified);
    }
    #[test] fn bounded_recovery_avoids_llm_for_one_turn() {
        let mut e=ready();
        let mut d=req("decide",Some(1),Some("FORWARD"));d.zone=Some("unknown".into());
        e.dispatch(d).unwrap();
        let mut f=req("feedback",Some(1),None);f.outcome=Some("UNCHANGED".into());
        assert_eq!(e.dispatch(f).unwrap(),"CONTINUE:REFLEX_RECOVER");
        let mut wrong=req("decide",Some(2),Some("FORWARD"));wrong.zone=Some("unknown".into());
        assert!(e.dispatch(wrong).is_err());
        assert_eq!(e.dispatch(req("reflex",Some(2),None)).unwrap(),"ALLOW:TURN_RIGHT");
        assert_eq!(e.world.recovery_actions,1);
    }
    #[test] fn rejects_replay_and_shell() {
        let mut e=ready();
        let mut d=req("decide",Some(1),Some("FORWARD"));d.zone=Some("unknown".into());
        e.dispatch(d).unwrap();
        let mut other=req("decide",Some(2),Some("ALT_F4"));other.zone=Some("unknown".into());
        assert!(e.dispatch(other).is_err());
        let mut f=req("feedback",Some(1),None);f.outcome=Some("VISIBLE_CHANGE".into());
        e.dispatch(f).unwrap();
        let mut replay=req("feedback",Some(1),None);replay.outcome=Some("VISIBLE_CHANGE".into());
        assert!(e.dispatch(replay).is_err());
    }
    #[test] fn overflow_and_unknown_fields_rejected() {
        let mut input=std::io::Cursor::new(vec![b'a';MAX_IPC_LINE+5]);
        assert!(read_bounded_line(&mut input).is_err());
        let bogus=format!(r#"{{"schema":"{}","id":"{}","op":"protocol","extra":"evil"}}"#,RUNTIME_REQUEST,SID);
        assert!(serde_json::from_str::<RuntimeRequest>(&bogus).is_err());
    }
    #[test] fn validates_mode_before_first_action() {
        let mut e=ready();
        let mut mode=req("mode",None,Some("deep"));
        assert_eq!(e.dispatch(mode).unwrap(),"MODE:deep");
        mode=req("mode",None,Some("arbitrary_shell"));
        assert!(e.dispatch(mode).is_err());
        assert_eq!(e.world.mode,"deep");
    }
    #[test] fn focused_does_not_act_on_unverified_obstacle() {
        let mut e=ready();
        e.dispatch(req("mode",None,Some("focused"))).unwrap();
        let mut d=req("decide",Some(1),Some("FORWARD"));d.zone=Some("unknown".into());
        e.dispatch(d).unwrap();
        let mut f=req("feedback",Some(1),None);f.outcome=Some("UNCHANGED".into());
        assert_eq!(e.dispatch(f).unwrap(),"STOP:SCENE_UNCHANGED");
    }
    #[test] fn human_override_discards_recovery() {
        let mut e=ready();
        let mut d=req("decide",Some(1),Some("FORWARD"));d.zone=Some("unknown".into());
        e.dispatch(d).unwrap();
        let mut f=req("feedback",Some(1),None);f.outcome=Some("HUMAN".into());
        assert_eq!(e.dispatch(f).unwrap(),"CONTINUE:REOBSERVE_AFTER_HUMAN");
        assert!(!e.world.recovery_pending);
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    fn demo() -> Session { Session::new("0123456789abcdef0123456789abcdef", 1_000) }
    #[test] fn rejects_bad_ids() {
        for x in ["", "../outside", "0123456789abcdef0123456789abcdeF", "0123456789abcdef0123456789abcdef0"] {
            assert!(session_path(x).is_err());
        }
    }
    #[test] fn rejects_shell_actions() {
        assert!(decide(&mut demo(), 1, "ALT_F4", "no").is_err());
    }
    #[test] fn accepts_bounded_step() {
        let mut s = demo();
        assert_eq!(decide(&mut s, 1, "FORWARD", "unknown").unwrap(), "ALLOW:FORWARD");
        assert_eq!(s.pending.as_deref(), Some("FORWARD"));
    }
    #[test] fn no_decision_without_feedback() {
        let mut s = demo();
        decide(&mut s, 1, "FORWARD", "no").unwrap();
        assert!(decide(&mut s, 2, "FORWARD", "no").is_err());
    }
    #[test] fn rejects_replayed_feedback() {
        let mut s = demo();
        decide(&mut s, 1, "FORWARD", "no").unwrap();
        feedback(&mut s, 1, "VISIBLE_CHANGE").unwrap();
        assert!(feedback(&mut s, 1, "VISIBLE_CHANGE").is_err());
    }
    #[test] fn does_not_equate_scene_change_with_goal() {
        let mut s = demo();
        decide(&mut s, 1, "FORWARD", "no").unwrap();
        assert_eq!(feedback(&mut s, 1, "VISIBLE_CHANGE").unwrap(), "CONTINUE:SCENE_CHANGED_UNVERIFIED");
        assert_eq!(s.phase, "ready");
        assert_eq!(s.visibly_changed_steps, 1);
    }
    #[test] fn stops_on_unchanged() {
        let mut s = demo();
        decide(&mut s, 1, "FORWARD", "unknown").unwrap();
        assert_eq!(feedback(&mut s, 1, "UNCHANGED").unwrap(), "STOP:SCENE_UNCHANGED");
        assert_eq!(s.phase, "stopped");
    }
    #[test] fn human_override_clears_unverified_history() {
        let mut s = demo();
        decide(&mut s, 1, "FORWARD", "unknown").unwrap();
        feedback(&mut s, 1, "HUMAN").unwrap();
        assert!(s.recent_moves.is_empty());
        assert_eq!(s.visibly_changed_steps, 0);
    }
    #[test] fn rejects_arrived_without_zone() {
        assert!(decide(&mut demo(), 1, "ARRIVED", "unknown").is_err());
    }
    #[test] fn arrived_is_not_verified() {
        let mut s = demo();
        assert_eq!(decide(&mut s, 1, "ARRIVED", "yes").unwrap(), "STOP:ARRIVED_UNVERIFIED");
        assert_eq!(s.phase, "stopped");
    }
    #[test] fn stops_at_step_limit() {
        let mut s = demo();
        for i in 1..=MAX_STEPS {
            decide(&mut s, i, "FORWARD", "unknown").unwrap();
            feedback(&mut s, i, "VISIBLE_CHANGE").unwrap();
        }
        assert!(decide(&mut s, 9, "FORWARD", "unknown").is_err());
    }
    #[test] fn rejects_wrong_sequence() {
        assert!(decide(&mut demo(), 2, "FORWARD", "unknown").is_err());
    }
    #[test] fn rejects_invalid_feedback() {
        let mut s = demo();
        decide(&mut s, 1, "FORWARD", "no").unwrap();
        assert!(feedback(&mut s, 1, "SUCCESS").is_err());
        assert_eq!(s.phase, "awaiting_feedback");
    }
    #[test] fn rejects_expired_and_malformed_state() {
        let mut s = demo();
        assert!(s.validate(&s.id, 1_000 + MAX_AGE_MS + 1).is_err());
        s.phase = "injected".into();
        assert!(s.validate(&s.id, 1_000).is_err());
    }
    #[test] fn rejects_alternating_turns() {
        let mut s = demo();
        for (i, mv) in ["TURN_LEFT", "TURN_RIGHT", "TURN_LEFT"].iter().enumerate() {
            let seq = (i + 1) as u8;
            decide(&mut s, seq, mv, "no").unwrap();
            feedback(&mut s, seq, "VISIBLE_CHANGE").unwrap();
        }
        assert!(decide(&mut s, 4, "TURN_RIGHT", "no").is_err());
    }
}
