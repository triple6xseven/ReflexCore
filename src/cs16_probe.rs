//! Read-only discovery of a GoldSrc listen server on the IPv4 loopback interface.
use crate::Result;
use serde::Serialize;
use std::{
    net::{Ipv4Addr, UdpSocket},
    time::Duration,
};

const QUERY: &[u8] = b"\xff\xff\xff\xff\x54Source Engine Query\x00";
const DEFAULT_PORT: u16 = 27015;

#[derive(Debug, Serialize)]
pub(crate) struct ServerInfo {
    pub map: String,
    pub players: u8,
    pub bots: u8,
}

fn take_string<'a>(data: &mut &'a [u8]) -> Option<&'a [u8]> {
    let end = data.iter().position(|byte| *byte == 0)?;
    let (field, remainder) = data.split_at(end);
    *data = &remainder[1..];
    Some(field)
}

fn info(packet: &[u8]) -> Option<ServerInfo> {
    let [0xff, 0xff, 0xff, 0xff, b'I', protocol, raw @ ..] = packet else {
        return None;
    };
    let mut data = raw;
    take_string(&mut data)?; // Server display name is private.
    let map = take_string(&mut data)?;
    let folder = take_string(&mut data)?;
    take_string(&mut data)?; // Game description.
    if folder != b"cstrike"
        || map.is_empty()
        || map.len() > 48
        || !map
            .iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'_' | b'-'))
    {
        return None;
    }
    let [10, 0, players, capacity, tail @ ..] = data else {
        return None;
    };
    let (bots, kind) = if *protocol == 0 {
        // Some GoldSrc builds send a 32-bit count instead of the standard byte.
        match tail {
            [bots, 0, 0, 0, b'l', b'w' | b'l', 0..=1, 0..=1, ..] => (*bots, b'l'),
            [bots, kind, b'w' | b'l', 0..=1, 0..=1, ..] => (*bots, *kind),
            _ => return None,
        }
    } else {
        let [bots, kind, b'w' | b'l', 0..=1, 0..=1, ..] = tail else {
            return None;
        };
        (*bots, *kind)
    };
    if kind != b'l' || *capacity == 0 || *players > *capacity || bots > *players {
        return None;
    }
    Some(ServerInfo {
        map: std::str::from_utf8(map).ok()?.to_owned(),
        players: *players,
        bots,
    })
}

pub(crate) fn probe(port: u16) -> Result<ServerInfo> {
    if port == 0 {
        return Err("Expected a nonzero CS16 server port".into());
    }
    let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0))?;
    socket.connect((Ipv4Addr::LOCALHOST, port))?;
    socket.set_read_timeout(Some(Duration::from_millis(900)))?;
    socket.send(QUERY)?;
    let mut buffer = [0u8; 2048];
    let length = socket
        .recv(&mut buffer)
        .map_err(|_| "No CS16 listen server replied on loopback")?;
    let data = &buffer[..length];
    let reply = if let [0xff, 0xff, 0xff, 0xff, b'A', token @ ..] = data {
        if token.len() != 4 {
            return Err("Invalid CS16 info challenge".into());
        }
        let mut request = QUERY.to_vec();
        request.extend_from_slice(token);
        socket.send(&request)?;
        let length = socket
            .recv(&mut buffer)
            .map_err(|_| "CS16 listen server did not answer challenge")?;
        &buffer[..length]
    } else {
        data
    };
    info(reply).ok_or_else(|| "Expected a valid cstrike listen-server response".into())
}

