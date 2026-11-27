use super::{Capability, Skill, SKILLS};
use crate::task_integrity::{self, Fault};
use serde::Serialize;
use std::{
    io::Read,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

pub(crate) const ID: &str = "artifact.verify_saved_text";
pub(super) const LIMIT: usize = 4096;
const CONTRACT: u32 = 1;
const DISK: &[Capability] = &[Capability::OwnedArtifact, Capability::ReopenDisk];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Adapter {
    Winforms,
    Notepad,
}

#[derive(Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum TextEncoding {
    Utf8,
    BomOrUtf8,
}

#[derive(Serialize)]
pub(crate) struct Binding {
    adapter: Adapter,
    adapter_version: u32,
    contract_version: u32,
    capabilities: &'static [Capability],
    encoding: TextEncoding,
    pub(crate) background: bool,
    pub(crate) backend: &'static str,
}

pub(crate) const BINDINGS: &[Binding] = &[
    Binding {
        adapter: Adapter::Winforms,
        encoding: TextEncoding::Utf8,
        adapter_version: 1,
        contract_version: CONTRACT,
        capabilities: DISK,
        background: true,
        backend: "owned_uia_fixture",
    },
    Binding {
        adapter: Adapter::Notepad,
        encoding: TextEncoding::BomOrUtf8,
        adapter_version: 1,
        contract_version: CONTRACT,
        capabilities: DISK,
        background: false,
        backend: "owned_foreground_editor",
    },
];

fn compatible(skill: &Skill, version: u32, background: bool, binding: &Binding) -> bool {
    version == skill.version
        && binding.contract_version == CONTRACT
        && (!background || binding.background)
        && skill
            .requires
            .iter()
            .all(|cap| binding.capabilities.contains(cap))
}

pub(crate) fn bind(
    id: &str,
    version: u32,
    adapter: Adapter,
    background: bool,
) -> Result<&'static Binding, Fault> {
    let skill = SKILLS
        .iter()
        .find(|s| s.id == id && s.operation == super::Operation::VerifySavedText)
        .ok_or(Fault::PreconditionFailed)?;
    BINDINGS
        .iter()
        .find(|b| b.adapter == adapter && compatible(skill, version, background, b))
        .ok_or(Fault::PreconditionFailed)
}

pub(crate) fn describe_binding(
    id: &str,
    version: &str,
    app: &str,
    mode: &str,
) -> crate::Result<()> {
    let adapter = match app {
        "winforms" => Adapter::Winforms,
        "notepad" => Adapter::Notepad,
        _ => return Err(Fault::PreconditionFailed.into()),
    };
    let background = match mode {
        "foreground" => false,
        "background" => true,
        _ => return Err(Fault::PreconditionFailed.into()),
    };
    let version = version.parse().map_err(|_| Fault::PreconditionFailed)?;
    let bound = bind(id, version, adapter, background)?;
    println!(
        "{}",
        serde_json::json!({"schema":"reflexcore.skill.binding.v1","skill_id":id,
        "skill_version":version,"binding":bound})
    );
    Ok(())
}

#[derive(Debug, Serialize)]
pub(crate) struct Evidence<'a> {
    schema: &'static str,
    run_id: &'a str,
    skill_id: &'static str,
    skill_version: u32,
    adapter: Adapter,
    adapter_version: u32,
    verifier_version: u32,
    outcome: &'static str,
    readback_us: u64,
}

fn matches_text(bytes: &[u8], text: &str, encoding: TextEncoding) -> bool {
    // The WinForms fixture promises exact UTF-8 bytes. Notepad's contract is
    // ordinal text equality, including the BOM encodings supported by ReadAllText.
    if encoding == TextEncoding::BomOrUtf8 {
        for (bom, little) in [
            (&[0xff, 0xfe, 0, 0][..], true),
            (&[0, 0, 0xfe, 0xff][..], false),
        ] {
            if let Some(body) = bytes.strip_prefix(bom) {
                return body.iter().copied().eq(text.chars().flat_map(|c| {
                    if little {
                        (c as u32).to_le_bytes()
                    } else {
                        (c as u32).to_be_bytes()
                    }
                }));
            }
        }
        for (bom, little) in [(&[0xff, 0xfe][..], true), (&[0xfe, 0xff][..], false)] {
            if let Some(body) = bytes.strip_prefix(bom) {
                return body.iter().copied().eq(text.encode_utf16().flat_map(|c| {
                    if little {
                        c.to_le_bytes()
                    } else {
                        c.to_be_bytes()
                    }
                }));
            }
        }
        return bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes) == text.as_bytes();
    }
    bytes == text.as_bytes()
}

