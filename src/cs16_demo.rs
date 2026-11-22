//! Read-only pose observations from a local GoldSrc protocol 5 demo.
//!
//! Wire framing: https://github.com/cgdangelo/talent/blob/main/libraries/parser-goldsrc/docs/demo-structure.md
//! RefParams fields: https://github.com/ValveSoftware/halflife/blob/master/common/ref_params.h

use std::fs::File;
use std::io::{self, BufReader, Read, Seek, SeekFrom};
use std::path::Path;

const HEADER_BYTES: usize = 544;
const FRAME_HEADER_BYTES: usize = 9;
const PACKET_BYTES: usize = 468;
const MAX_PACKET_DATA: u32 = 65_536;
const MAX_FRAMES_PER_POLL: usize = 32_768;
const MAX_DEMO_BYTES: u64 = i32::MAX as u64;
const DIRECTORY_ENTRY_BYTES: u64 = 92;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct DemoSample {
    /// Playback time in seconds, relative to the current recording section.
    pub time_secs: f32,
    /// Raw packet timestamp. Some clients leave this at zero.
    pub packet_time_secs: f32,
    pub frame: u32,
    /// Predicted player position, in game map coordinates.
    pub position: [f32; 3],
    /// Client pitch, yaw and roll in degrees.
    pub view_angles: [f32; 3],
    pub health: i32,
}

pub(crate) struct DemoReader {
    file: BufReader<File>,
    offset: u64,
    header_read: bool,
    directory: Option<u64>,
    map: Option<String>,
    sections_ended: u8,
    needs_seek: bool,
    finished: bool,
}

enum Frame {
    Other,
    Pose(Option<DemoSample>),
    SectionEnd,
}

impl DemoReader {
    pub(crate) fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let file = File::open(path)?;
        if !file.metadata()?.is_file() {
            return Err(invalid("demo input must be a file"));
        }
        Ok(Self {
            file: BufReader::with_capacity(64 * 1024, file),
            offset: 0,
            header_read: false,
            directory: None,
            map: None,
            sections_ended: 0,
            needs_seek: false,
            finished: false,
        })
    }

    pub(crate) fn map_name(&self) -> Option<&str> {
        self.map.as_deref()
    }

    /// True after reading the closed recording's directory offset, or after
    /// observing the client close the last section and write that directory.
    pub(crate) fn is_sealed(&self) -> bool {
        self.directory.is_some()
    }

    /// All complete frame data has been visited. An unsealed recording can
    /// have no new samples and still continue on the next poll.
    pub(crate) fn is_finished(&self) -> bool {
        self.finished
    }

    /// Consume complete new frames only. An incomplete tail is retried at its
    /// original offset. This never returns an old pose when no new pose exists.
    pub(crate) fn poll(&mut self) -> io::Result<Option<DemoSample>> {
        self.scan(false)
    }

    /// Return the next complete living pose in recording order. If the bounded
    /// scan yields no pose, check is_finished before deciding to end replay.
    pub(crate) fn poll_next(&mut self) -> io::Result<Option<DemoSample>> {
        self.scan(true)
    }

    fn scan(&mut self, first_pose: bool) -> io::Result<Option<DemoSample>> {
        if self.finished && self.is_sealed() {
            return Ok(None);
        }
        // When replaying a finalized recording, reuse its validated boundary
        // instead of querying filesystem metadata for every individual pose.
        let file_len = if first_pose && self.is_sealed() {
            self.directory.unwrap()
        } else {
            self.file.get_ref().metadata()?.len()
        };
        if file_len > MAX_DEMO_BYTES || file_len < self.offset {
            return Err(invalid("demo is oversized or was truncated"));
        }
        if self.finished {
            self.refresh_directory()?;
            return Ok(None);
        }
        if !self.header_read {
            if file_len < HEADER_BYTES as u64 {
                return Ok(None);
            }
            let mut header = [0; HEADER_BYTES];
            self.file.seek(SeekFrom::Start(0))?;
            if !read_complete(&mut self.file, &mut header)? {
                return Ok(None);
            }
            if &header[..8] != b"HLDEMO\0\0" || dword(&header, 8) != 5 {
                return Err(invalid("expected a GoldSrc protocol 5 demo"));
            }
            self.set_directory(dword(&header, 540), file_len)?;
            let map = &header[16..276];
            let name = map.split(|byte| *byte == 0).next().unwrap_or_default();
            self.map = std::str::from_utf8(name)
                .ok()
                .filter(|name| {
                    !name.is_empty()
                        && name.len() <= 64
                        && name
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
                })
                .map(str::to_owned);
            self.offset = HEADER_BYTES as u64;
            self.header_read = true;
        }

        let limit = self
            .directory
            .map_or(file_len, |directory| directory.min(file_len));
        let mut latest = None;
        if self.needs_seek {
            self.file.seek(SeekFrom::Start(self.offset))?;
            self.needs_seek = false;
        }
        for _ in 0..MAX_FRAMES_PER_POLL {
            if self.offset == limit {
                self.finished = self.is_sealed();
                break;
            }
            self.needs_seek = true;
            let Some((frame, frame_bytes)) = read_frame(&mut self.file, limit - self.offset)?
            else {
                if self.is_sealed() {
                    return Err(invalid("partial frame in finalized demo"));
                }
                break;
            };
            self.needs_seek = false;
            self.offset += frame_bytes;
            self.finished = self.is_sealed() && self.offset == limit;
            match frame {
                Frame::Other => {}
                Frame::Pose(pose) => {
                    if first_pose && pose.is_some() {
                        return Ok(pose);
                    }
                    latest = pose;
                }
                Frame::SectionEnd => {
                    self.sections_ended = self.sections_ended.saturating_add(1);
                    latest = None;
                    if !self.is_sealed() && self.sections_ended >= 2 {
                        self.finished = true;
                        self.refresh_directory()?;
                        break;
                    }
                }
            }
        }
        Ok(latest)
    }

    fn refresh_directory(&mut self) -> io::Result<()> {
        self.file.seek(SeekFrom::Start(540))?;
        let mut directory = [0; 4];
        self.file.read_exact(&mut directory)?;
        let directory = u32::from_le_bytes(directory);
        if directory != 0 && u64::from(directory) != self.offset {
            return Err(invalid("demo directory does not follow the final section"));
        }
        if directory != 0 {
            self.set_directory(directory, self.file.get_ref().metadata()?.len())?;
        }
        Ok(())
    }

    fn set_directory(&mut self, directory: u32, file_len: u64) -> io::Result<()> {
        if directory != 0 {
            let directory = u64::from(directory);
            if directory < HEADER_BYTES as u64 || directory + 4 > file_len {
                return Err(invalid("invalid demo directory offset"));
            }
            self.file.seek(SeekFrom::Start(directory))?;
            let mut count = [0; 4];
            self.file.read_exact(&mut count)?;
            let count = u64::from(u32::from_le_bytes(count));
            if !(1..=1024).contains(&count)
                || directory + 4 + count * DIRECTORY_ENTRY_BYTES > file_len
            {
                return Err(invalid("invalid demo directory length"));
            }
            self.directory = Some(directory);
            self.needs_seek = true;
        }
        Ok(())
    }
}

