use std::{
    ffi::{OsStr, OsString},
    fs::{File, OpenOptions},
    io,
    os::windows::{
        ffi::{OsStrExt, OsStringExt},
        fs::{MetadataExt, OpenOptionsExt},
        io::AsRawHandle,
    },
    path::{Component, Path, PathBuf, Prefix},
};
use windows::{
    core::PCWSTR,
    Win32::{
        Foundation::HANDLE,
        Storage::FileSystem::{
            GetDriveTypeW, GetFinalPathNameByHandleW, MoveFileW, FILE_NAME_NORMALIZED,
        },
    },
};

const OPEN_REPARSE_POINT: u32 = 0x0020_0000;
const BACKUP_SEMANTICS: u32 = 0x0200_0000;
const READ_ATTRIBUTES: u32 = 0x80;
const REPARSE: u32 = 0x400;

fn invalid() -> io::Error {
    io::ErrorKind::InvalidInput.into()
}
fn wide(path: &OsStr) -> Vec<u16> {
    path.encode_wide().chain(Some(0)).collect()
}

pub(super) fn physical(file: &File) -> io::Result<PathBuf> {
    let mut buf = vec![0; 512];
    loop {
        let size = unsafe {
            GetFinalPathNameByHandleW(HANDLE(file.as_raw_handle()), &mut buf, FILE_NAME_NORMALIZED)
        } as usize;
        if size == 0 {
            return Err(io::Error::last_os_error());
        }
        if size < buf.len() {
            return Ok(PathBuf::from(OsString::from_wide(&buf[..size])));
        }
        if size > 32768 {
            return Err(invalid());
        }
        buf.resize(size + 1, 0);
    }
}
fn safe_name(name: &str) -> bool {
    let stem = name
        .split('.')
        .next()
        .unwrap_or("")
        .trim_end()
        .to_ascii_uppercase();
    let device = matches!(
        stem.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$" | "CLOCK$"
    ) || ["COM", "LPT"].iter().any(|p| {
        stem.strip_prefix(p).is_some_and(|n| {
            n.len() == 1 && n.as_bytes()[0].is_ascii_digit() || matches!(n, "¹" | "²" | "³")
        })
    });
    !device
        && !name.is_empty()
        && !name.ends_with([' ', '.'])
        && !name
            .chars()
            .any(|c| c.is_control() || "<>:\"|?*".contains(c))
}
pub(super) fn relative(s: &str) -> io::Result<PathBuf> {
    if s.len() > 1024 || !s.split(['/', '\\']).all(safe_name) {
        return Err(invalid());
    }
    Ok(PathBuf::from(s))
}

// Normal drive paths only. Inspect each component without following reparse points
// and retain directory handles without write/delete sharing until inspection ends.
pub(super) struct Directory {
    pub path: PathBuf,
    _pins: Vec<File>,
}
impl Directory {
    pub fn local(path: &Path) -> io::Result<Self> {
        let mut parts = path.components();
        let Some(Component::Prefix(prefix)) = parts.next() else {
            return Err(invalid());
        };
        let Prefix::Disk(letter) = prefix.kind() else {
            return Err(invalid());
        };
        if parts.next() != Some(Component::RootDir) {
            return Err(invalid());
        }
        let root = PathBuf::from(format!("{}:\\", char::from(letter)));
        let drive = wide(root.as_os_str());
        if !matches!(unsafe { GetDriveTypeW(PCWSTR(drive.as_ptr())) }, 2 | 3 | 6) {
            return Err(invalid());
        }
        let mut dir = Self {
            path: root,
            _pins: Vec::new(),
        };
        dir.pin()?;
        for part in parts {
            dir.descend(part)?;
        }
        Ok(dir)
    }
    pub fn physical(&self) -> io::Result<PathBuf> {
        physical(self._pins.last().ok_or_else(invalid)?)
    }
    fn pin(&mut self) -> io::Result<()> {
        let file = open(&self.path, false, 1)?;
        if !file.metadata()?.is_dir() {
            return Err(invalid());
        }
        self._pins.push(file);
        Ok(())
    }
    fn descend(&mut self, part: Component<'_>) -> io::Result<()> {
        let Component::Normal(name) = part else {
            return Err(invalid());
        };
        if !name.to_str().is_some_and(safe_name) {
            return Err(invalid());
        }
        self.path.push(name);
        self.pin()
    }
    pub fn child_parent(&self, path: &Path) -> io::Result<Self> {
        let mut dir = Self {
            path: self.path.clone(),
            _pins: Vec::new(),
        };
        for part in path.parent().ok_or_else(invalid)?.components() {
            dir.descend(part)?;
        }
        Ok(dir)
    }
}
pub(super) fn open(path: &Path, read: bool, share: u32) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options
        .read(true)
        .custom_flags(OPEN_REPARSE_POINT | BACKUP_SEMANTICS)
        .share_mode(share);
    if !read {
        options.access_mode(READ_ATTRIBUTES);
    }
    let file = options.open(path)?;
    if file.metadata()?.file_attributes() & REPARSE != 0 {
        return Err(invalid());
    }
    Ok(file)
}
pub(super) fn target(path: &Path) -> io::Result<(Directory, PathBuf)> {
    let name = path
        .file_name()
        .and_then(OsStr::to_str)
        .filter(|s| safe_name(s))
        .ok_or_else(invalid)?;
    let parent = Directory::local(path.parent().ok_or_else(invalid)?)?;
    let path = parent.path.join(name);
    Ok((parent, path))
}
pub(super) fn publish(from: &Path, to: &Path) -> io::Result<()> {
    let src = wide(from.as_os_str());
    let dest = wide(to.as_os_str());
    unsafe { MoveFileW(PCWSTR(src.as_ptr()), PCWSTR(dest.as_ptr())) }
        .map_err(|_| io::Error::last_os_error())
}