pub(crate) fn winforms_folder(run: &str) -> Result<PathBuf, Fault> {
    if run.len() != 56 || !run.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err(Fault::PreconditionFailed);
    }
    Ok(std::env::temp_dir().join(format!("ReflexCore-save-{run}")))
}

impl Binding {
    pub(super) fn matches_snapshot(&self, bytes:&[u8], text:&str)->bool {matches_text(bytes,text,self.encoding)}
    /// Capture only an adapter-owned fixture. The private source cannot be reconstructed from a receipt.
    pub(crate) fn artifact<'a>(
        &self,
        run: &'a str,
        expected: &str,
    ) -> Result<VerifiedArtifact<'a>, Fault> {
        use sha2::{Digest, Sha256};
        let path = match self.adapter {
            Adapter::Winforms => winforms_folder(run)?.join("saved.txt"),
            Adapter::Notepad => notepad_file(run, "fixture")?,
        };
        let (scope, path) =
            crate::local_files::target(&path).map_err(|_| Fault::PreconditionFailed)?;
        let mut file =
            crate::local_files::open(&path, true, 1).map_err(|_| Fault::EffectUnknown)?;
        let identity = file_identity(&file)?;
        // Keep the source pinned while the existing verifier independently opens the same name.
        let evidence = self.verify(run, &path, expected)?;
        let bytes = artifact_bytes(&mut file)?;
        if !matches_text(&bytes, expected, self.encoding) {
            return Err(Fault::VerificationFailed);
        }
        Ok(VerifiedArtifact {
            _scope: scope,
            file,
            identity,
            evidence,
            length: bytes.len(),
            fingerprint: Sha256::digest(&bytes).into(),
        })
    }
    pub(crate) fn verify_transfer<'a>(
        &self,
        run: &'a str,
        expected: &str,
    ) -> Result<Evidence<'a>, Fault> {
        self.artifact(run, expected)?
            .consume(run, self.adapter)
            .map(|(evidence, _)| evidence)
    }

    pub(crate) fn verify_winforms<'a>(
        &self,
        run: &'a str,
        expected: &str,
    ) -> Result<Evidence<'a>, Fault> {
        if self.adapter != Adapter::Winforms {
            return Err(Fault::PreconditionFailed);
        }
        self.verify(run, &winforms_folder(run)?.join("saved.txt"), expected)
    }

    fn verify<'a>(&self, run: &'a str, file: &Path, expected: &str) -> Result<Evidence<'a>, Fault> {
        if expected.is_empty() || expected.len() > LIMIT {
            return Err(Fault::PreconditionFailed);
        }
        let start = Instant::now();
        let mut bytes = Vec::with_capacity(LIMIT + 1);
        if task_integrity::cancelled() {
            return Err(Fault::CancelledUnknown);
        }
        let input =
            crate::local_files::open_for_readback(file).map_err(|_| Fault::EffectUnknown)?;
        input
            .take(LIMIT as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Fault::EffectUnknown)?;
        if task_integrity::cancelled() {
            return Err(Fault::CancelledUnknown);
        }
        if bytes.len() > LIMIT || !matches_text(&bytes, expected, self.encoding) {
            return Err(Fault::VerificationFailed);
        }
        Ok(Evidence {
            schema: "reflexcore.skill.evidence.v1",
            run_id: run,
            skill_id: ID,
            skill_version: 1,
            adapter: self.adapter,
            adapter_version: self.adapter_version,
            verifier_version: CONTRACT,
            outcome: "verified",
            readback_us: start.elapsed().as_micros() as u64,
        })
    }
}

pub(crate) struct VerifiedArtifact<'a> {
    _scope: crate::local_files::Directory,
    file: std::fs::File,
    identity: (u32, u32, u32),
    evidence: Evidence<'a>,
    length: usize,
    fingerprint: [u8; 32],
}