fn read_frame(reader: &mut BufReader<File>, available: u64) -> io::Result<Option<(Frame, u64)>> {
    let mut header = [0; FRAME_HEADER_BYTES];
    if available < FRAME_HEADER_BYTES as u64 || !read_complete(reader, &mut header)? {
        return Ok(None);
    }
    let body_available = available - FRAME_HEADER_BYTES as u64;
    let (frame, consumed, remaining) = match header[0] {
        0 | 1 => {
            let mut packet = [0; PACKET_BYTES];
            if body_available < PACKET_BYTES as u64 || !read_complete(reader, &mut packet)? {
                return Ok(None);
            }
            let remaining = bounded_length(dword(&packet, PACKET_BYTES - 4))?;
            let frame = if header[0] == 1 {
                Frame::Pose(pose(&header, &packet))
            } else {
                Frame::Other
            };
            (frame, PACKET_BYTES as u64, remaining)
        }
        2 => (Frame::Other, 0, 0),
        3 => (Frame::Other, 0, 64),
        4 => (Frame::Other, 0, 32),
        5 => (Frame::SectionEnd, 0, 0),
        6 => (Frame::Other, 0, 84),
        7 => (Frame::Other, 0, 8),
        8 => {
            let mut sound = [0; 8];
            if body_available < 8 || !read_complete(reader, &mut sound)? {
                return Ok(None);
            }
            (Frame::Other, 8, bounded_length(dword(&sound, 4))? + 16)
        }
        9 => {
            let mut length = [0; 4];
            if body_available < 4 || !read_complete(reader, &mut length)? {
                return Ok(None);
            }
            (Frame::Other, 4, bounded_length(u32::from_le_bytes(length))?)
        }
        _ => return Err(invalid("unknown GoldSrc demo frame type")),
    };
    if consumed + remaining > body_available {
        return Ok(None);
    }
    if remaining != 0 {
        reader.seek_relative(remaining as i64)?;
    }
    Ok(Some((
        frame,
        FRAME_HEADER_BYTES as u64 + consumed + remaining,
    )))
}

