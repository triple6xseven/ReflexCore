use crate::Result;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs::File,
    io::Read,
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

const SNAPSHOT: &str = "data/bridge/reflexvision.json";
const MAX_AGE_MS: u64 = 650;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Snapshot {
    schema: String,
    sequence: u64,
    status: String,
    captured_unix_ms: u64,
    width: u16,
    height: u16,
    objects: Vec<Detection>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Detection {
    id: u32,
    kind: String,
    confidence: f32,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
}

fn decode(bytes: &[u8], now: u64) -> Result<Snapshot> {
    if bytes.len() > 8 * 1024 {
        return Err("ReflexVision snapshot exceeds maximum size".into());
    }
    let frame: Snapshot = serde_json::from_slice(bytes)?;
    if frame.schema != "reflexcore.vision.v1"
        || frame.status != "live"
        || frame.sequence == 0
        || now.abs_diff(frame.captured_unix_ms) > MAX_AGE_MS
        || frame.captured_unix_ms > now.saturating_add(100)
        || !(160..=640).contains(&frame.width)
        || !(72..=640).contains(&frame.height)
        || frame.objects.len() > 20
    {
        return Err("ReflexVision snapshot is unavailable, invalid or stale".into());
    }
    let mut ids = HashSet::with_capacity(frame.objects.len());
    for observed in &frame.objects {
        if !matches!(
            observed.kind.as_str(),
            "red_cue" | "hud_health" | "hud_armor" | "hud_clock" | "hud_ammo"
        ) || !(0.0..=1.0).contains(&observed.confidence)
            || observed.id == 0
            || !ids.insert(observed.id)
            || observed.width == 0
            || observed.height == 0
            || u32::from(observed.x) + u32::from(observed.width) > u32::from(frame.width)
            || u32::from(observed.y) + u32::from(observed.height) > u32::from(frame.height)
        {
            return Err("ReflexVision object rejected".into());
        }
    }
    Ok(frame)
}

// The existing CS16 CLI exposes the same observation to an operator or navigator.
// No movement is inferred from HUD or color cues.
pub(crate) fn run(args: &[String]) -> Result<()> {
    if args.len() != 1 {
        return Err("Usage: cs16 vision".into());
    }
    let mut data = Vec::new();
    File::open(Path::new(SNAPSHOT))?
        .take(8193)
        .read_to_end(&mut data)?;
    let now = u64::try_from(SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis())?;
    println!("{}", serde_json::to_string(&decode(&data, now)?)?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn frame() -> serde_json::Value {
        json!({
            "schema":"reflexcore.vision.v1", "sequence":1, "status":"live",
            "captured_unix_ms":1000, "width":480, "height":360,
            "objects":[{"id":1,"kind":"red_cue","confidence":0.8,"x":22,"y":31,"width":20,"height":32}]
        })
    }

    #[test]
    fn forwards_fresh_empty_or_tracked_frames() {
        let mut value = frame();
        assert_eq!(
            decode(&serde_json::to_vec(&value).unwrap(), 1100)
                .unwrap()
                .objects
                .len(),
            1
        );
        value["objects"] = json!([]);
        assert!(decode(&serde_json::to_vec(&value).unwrap(), 1100)
            .unwrap()
            .objects
            .is_empty());
    }

    #[test]
    fn refuses_stale_stopped_and_malformed_frames() {
        let mut value = frame();
        assert!(decode(&serde_json::to_vec(&value).unwrap(), 1700).is_err());
        value["status"] = json!("stopped");
        assert!(decode(&serde_json::to_vec(&value).unwrap(), 1100).is_err());
        value["status"] = json!("live");
        value["objects"][0]["width"] = json!(65535);
        assert!(decode(&serde_json::to_vec(&value).unwrap(), 1100).is_err());
        value["objects"][0]["width"] = json!(20);
        let item = value["objects"][0].clone();
        value["objects"] = json!([item.clone(), item]);
        assert!(decode(&serde_json::to_vec(&value).unwrap(), 1100).is_err());
    }
}
