use crate::{
    cs16_benchmark,
    cs16_demo::DemoReader,
    cs16_probe,
    cs16_route::{Navigator, Pose, Route},
    Result,
};
use serde_json::json;
use std::path::Path;

pub(crate) fn run(args: &[String]) -> Result<()> {
    match args.first().map(String::as_str) {
        Some("benchmark") => cs16_benchmark::run(args),
        Some("probe") => cs16_probe::run(args),
        Some("vision") => crate::vision::run(args),
        Some("practice") => crate::cs16_practice::run(args),
        Some("demo") if args.len() == 2 => inspect_demo(Path::new(&args[1])),
        Some("route-check") if args.len() == 3 => check_route(Path::new(&args[1]), Path::new(&args[2])),
        Some("route-draft") if args.len() == 5 => {
            let start = args[3].parse()?;
            let end = args[4].parse()?;
            let route = draft_route(Path::new(&args[1]), &args[2], start, end)?;
            println!("{}", serde_json::to_string_pretty(&route)?);
            Ok(())
        }
        _ => Err("Usage: cs16 benchmark <log> --player <userid> [--require-bot-win] | probe [--port <port>] [--pid <pid>] | vision | practice <mailbox> <route> --allow-offline | demo <demo> | route-draft <demo> <A|B> <start-seconds> <end-seconds> | route-check <route> <demo>".into()),
    }
}

fn check_route(route: &Path, demo: &Path) -> Result<()> {
    let route = Route::load(route)?;
    let mut reader = DemoReader::open(demo)?;
    let sample = reader
        .poll_next()?
        .ok_or("No complete living pose in demo")?;
    let map = reader.map_name().ok_or("Missing demo map")?;
    let mut navigator = Navigator::new(route, map)?;
    let [x, y, z] = sample.position.map(f64::from);
    let pose = Pose {
        sample_id: 1,
        x,
        y,
        z,
        yaw_degrees: f64::from(sample.view_angles[1]).rem_euclid(360.0),
    };
    let decision = navigator.step(pose);
    println!(
        "{}",
        json!({"schema":"reflexcore.cs16.route_check.v1", "map":map, "decision":decision})
    );
    if matches!(decision, crate::cs16_route::Decision::Stopped { .. }) {
        return Err("The route rejected the selected recording's first living pose".into());
    }
    Ok(())
}

fn inspect_demo(path: &Path) -> Result<()> {
    let mut reader = DemoReader::open(path)?;
    let sample = reader
        .poll()?
        .ok_or("No complete living pose in the scanned demo frames")?;
    println!(
        "{}",
        json!({
            "schema": "reflexcore.cs16.demo.v1",
            "map": reader.map_name(),
            "sealed": reader.is_sealed(),
            "sample": {
                "frame": sample.frame, "time_s": sample.time_secs, "packet_time_s": sample.packet_time_secs,
                "position": sample.position, "view_angles": sample.view_angles, "health": sample.health
            }
        })
    );
    Ok(())
}

fn horizontal_distance(a: [f32; 3], b: [f32; 3]) -> f32 {
    (a[0] - b[0]).hypot(a[1] - b[1])
}

fn draft_route(path: &Path, site: &str, start: f32, end: f32) -> Result<serde_json::Value> {
    if !matches!(site, "A" | "B")
        || !start.is_finite()
        || !end.is_finite()
        || start < 0.0
        || end <= start
        || end - start > 240.0
        || end > 3600.0
    {
        return Err("Expected site A/B and a bounded nonempty range in demo seconds".into());
    }
    let mut reader = DemoReader::open(path)?;
    let mut points = Vec::new();
    let mut previous = None;
    let mut last_time = -1.0;
    let mut covered = false;
    let mut reached_end = false;
    for _ in 0..500_000 {
        let sample = match reader.poll_next()? {
            Some(sample) => sample,
            None if reader.is_finished() => break,
            None => {
                return Err(
                    "The demo cut is incomplete or its frame scan exceeded the bound".into(),
                )
            }
        };
        if !reader.is_sealed() {
            return Err("Close the game recording before deriving a waypoint draft".into());
        }
        let time = sample.time_secs;
        if time < start {
            continue;
        }
        if last_time > time {
            return Err("The selected demo crosses a time reset".into());
        }
        last_time = time;
        if time > end {
            reached_end = true;
            break;
        }
        let pos = sample.position;
        if let Some(before) = previous {
            if horizontal_distance(pos, before) > 96.0 || (pos[2] - before[2]).abs() > 72.0 {
                return Err("The selected demo crosses a respawn or a pose discontinuity".into());
            }
        }
        if !covered && time - start > 1.0 {
            return Err("The selected start has no nearby living sample".into());
        }
        covered = true;
        if points.last().is_none_or(|last| {
            horizontal_distance(pos, *last) >= 64.0 || (pos[2] - last[2]).abs() >= 20.0
        }) {
            points.push(pos);
            if points.len() >= 128 {
                return Err("Route exceeds 127 sampled waypoints".into());
            }
        }
        previous = Some(pos);
    }
    if !covered || (!reached_end && end - last_time > 1.0) {
        return Err("The recording does not cover the requested interval".into());
    }
    if let Some(pos) = previous {
        if points
            .last()
            .is_some_and(|last| horizontal_distance(pos, *last) >= 9.0)
        {
            points.push(pos);
        }
    }
    let waypoints: Vec<_> = points
        .into_iter()
        .map(|p| json!({"x":p[0], "y":p[1], "z":p[2]}))
        .collect();
    let value = json!({
        "schema": "reflexcore.cs16.route.v1",
        "map": reader.map_name(),
        "site": site,
        "waypoints": waypoints
    });
    Route::parse(&serde_json::to_vec(&value)?)?;
    Ok(value)
}