fn pose(frame: &[u8], packet: &[u8]) -> Option<DemoSample> {
    let time_secs = float(frame, 1);
    let packet_time_secs = float(packet, 0);
    let position = vector(packet, 104);
    let view_angles = vector(packet, 132);
    let health = dword(packet, 144) as i32;
    let active_play = [72, 76, 80]
        .into_iter()
        .all(|offset| dword(packet, offset) == 0);
    if !active_play
        || health <= 0
        || !time_secs.is_finite()
        || time_secs < 0.0
        || !packet_time_secs.is_finite()
        || !position
            .iter()
            .chain(&view_angles)
            .all(|value| value.is_finite())
    {
        return None;
    }
    Some(DemoSample {
        time_secs,
        packet_time_secs,
        frame: dword(frame, 5),
        position,
        view_angles,
        health,
    })
}

fn read_complete(reader: &mut impl Read, bytes: &mut [u8]) -> io::Result<bool> {
    match reader.read_exact(bytes) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => Ok(false),
        Err(error) => Err(error),
    }
}

fn bounded_length(length: u32) -> io::Result<u64> {
    if length <= MAX_PACKET_DATA {
        Ok(u64::from(length))
    } else {
        Err(invalid("demo frame body exceeds size limit"))
    }
}

fn invalid(reason: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, reason)
}

fn dword(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
}

fn float(bytes: &[u8], offset: usize) -> f32 {
    f32::from_bits(dword(bytes, offset))
}

