//! Cooperative stop at the existing Windows desktop queue boundary.
use std::{
    env,
    error::Error,
    fmt,
    path::{Path, PathBuf},
};

#[derive(Debug)]
pub(crate) struct Cancelled;

impl fmt::Display for Cancelled {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Task stopped by operator or queue claim lost")
    }
}

impl Error for Cancelled {}

pub(crate) enum Cancellation {
    Unscoped,
    Queue { claim: PathBuf, request: PathBuf },
    InvalidClaim,
}

impl Cancellation {
    pub(crate) fn from_queue() -> Self {
        match env::var("REFLEXCORE_QUEUE_MANIFEST") {
            Ok(name) if !name.is_empty() => Self::for_claim(Path::new("data/bridge"), &name),
            Ok(_) | Err(env::VarError::NotPresent) => Self::Unscoped,
            Err(env::VarError::NotUnicode(_)) => Self::InvalidClaim,
        }
    }

    fn for_claim(bridge: &Path, name: &str) -> Self {
        let Some(id) = name.strip_suffix(".job") else {
            return Self::InvalidClaim;
        };
        let Some((timestamp, nonce)) = id.split_once('-') else {
            return Self::InvalidClaim;
        };
        if timestamp.len() != 17
            || !timestamp.bytes().all(|b| b.is_ascii_digit())
            || nonce.len() != 32
            || !nonce
                .bytes()
                .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
        {
            return Self::InvalidClaim;
        }
        Self::Queue {
            claim: bridge.join("running").join(name),
            request: bridge.join("queue-requests").join(format!("{id}.cancel")),
        }
    }

    pub(crate) fn check(&self) -> Result<(), Cancelled> {
        let can_continue = match self {
            Self::Unscoped => true,
            Self::Queue { claim, request } => {
                claim.is_file() && matches!(request.try_exists(), Ok(false))
            }
            Self::InvalidClaim => false,
        };
        if can_continue {
            Ok(())
        } else {
            Err(Cancelled)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };

    #[test]
    fn queued_cancellation_is_scoped_and_fails_closed() {
        let time = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = env::temp_dir().join(format!("reflexcore-cancel-{}-{time}", std::process::id()));
        fs::create_dir_all(root.join("running")).unwrap();
        fs::create_dir_all(root.join("queue-requests")).unwrap();
        let id = "20261123000000000-0123456789abcdef0123456789abcdef";
        let name = format!("{id}.job");
        let stop = Cancellation::for_claim(&root, &name);
        assert!(stop.check().is_err());
        let claim = root.join("running").join(&name);
        let request = root.join("queue-requests").join(format!("{id}.cancel"));
        fs::write(&claim, "").unwrap();
        assert!(stop.check().is_ok());
        fs::write(&request, "").unwrap();
        assert!(stop.check().is_err());
        assert!(Cancellation::Unscoped.check().is_ok());
        fs::remove_file(&request).unwrap();
        fs::remove_file(&claim).unwrap();
        assert!(stop.check().is_err());
        assert!(Cancellation::for_claim(&root, "../wrong.job")
            .check()
            .is_err());
        fs::remove_dir(root.join("running")).unwrap();
        fs::remove_dir(root.join("queue-requests")).unwrap();
        fs::remove_dir(root).unwrap();
    }
}