#[cfg(windows)]
pub(crate) fn listener_owned_by(port: u16, pid: u32) -> Result<bool> {
    use std::ffi::c_void;
    const IPV4: u32 = 2;
    const OWNER_PID: u32 = 1;
    const INSUFFICIENT_BUFFER: u32 = 122;
    const MAX_TABLE_BYTES: u32 = 8 * 1024 * 1024;

    #[link(name = "iphlpapi")]
    unsafe extern "system" {
        fn GetExtendedUdpTable(
            table: *mut c_void,
            size: *mut u32,
            order: i32,
            family: u32,
            class: u32,
            reserved: u32,
        ) -> u32;
    }

    let mut size = 0u32;
    let first =
        unsafe { GetExtendedUdpTable(std::ptr::null_mut(), &mut size, 0, IPV4, OWNER_PID, 0) };
    if first != INSUFFICIENT_BUFFER {
        return Err("Unable to size the Windows IPv4 UDP listener table".into());
    }
    let mut table = Vec::<u32>::new();
    for _ in 0..3 {
        if !(4..=MAX_TABLE_BYTES).contains(&size) {
            return Err("Invalid Windows IPv4 UDP listener table size".into());
        }
        table.resize((size as usize).div_ceil(4), 0);
        let result = unsafe {
            GetExtendedUdpTable(table.as_mut_ptr().cast(), &mut size, 0, IPV4, OWNER_PID, 0)
        };
        if result == INSUFFICIENT_BUFFER {
            continue;
        }
        if result != 0 {
            return Err("Unable to read the Windows IPv4 UDP listener table".into());
        }
        let count = table[0] as usize;
        let words = table
            .get(1..)
            .ok_or("Missing Windows IPv4 UDP listener rows")?;
        if count > words.len() / 3 {
            return Err("Truncated Windows IPv4 UDP listener table".into());
        }
        let mut matched = false;
        for row in words.chunks_exact(3).take(count) {
            let address = row[0].to_ne_bytes();
            let binding = u16::from_be(row[1] as u16);
            if binding == port && (address == [0, 0, 0, 0] || address == [127, 0, 0, 1]) {
                if row[2] != pid {
                    return Ok(false);
                }
                matched = true;
            }
        }
        return Ok(matched);
    }
    Err("The Windows IPv4 UDP listener table changed repeatedly".into())
}

pub(crate) fn run(args: &[String]) -> Result<()> {
    let values: Vec<_> = args.iter().map(String::as_str).collect();
    let (port, pid): (u16, Option<u32>) = match values.as_slice() {
        ["probe"] => (DEFAULT_PORT, None),
        ["probe", "--port", port] => (port.parse()?, None),
        ["probe", "--port", port, "--pid", pid] => (port.parse()?, Some(pid.parse()?)),
        _ => {
            return Err(
                "Usage: reflexcore cs16 probe [--port <number> [--pid <process-id>]]".into(),
            )
        }
    };
    if let Some(pid) = pid {
        #[cfg(windows)]
        {
            if pid == 0 || !listener_owned_by(port, pid)? {
                return Err(
                    "The supplied process does not exclusively own the loopback listener".into(),
                );
            }
        }
        #[cfg(not(windows))]
        {
            let _ = pid;
            return Err("Listener PID verification requires Windows".into());
        }
    }
    let result = probe(port)?;
    #[cfg(windows)]
    if let Some(pid) = pid {
        if !listener_owned_by(port, pid)? {
            return Err("The loopback listener owner changed during the request".into());
        }
    }
    println!("{}", serde_json::to_string(&result)?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reply(protocol: u8, metadata: &[u8]) -> Vec<u8> {
        let mut packet = b"\xff\xff\xff\xffI".to_vec();
        packet.push(protocol);
        packet.extend_from_slice(b"Private hostname\x00de_dust2\x00cstrike\x00Counter-Strike\x00");
        packet.extend_from_slice(metadata);
        packet
    }

    #[test]
    fn identifies_listen_servers_and_both_bot_count_layouts() {
        for packet in [
            reply(48, b"\x0a\x00\x02\x20\x01lw\x00\x00"),
            reply(0, b"\x0a\x00\x02\x20\x01\x00\x00\x00lw\x00\x00"),
        ] {
            let result = info(&packet).unwrap();
            assert_eq!(result.map, "de_dust2");
            assert_eq!(result.players, 2);
            assert_eq!(result.bots, 1);
            assert!(!serde_json::to_string(&result).unwrap().contains("hostname"));
        }
    }

    #[test]
    fn rejects_dedicated_inconsistent_and_truncated_replies() {
        for packet in [
            reply(48, b"\x0a\x00\x02\x20\x01dw\x00\x00"),
            reply(0, b"\x0a\x00\x01\x20\x02\x00\x00\x00lw\x00\x00"),
            reply(0, b"\x0a\x00\x01\x20\x00\x00"),
        ] {
            assert!(info(&packet).is_none());
        }
    }

    #[cfg(windows)]
    #[test]
    fn proves_windows_listener_owner() {
        let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = socket.local_addr().unwrap().port();
        assert!(listener_owned_by(port, std::process::id()).unwrap());
        assert!(!listener_owned_by(port, 0).unwrap());
    }
}
