//! Bounded waypoint tracking for an offline Counter-Strike 1.6 fixture.

use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::Read;
use std::path::Path;

const ROUTE_SCHEMA: &str = "reflexcore.cs16.route.v1";
const MAX_ROUTE_BYTES: usize = 32 * 1024;
const MAX_WAYPOINTS: usize = 128;
const MAX_COORDINATE: f64 = 32_768.0;
const MAX_SEGMENT_LENGTH: f64 = 512.0;
const MAX_SAMPLE_DISTANCE: f64 = 256.0;
const HEIGHT_TOLERANCE: f64 = 36.0;
const TURN_TOLERANCE: f64 = 8.0;
const MAX_TURN: f64 = 30.0;
const STALL_LIMIT: u8 = 4;
const MAX_OBSERVATIONS: u16 = 2048;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub(crate) enum Site {
    A,
    B,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Waypoint {
    x: f64,
    y: f64,
    z: f64,
    #[serde(default = "default_radius")]
    radius: f64,
}

fn default_radius() -> f64 {
    24.0
}

fn valid_point(x: f64, y: f64, z: f64) -> bool {
    [x, y, z]
        .into_iter()
        .all(|value| value.abs() <= MAX_COORDINATE)
}

impl Waypoint {
    fn measured_from(&self, pose: Pose, height_tolerance: f64) -> Measurement {
        let x = self.x - pose.x;
        let y = self.y - pose.y;
        let horizontal = x.hypot(y);
        let height = (self.z - pose.z).abs();
        let bearing = if horizontal > 0.01 {
            y.atan2(x).to_degrees()
        } else {
            pose.yaw_degrees
        };
        Measurement {
            distance: horizontal.hypot(height),
            reached: horizontal <= self.radius && height <= height_tolerance,
            turn: (bearing - pose.yaw_degrees + 180.0).rem_euclid(360.0) - 180.0,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Route {
    schema: String,
    map: String,
    site: Site,
    waypoints: Vec<Waypoint>,
}

impl Route {
    pub(crate) fn load(path: &Path) -> Result<Self, String> {
        let mut reader = File::open(path)
            .map_err(|error| format!("Could not open route: {error}"))?
            .take((MAX_ROUTE_BYTES + 1) as u64);
        let mut buffer = Vec::new();
        reader
            .read_to_end(&mut buffer)
            .map_err(|error| format!("Could not read route: {error}"))?;
        Self::parse(&buffer)
    }

    pub(crate) fn parse(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > MAX_ROUTE_BYTES {
            return Err("Route exceeds the byte limit".into());
        }
        let route: Self = serde_json::from_slice(bytes)
            .map_err(|error| format!("Invalid route JSON: {error}"))?;
        if route.schema != ROUTE_SCHEMA {
            return Err("Unsupported route schema".into());
        }
        if route.map.is_empty()
            || route.map.len() > 32
            || !route
                .map
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
        {
            return Err("Invalid route map name".into());
        }
        if !(2..=MAX_WAYPOINTS).contains(&route.waypoints.len()) {
            return Err("Route requires a spawn anchor and between 1 and 127 targets".into());
        }
        if route.waypoints.iter().any(|point| {
            !valid_point(point.x, point.y, point.z) || !(8.0..=128.0).contains(&point.radius)
        }) {
            return Err("Invalid waypoint position or radius".into());
        }
        for pair in route.waypoints.windows(2) {
            let from = &pair[0];
            let to = &pair[1];
            let distance = (from.x - to.x).hypot(from.y - to.y).hypot(from.z - to.z);
            if !(0.01..=MAX_SEGMENT_LENGTH).contains(&distance) {
                return Err("Adjacent waypoints must be distinct and within 512 units".into());
            }
        }
        Ok(route)
    }
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Pose {
    pub(crate) sample_id: u64,
    pub(crate) x: f64,
    pub(crate) y: f64,
    pub(crate) z: f64,
    pub(crate) yaw_degrees: f64,
}

impl Pose {
    fn valid(self) -> bool {
        valid_point(self.x, self.y, self.z) && self.yaw_degrees.abs() <= 360.0
    }

    fn distance_from(self, other: Self) -> f64 {
        (self.x - other.x)
            .hypot(self.y - other.y)
            .hypot(self.z - other.z)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum StopReason {
    InvalidPose,
    StalePose,
    SpawnOutsideRoute,
    PoseDiscontinuity,
    Stalled,
    ObservationLimit,
}

impl StopReason {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::InvalidPose => "invalid_pose",
            Self::StalePose => "stale_pose",
            Self::SpawnOutsideRoute => "spawn_outside_route",
            Self::PoseDiscontinuity => "pose_discontinuity",
            Self::Stalled => "stalled",
            Self::ObservationLimit => "observation_limit",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub(crate) enum Decision {
    /// Positive yaw is a GoldSrc left turn.
    Turn {
        delta_degrees: f64,
    },
    Advance {
        millis: u16,
    },
    /// Arrival denotes route geometry only. The game must confirm planting.
    Arrived {
        site: Site,
    },
    Stopped {
        reason: StopReason,
    },
}

#[derive(Clone, Copy)]
struct Measurement {
    distance: f64,
    reached: bool,
    turn: f64,
}

#[derive(Clone, Copy)]
enum ExpectedEffect {
    Turn { error: f64 },
    Advance { distance: f64 },
}

pub(crate) struct Navigator {
    route: Route,
    next: usize,
    observations: u16,
    last_pose: Option<Pose>,
    expected_effect: Option<ExpectedEffect>,
    stalled: u8,
    terminal: Option<Decision>,
    precise: bool,
}

impl Navigator {
    pub(crate) fn new(route: Route, observed_map: &str) -> Result<Self, String> {
        if route.map != observed_map {
            return Err("Observed map does not match route".into());
        }
        Ok(Self {
            route,
            next: 0,
            observations: 0,
            last_pose: None,
            expected_effect: None,
            stalled: 0,
            terminal: None,
            precise: false,
        })
    }

    pub(crate) fn with_precise_steering(mut self) -> Self {
        self.precise = true;
        self
    }

    pub(crate) fn site(&self) -> Site {
        self.route.site
    }

    pub(crate) fn blocked_heading(&self) -> Option<f64> {
        self.expected_effect?;
        let pose = self.last_pose?;
        let target = self.route.waypoints.get(self.next)?;
        Some((target.y - pose.y).atan2(target.x - pose.x).to_degrees())
    }

    fn terminate(&mut self, decision: Decision) -> Decision {
        self.terminal = Some(decision);
        decision
    }

    fn stop(&mut self, reason: StopReason) -> Decision {
        self.terminate(Decision::Stopped { reason })
    }

    pub(crate) fn step(&mut self, pose: Pose) -> Decision {
        if let Some(decision) = self.terminal {
            return decision;
        }
        if !pose.valid() {
            return self.stop(StopReason::InvalidPose);
        }
        let height_tolerance = if self.precise { 16.0 } else { HEIGHT_TOLERANCE };
        let turn_tolerance = if self.precise { 6.0 } else { TURN_TOLERANCE };
        if let Some(last) = self.last_pose {
            if pose.sample_id <= last.sample_id {
                return self.stop(StopReason::StalePose);
            }
            if pose.distance_from(last) > MAX_SAMPLE_DISTANCE {
                return self.stop(StopReason::PoseDiscontinuity);
            }
        } else if !self.route.waypoints[0]
            .measured_from(pose, height_tolerance)
            .reached
        {
            return self.stop(StopReason::SpawnOutsideRoute);
        }
        if self.observations == MAX_OBSERVATIONS {
            return self.stop(StopReason::ObservationLimit);
        }
        self.observations += 1;
        self.last_pose = Some(pose);

        let mut measured = self.route.waypoints[self.next].measured_from(pose, height_tolerance);
        if measured.reached {
            self.next += 1;
            // Consume the spawn anchor, but require a fresh observation for each later waypoint.
            if self.next == self.route.waypoints.len() {
                return self.terminate(Decision::Arrived {
                    site: self.route.site,
                });
            }
            measured = self.route.waypoints[self.next].measured_from(pose, height_tolerance);
            self.expected_effect = None;
            self.stalled = 0;
        }

        let no_progress = match self.expected_effect {
            Some(ExpectedEffect::Turn { error }) => {
                measured.turn.abs() > turn_tolerance && error - measured.turn.abs() < 1.0
            }
            Some(ExpectedEffect::Advance { distance }) => {
                distance - measured.distance < if self.precise { 0.75 } else { 2.0 }
            }
            None => false,
        };
        self.stalled = if no_progress { self.stalled + 1 } else { 0 };
        if self.stalled >= STALL_LIMIT {
            return self.stop(StopReason::Stalled);
        }

        if measured.turn.abs() > turn_tolerance {
            self.expected_effect = Some(ExpectedEffect::Turn {
                error: measured.turn.abs(),
            });
            Decision::Turn {
                delta_degrees: measured.turn.clamp(-MAX_TURN, MAX_TURN),
            }
        } else {
            self.expected_effect = Some(ExpectedEffect::Advance {
                distance: measured.distance,
            });
            let minimum = if self.precise { 24.0 } else { 45.0 };
            let millis = (measured.distance * 4.0).round().clamp(minimum, 160.0) as u16;
            Decision::Advance { millis }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn route(waypoints: &str) -> Route {
        let json = format!(
            r#"{{"schema":"{ROUTE_SCHEMA}","map":"de_fixture","site":"A","waypoints":{waypoints}}}"#
        );
        Route::parse(json.as_bytes()).unwrap()
    }

    fn pose(sample_id: u64, x: f64, y: f64, z: f64, yaw_degrees: f64) -> Pose {
        Pose {
            sample_id,
            x,
            y,
            z,
            yaw_degrees,
        }
    }

    #[test]
    fn turns_walks_and_reaches_ordered_waypoints() {
        let route = route(
            r#"[{"x":0,"y":0,"z":0},{"x":80,"y":0,"z":0},{"x":80,"y":80,"z":0,"radius":10}]"#,
        );
        let mut navigator = Navigator::new(route, "de_fixture").unwrap();
        assert_eq!(
            navigator.step(pose(1, 0.0, 0.0, 0.0, -45.0)),
            Decision::Turn {
                delta_degrees: 30.0
            }
        );
        assert_eq!(
            navigator.step(pose(2, 0.0, 0.0, 0.0, -15.0)),
            Decision::Turn {
                delta_degrees: 15.0
            }
        );
        assert_eq!(
            navigator.step(pose(3, 0.0, 0.0, 0.0, 0.0)),
            Decision::Advance { millis: 160 }
        );
        assert_eq!(
            navigator.step(pose(4, 80.0, 0.0, 0.0, 0.0)),
            Decision::Turn {
                delta_degrees: 30.0
            }
        );
        assert_eq!(
            navigator.step(pose(5, 80.0, 64.0, 0.0, 90.0)),
            Decision::Advance { millis: 64 }
        );
        assert_eq!(
            navigator.step(pose(6, 80.0, 73.0, 0.0, 90.0)),
            Decision::Arrived { site: Site::A }
        );
    }

    #[test]
    fn automatic_steering_realigns_before_taking_a_small_turn() {
        let points = r#"[{"x":0,"y":0,"z":36},{"x":100,"y":0,"z":36}]"#;
        let start = pose(1, 0.0, 0.0, 36.0, 7.0);
        let mut fixed = Navigator::new(route(points), "de_fixture").unwrap();
        let mut automatic = Navigator::new(route(points), "de_fixture")
            .unwrap()
            .with_precise_steering();
        assert!(matches!(fixed.step(start), Decision::Advance { .. }));
        assert!(matches!(automatic.step(start), Decision::Turn { .. }));
    }

    #[test]
    fn takes_short_signed_turn_across_wrap() {
        let route = route(r#"[{"x":0,"y":0,"z":0},{"x":-100,"y":17.63,"z":0}]"#);
        let mut navigator = Navigator::new(route, "de_fixture").unwrap();
        let Decision::Turn { delta_degrees } = navigator.step(pose(1, 0.0, 0.0, 0.0, -170.0))
        else {
            panic!("Expected a turn");
        };
        assert!((delta_degrees + 20.0).abs() < 0.02);
    }

    #[test]
    fn wrong_floor_cannot_report_arrival() {
        let route = route(r#"[{"x":0,"y":0,"z":0},{"x":80,"y":0,"z":64}]"#);
        let mut navigator = Navigator::new(route, "de_fixture").unwrap();
        navigator.step(pose(1, 0.0, 0.0, 0.0, 0.0));
        assert!(matches!(
            navigator.step(pose(2, 80.0, 0.0, 0.0, 0.0)),
            Decision::Advance { .. }
        ));
    }

    #[test]
    fn stops_after_repeated_unverified_action_effects() {
        for yaw in [0.0, 90.0] {
            let route = route(r#"[{"x":0,"y":0,"z":0},{"x":80,"y":0,"z":0}]"#);
            let mut navigator = Navigator::new(route, "de_fixture").unwrap();
            for id in 1..=4 {
                assert!(!matches!(
                    navigator.step(pose(id, 0.0, 0.0, 0.0, yaw)),
                    Decision::Stopped { .. }
                ));
            }
            let stopped = Decision::Stopped {
                reason: StopReason::Stalled,
            };
            assert_eq!(navigator.step(pose(5, 0.0, 0.0, 0.0, yaw)), stopped);
            assert_eq!(navigator.step(pose(6, 80.0, 0.0, 0.0, 0.0)), stopped);
        }
    }

    #[test]
    fn rejects_mismatched_map_and_inconsistent_poses() {
        const PATH: &str = r#"[{"x":0,"y":0,"z":0},{"x":80,"y":0,"z":0}]"#;
        assert!(Navigator::new(route(PATH), "de_other").is_err());
        for (first, second, reason) in [
            (
                pose(1, 40.0, 0.0, 0.0, 0.0),
                None,
                StopReason::SpawnOutsideRoute,
            ),
            (
                pose(1, 0.0, 0.0, 0.0, f64::NAN),
                None,
                StopReason::InvalidPose,
            ),
            (
                pose(1, 0.0, 0.0, 0.0, 0.0),
                Some(pose(1, 10.0, 0.0, 0.0, 0.0)),
                StopReason::StalePose,
            ),
            (
                pose(1, 0.0, 0.0, 0.0, 0.0),
                Some(pose(2, 400.0, 0.0, 0.0, 0.0)),
                StopReason::PoseDiscontinuity,
            ),
        ] {
            let mut navigator = Navigator::new(route(PATH), "de_fixture").unwrap();
            let actual = navigator.step(first);
            let actual = second.map_or(actual, |next| navigator.step(next));
            assert_eq!(actual, Decision::Stopped { reason });
        }
    }

    #[test]
    fn bounds_route_schema_and_loads_from_disk() {
        let good = r#"{"schema":"reflexcore.cs16.route.v1","map":"de_fixture","site":"B","waypoints":[{"x":0,"y":0,"z":0},{"x":80,"y":0,"z":0}]}"#;
        for invalid in [
            good.replace(".v1", ".v2"),
            good.replace("de_fixture", "../de_fake"),
            good.replace(r#""z":0"#, r#""z":0,"radius":2"#),
            good.replace(r#""z":0"#, r#""z":0,"command":"invalid""#),
            good.replace(r#""x":80"#, r#""x":20000"#),
        ] {
            assert!(Route::parse(invalid.as_bytes()).is_err(), "{invalid}");
        }
        assert!(Route::parse(&vec![b' '; MAX_ROUTE_BYTES + 1]).is_err());
        let path =
            std::env::temp_dir().join(format!("reflexcore-route-{}.json", std::process::id()));
        std::fs::write(&path, good).unwrap();
        let loaded = Route::load(&path);
        std::fs::remove_file(path).unwrap();
        assert_eq!(loaded.unwrap().site, Site::B);
    }
}