pub(super) fn file_identity(file: &std::fs::File) -> Result<(u32, u32, u32), Fault> {
    use std::os::windows::io::AsRawHandle;
    use windows::Win32::{Foundation::HANDLE, Storage::FileSystem::*};
    let handle = HANDLE(file.as_raw_handle());
    let mut fs_name = [0u16; 32];
    let mut info = BY_HANDLE_FILE_INFORMATION::default();
    unsafe {
        GetVolumeInformationByHandleW(handle, None, None, None, None, Some(&mut fs_name))
            .map_err(|_| Fault::PreconditionFailed)?;
        GetFileInformationByHandle(handle, &mut info).map_err(|_| Fault::EffectUnknown)?;
    }
    if !fs_name.starts_with(&[78, 84, 70, 83, 0])
        || info.nNumberOfLinks != 1
        || (info.nFileIndexHigh == 0 && info.nFileIndexLow == 0)
        || !file.metadata().map_err(|_| Fault::EffectUnknown)?.is_file()
    {
        return Err(Fault::PreconditionFailed);
    }
    Ok((
        info.dwVolumeSerialNumber,
        info.nFileIndexHigh,
        info.nFileIndexLow,
    ))
}

fn artifact_bytes(file: &mut std::fs::File) -> Result<Vec<u8>, Fault> {
    use std::io::Seek;
    if task_integrity::cancelled() {
        return Err(Fault::CancelledUnknown);
    }
    file.rewind().map_err(|_| Fault::EffectUnknown)?;
    let mut bytes = Vec::with_capacity(LIMIT + 1);
    file.take(LIMIT as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Fault::EffectUnknown)?;
    if bytes.len() > LIMIT {
        return Err(Fault::VerificationFailed);
    }
    if task_integrity::cancelled() {
        return Err(Fault::CancelledUnknown);
    }
    Ok(bytes)
}

impl<'a> VerifiedArtifact<'a> {
    pub(crate) fn consume(
        mut self,
        run: &str,
        adapter: Adapter,
    ) -> Result<(Evidence<'a>, Vec<u8>), Fault> {
        use sha2::{Digest, Sha256};
        if run != self.evidence.run_id
            || adapter != self.evidence.adapter
            || file_identity(&self.file)? != self.identity
        {
            return Err(Fault::PreconditionFailed);
        }
        let bytes = artifact_bytes(&mut self.file)?;
        if bytes.len() != self.length || Sha256::digest(&bytes)[..] != self.fingerprint {
            return Err(Fault::VerificationFailed);
        }
        Ok((self.evidence, bytes))
    }
}

pub(crate) fn transfer_check_enabled() -> bool {
    std::env::var("REFLEXCORE_CHECK_ARTIFACT_TRANSFER").as_deref() == Ok("1")
}

fn notepad_file(run: &str, scope: &str) -> Result<PathBuf, Fault> {
    use windows::Win32::{
        System::Com::CoTaskMemFree,
        UI::Shell::{
            FOLDERID_Desktop, FOLDERID_LocalAppData, SHGetKnownFolderPath, KF_FLAG_DEFAULT,
        },
    };
    if run.len() != 32
        || !run
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    {
        return Err(Fault::PreconditionFailed);
    }
    let id = match scope {
        "desktop" => FOLDERID_Desktop,
        "fixture" => FOLDERID_LocalAppData,
        _ => return Err(Fault::PreconditionFailed),
    };
    let raw = unsafe { SHGetKnownFolderPath(&id, KF_FLAG_DEFAULT, None) }
        .map_err(|_| Fault::Infrastructure)?;
    use std::os::windows::ffi::OsStringExt;
    let path = std::ffi::OsString::from_wide(unsafe { raw.as_wide() });
    unsafe {
        CoTaskMemFree(Some(raw.0.cast()));
    }
    let mut folder = PathBuf::from(path);
    if scope == "fixture" {
        folder.push("ReflexCore/runtime/fixtures");
    }
    Ok(folder.join(format!("ReflexCore-VisionLoop-{run}.txt")))
}