fn vector(bytes: &[u8], offset: usize) -> [f32; 3] {
    [
        float(bytes, offset),
        float(bytes, offset + 4),
        float(bytes, offset + 8),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, OpenOptions};
    use std::io::Write;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct Recording(PathBuf);

    impl Recording {
        fn new(label: &str, initial: &[u8]) -> io::Result<Self> {
            let stamp = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "reflexcore-demo-{}-{stamp}-{label}.dem",
                std::process::id()
            ));
            OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)?
                .write_all(initial)?;
            Ok(Self(path))
        }

        fn append(&self, bytes: &[u8]) -> io::Result<()> {
            OpenOptions::new()
                .append(true)
                .open(&self.0)?
                .write_all(bytes)
        }
    }

    impl Drop for Recording {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.0);
        }
    }

    fn header(directory: u32) -> [u8; HEADER_BYTES] {
        let mut bytes = [0; HEADER_BYTES];
        bytes[..8].copy_from_slice(b"HLDEMO\0\0");
        bytes[8..12].copy_from_slice(&5_u32.to_le_bytes());
        bytes[12..16].copy_from_slice(&48_u32.to_le_bytes());
        bytes[16..24].copy_from_slice(b"de_dust2");
        bytes[540..544].copy_from_slice(&directory.to_le_bytes());
        bytes
    }

    fn packet(frame: u32, health: i32, payload: &[u8]) -> Vec<u8> {
        let mut bytes = vec![0; FRAME_HEADER_BYTES + PACKET_BYTES];
        bytes[0] = 1;
        bytes[1..5].copy_from_slice(&(frame as f32 / 10.).to_le_bytes());
        bytes[5..9].copy_from_slice(&frame.to_le_bytes());
        let body = &mut bytes[FRAME_HEADER_BYTES..];
        body[0..4].copy_from_slice(&30_f32.to_le_bytes());
        for (offset, value) in [
            (104, -1200_f32),
            (108, 350.),
            (112, 30.),
            (132, -15.),
            (136, 100.),
        ] {
            body[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        }
        body[144..148].copy_from_slice(&health.to_le_bytes());
        body[464..468].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        bytes.extend(payload);
        bytes
    }

    #[test]
    fn waits_for_a_complete_header_and_live_packet() -> io::Result<()> {
        let bytes = header(0);
        let demo = Recording::new("live", &bytes[..100])?;
        let mut reader = DemoReader::open(&demo.0)?;
        assert_eq!(reader.poll()?, None);
        demo.append(&bytes[100..])?;
        let next = packet(25, 100, &[1, 2, 3, 4]);
        for range in [0..4, 4..9, 9..400, 400..next.len() - 1] {
            demo.append(&next[range])?;
            assert_eq!(reader.poll()?, None);
        }
        demo.append(&next[next.len() - 1..])?;
        assert_eq!(
            reader.poll()?,
            Some(DemoSample {
                time_secs: 2.5,
                packet_time_secs: 30.,
                frame: 25,
                position: [-1200., 350., 30.],
                view_angles: [-15., 100., 0.],
                health: 100,
            })
        );
        assert_eq!(reader.map_name(), Some("de_dust2"));
        assert_eq!(reader.poll()?, None);
        Ok(())
    }

    #[test]
    fn skips_variable_frames_and_does_not_return_a_dead_or_spectated_pose() -> io::Result<()> {
        let demo = Recording::new("mixed", &header(0))?;
        let mut reader = DemoReader::open(&demo.0)?;
        let mut frames = vec![0; FRAME_HEADER_BYTES + 8 + 3 + 16];
        frames[0] = 8;
        frames[FRAME_HEADER_BYTES + 4] = 3;
        let mut buffer = vec![0; FRAME_HEADER_BYTES + 4 + 2];
        buffer[0] = 9;
        buffer[FRAME_HEADER_BYTES] = 2;
        frames.extend(buffer);
        frames.extend(packet(25, 100, &[]));
        frames.extend(packet(26, 0, &[]));
        demo.append(&frames)?;
        assert_eq!(reader.poll()?, None);
        let mut spectator = packet(27, 100, &[]);
        spectator[FRAME_HEADER_BYTES + 80] = 1;
        demo.append(&spectator)?;
        assert_eq!(reader.poll()?, None);
        demo.append(&packet(28, 75, &[]))?;
        assert_eq!(reader.poll()?.map(|sample| sample.frame), Some(28));
        Ok(())
    }

    #[test]
    fn stops_at_finalized_directory_and_rejects_oversized_packet() -> io::Result<()> {
        let body = packet(25, 100, &[1, 2, 3, 4]);
        let mut bytes = header((HEADER_BYTES + body.len()) as u32).to_vec();
        bytes.extend(body);
        bytes.extend(1_u32.to_le_bytes());
        bytes.extend([255; DIRECTORY_ENTRY_BYTES as usize]);
        let demo = Recording::new("sealed", &bytes)?;
        let mut reader = DemoReader::open(&demo.0)?;
        assert_eq!(reader.poll()?.map(|sample| sample.frame), Some(25));
        assert_eq!(reader.poll()?, None);

        let mut bytes = header(0).to_vec();
        let mut oversized = packet(25, 100, &[]);
        oversized[FRAME_HEADER_BYTES + 464..FRAME_HEADER_BYTES + 468]
            .copy_from_slice(&(MAX_PACKET_DATA + 1).to_le_bytes());
        bytes.extend(oversized);
        let demo = Recording::new("oversized", &bytes)?;
        let mut reader = DemoReader::open(&demo.0)?;
        assert_eq!(
            reader.poll().unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        Ok(())
    }

    #[test]
    fn visits_sealed_poses_in_recording_order() -> io::Result<()> {
        let mut frames = vec![5; FRAME_HEADER_BYTES];
        frames.extend(packet(20, 100, &[]));
        frames.extend(packet(21, 0, &[]));
        frames.extend(packet(22, 75, &[1, 2, 3]));
        frames.extend([5; FRAME_HEADER_BYTES]);
        let mut bytes = header((HEADER_BYTES + frames.len()) as u32).to_vec();
        bytes.extend(frames);
        bytes.extend(2_u32.to_le_bytes());
        bytes.extend([0; 2 * DIRECTORY_ENTRY_BYTES as usize]);
        let demo = Recording::new("ordered", &bytes)?;
        let mut reader = DemoReader::open(&demo.0)?;
        assert_eq!(reader.poll_next()?.map(|sample| sample.frame), Some(20));
        assert!(reader.is_sealed());
        assert!(!reader.is_finished());
        assert_eq!(reader.poll_next()?.map(|sample| sample.frame), Some(22));
        assert!(!reader.is_finished());
        assert!(reader.poll_next()?.is_none());
        assert!(reader.is_finished());
        Ok(())
    }

    #[test]
    fn observes_live_recording_finalization() -> io::Result<()> {
        let mut initial = header(0).to_vec();
        initial.extend([5; FRAME_HEADER_BYTES]);
        initial.extend(packet(23, 100, &[]));
        let demo = Recording::new("finalizing", &initial)?;
        let mut reader = DemoReader::open(&demo.0)?;
        assert_eq!(reader.poll_next()?.map(|sample| sample.frame), Some(23));
        assert!(!reader.is_finished());
        assert!(!reader.is_sealed());
        demo.append(&[5; FRAME_HEADER_BYTES])?;
        assert!(reader.poll_next()?.is_none());
        assert!(reader.is_finished());
        assert!(!reader.is_sealed());
        let directory = (initial.len() + FRAME_HEADER_BYTES) as u32;
        demo.append(&2_u32.to_le_bytes())?;
        demo.append(&[0; 2 * DIRECTORY_ENTRY_BYTES as usize])?;
        let mut writer = OpenOptions::new().write(true).open(&demo.0)?;
        writer.seek(SeekFrom::Start(540))?;
        writer.write_all(&directory.to_le_bytes())?;
        drop(writer);
        assert!(reader.poll_next()?.is_none());
        assert!(reader.is_sealed());
        assert!(reader.is_finished());
        Ok(())
    }
}
