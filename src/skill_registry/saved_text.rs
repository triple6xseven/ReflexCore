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
        match binding.verify(run, &path, &text) {
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