pub(crate) fn verify_notepad(run: &str, scope: &str) -> crate::Result<()> {
    let binding = bind(ID, 1, Adapter::Notepad, false)?;
    let path = notepad_file(run, scope)?;
    let text = std::env::var("REFLEXCORE_EXPECTED_TEXT").map_err(|_| Fault::PreconditionFailed)?;
    let start = Instant::now();
    loop {
        let verified = if scope == "fixture" && transfer_check_enabled() {
            binding.verify_transfer(run, &text)
        } else {
            binding.verify(run, &path, &text)
        };
        match verified {
            Ok(receipt) => {
                println!("{}", serde_json::to_string(&receipt)?);
                return Ok(());
            }
            Err(Fault::VerificationFailed | Fault::EffectUnknown)
                if start.elapsed() < Duration::from_secs(9) =>
            {
                std::thread::sleep(Duration::from_millis(150));
            }
            Err(fault) => return Err(fault.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binding_requires_id_version_mode_and_every_capability() {
        let skill = SKILLS.iter().find(|s| s.id == ID).unwrap();
        let absent = Binding {
            capabilities: &[Capability::OwnedArtifact],
            ..BINDINGS[0]
        };
        assert!(!compatible(skill, 1, false, &absent));
        assert!(bind(ID, 2, Adapter::Winforms, true).is_err());
        assert!(bind("unregistered", 1, Adapter::Notepad, false).is_err());
        assert!(bind(ID, 1, Adapter::Notepad, true).is_err());
        assert!(bind(ID, 1, Adapter::Winforms, true).is_ok());
        assert!(notepad_file("../old", "fixture").is_err());
        assert!(notepad_file(&"a".repeat(32), "untrusted").is_err());
    }

    #[test]
    fn pinned_source() {
        let run = task_integrity::run_id();
        let dir = winforms_folder(&run).unwrap();
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("saved.txt");
        std::fs::write(&path, "transfer").unwrap();
        let binding = bind(ID, 1, Adapter::Winforms, true).unwrap();
        let issue = || binding.artifact(&run, "transfer").unwrap();
        let source = issue();
        std::thread::scope(|s| {
            s.spawn(|| {
                assert!(std::fs::write(&path, "changed").is_err());
                assert!(std::fs::rename(&path, dir.join("moved")).is_err());
            })
            .join()
            .unwrap();
        });
        assert_eq!(
            source.consume(&run, Adapter::Winforms).unwrap().1,
            b"transfer"
        );
        assert!(issue().consume("foreign", Adapter::Winforms).is_err());
        let alias = dir.join("alias");
        std::fs::hard_link(&path, &alias).unwrap();
        assert!(binding.artifact(&run, "transfer").is_err());
        std::fs::remove_file(alias).unwrap();
        std::fs::remove_file(path).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }

    #[test]
    fn reopened_evidence_distinguishes_changed_missing_and_oversized_outputs() {
        let run = task_integrity::run_id();
        let file = std::env::temp_dir().join(format!("reflex-skill-{run}"));
        let expected = "Held-out Ω text\r\n";
        let binding = bind(ID, 1, Adapter::Notepad, false).unwrap();
        std::fs::write(&file, expected).unwrap();
        let receipt = serde_json::to_value(binding.verify(&run, &file, expected).unwrap()).unwrap();
        assert_eq!(receipt["run_id"], run);
        let public = receipt.to_string();
        assert!(!public.contains("Held-out") && !public.contains("reflex-skill-"));
        std::fs::write(&file, expected.trim()).unwrap();
        assert!(matches!(
            binding.verify(&run, &file, expected),
            Err(Fault::VerificationFailed)
        ));
        std::fs::write(&file, vec![b'x'; LIMIT + 1]).unwrap();
        assert!(matches!(
            binding.verify(&run, &file, &"x".repeat(LIMIT)),
            Err(Fault::VerificationFailed)
        ));
        std::fs::remove_file(&file).unwrap();
        assert!(matches!(
            binding.verify(&run, &file, expected),
            Err(Fault::EffectUnknown)
        ));
    }

    #[test]
    fn editor_specific_encoding_preserves_ordinal_text() {
        let text = "π😀";
        let bytes: Vec<_> = [0xff, 0xfe]
            .into_iter()
            .chain(text.encode_utf16().flat_map(u16::to_le_bytes))
            .collect();
        assert!(matches_text(&bytes, text, TextEncoding::BomOrUtf8));
        assert!(!matches_text(&bytes, text, TextEncoding::Utf8));
        assert!(!matches_text(
            &bytes[..bytes.len() - 1],
            text,
            TextEncoding::BomOrUtf8
        ));
        assert!(!matches_text(b"a\r\n", "a\n", TextEncoding::BomOrUtf8));
    }

    #[test]
    #[ignore = "Release microbenchmark; no UI or file access"]
    fn measure_binding() {
        use std::hint::black_box;
        let mut samples = Vec::new();
        for batch in 0..32 {
            let start = Instant::now();
            for _ in 0..4096 {
                black_box(
                    bind(
                        black_box(ID),
                        black_box(1),
                        black_box(Adapter::Winforms),
                        black_box(true),
                    )
                    .unwrap(),
                );
            }
            if batch != 0 {
                samples.push(start.elapsed().as_nanos() as f64 / 4096.0);
            }
        }
        samples.sort_by(f64::total_cmp);
        println!(
            "31 batches, 4096 binds each, ns/bind p50={:.2} p95={:.2} p99=max={:.2}",
            samples[15], samples[29], samples[30]
        );
    }
}
