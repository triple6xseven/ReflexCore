# Distribution and attribution

Public ReflexCore source is released under the repository MIT license. The rights holder authorized redistribution of the adapted zxcLagLab visual interface, original theme collection and six generated theme artworks in this MIT release. Attribution is to the zxcLagLab and ReflexCore projects. The UI port is documented in [Studio](STUDIO.md). Theme artwork retains its pixels and has been stripped of authoring metadata. System fonts are selected by family name. Network drivers and packet processing are outside this UI port.

The Rust dependency graph is locked in Cargo.lock. SQLite is built through the bundled libsqlite3-sys configuration. The source archive contains no dependency binaries or model weights. Dependency licenses below are Cargo metadata declarations, including alternatives where present. Binary distributors must carry the applicable notices. See the selected crate version on crates.io for license texts.

| Dependency | Version | Declared license |
|---|---|---|
| [bitflags](https://crates.io/crates/bitflags/2.13.2) | 2.13.2 | MIT OR Apache-2.0 |
| [block-buffer](https://crates.io/crates/block-buffer/0.10.4) | 0.10.4 | MIT OR Apache-2.0 |
| [cc](https://crates.io/crates/cc/1.11.3) | 1.11.3 | MIT OR Apache-2.0 |
| [cfg-if](https://crates.io/crates/cfg-if/1.0.5) | 1.0.5 | MIT OR Apache-2.0 |
| [cpufeatures](https://crates.io/crates/cpufeatures/0.2.17) | 0.2.17 | MIT OR Apache-2.0 |
| [crypto-common](https://crates.io/crates/crypto-common/0.1.7) | 0.1.7 | MIT OR Apache-2.0 |
| [digest](https://crates.io/crates/digest/0.10.7) | 0.10.7 | MIT OR Apache-2.0 |
| [fallible-iterator](https://crates.io/crates/fallible-iterator/0.3.0) | 0.3.0 | MIT/Apache-2.0 |
| [fallible-streaming-iterator](https://crates.io/crates/fallible-streaming-iterator/0.1.9) | 0.1.9 | MIT/Apache-2.0 |
| [find-msvc-tools](https://crates.io/crates/find-msvc-tools/0.1.15) | 0.1.15 | MIT OR Apache-2.0 |
| [foldhash](https://crates.io/crates/foldhash/0.2.0) | 0.2.0 | Zlib |
| [generic-array](https://crates.io/crates/generic-array/0.14.7) | 0.14.7 | MIT |
| [hashbrown](https://crates.io/crates/hashbrown/0.17.2) | 0.17.2 | MIT OR Apache-2.0 |
| [hashlink](https://crates.io/crates/hashlink/0.12.2) | 0.12.2 | MIT OR Apache-2.0 |
| [itoa](https://crates.io/crates/itoa/1.0.19) | 1.0.19 | MIT OR Apache-2.0 |
| [libc](https://crates.io/crates/libc/0.2.191) | 0.2.191 | MIT OR Apache-2.0 |
| [libsqlite3-sys](https://crates.io/crates/libsqlite3-sys/0.40.0) | 0.40.0 | MIT |
| [memchr](https://crates.io/crates/memchr/2.8.3) | 2.8.3 | Unlicense OR MIT |
| [pkg-config](https://crates.io/crates/pkg-config/0.3.34) | 0.3.34 | MIT OR Apache-2.0 |
| [proc-macro2](https://crates.io/crates/proc-macro2/1.0.107) | 1.0.107 | MIT OR Apache-2.0 |
| [quote](https://crates.io/crates/quote/1.0.47) | 1.0.47 | MIT OR Apache-2.0 |
| [rsqlite-vfs](https://crates.io/crates/rsqlite-vfs/0.2.0) | 0.2.0 | MIT |
| [rusqlite](https://crates.io/crates/rusqlite/0.43.0) | 0.43.0 | MIT |
| [serde](https://crates.io/crates/serde/1.0.229) | 1.0.229 | MIT OR Apache-2.0 |
| [serde_core](https://crates.io/crates/serde_core/1.0.229) | 1.0.229 | MIT OR Apache-2.0 |
| [serde_derive](https://crates.io/crates/serde_derive/1.0.229) | 1.0.229 | MIT OR Apache-2.0 |
| [serde_json](https://crates.io/crates/serde_json/1.0.154) | 1.0.154 | MIT OR Apache-2.0 |
| [sha2](https://crates.io/crates/sha2/0.10.9) | 0.10.9 | MIT OR Apache-2.0 |
| [shlex](https://crates.io/crates/shlex/2.0.1) | 2.0.1 | MIT OR Apache-2.0 |
| [smallvec](https://crates.io/crates/smallvec/1.16.6) | 1.16.6 | MIT OR Apache-2.0 |
| [sqlite-wasm-rs](https://crates.io/crates/sqlite-wasm-rs/0.6.3) | 0.6.3 | MIT |
| [syn](https://crates.io/crates/syn/2.0.119) | 2.0.119 | MIT OR Apache-2.0 |
| [syn](https://crates.io/crates/syn/3.0.10) | 3.0.10 | MIT OR Apache-2.0 |
| [thiserror](https://crates.io/crates/thiserror/2.0.21) | 2.0.21 | MIT OR Apache-2.0 |
| [thiserror-impl](https://crates.io/crates/thiserror-impl/2.0.21) | 2.0.21 | MIT OR Apache-2.0 |
| [typenum](https://crates.io/crates/typenum/1.20.1) | 1.20.1 | MIT OR Apache-2.0 |
| [unicode-ident](https://crates.io/crates/unicode-ident/1.0.27) | 1.0.27 | (MIT OR Apache-2.0) AND Unicode-3.0 |
| [vcpkg](https://crates.io/crates/vcpkg/0.2.15) | 0.2.15 | MIT/Apache-2.0 |
| [version_check](https://crates.io/crates/version_check/0.9.5) | 0.9.5 | MIT/Apache-2.0 |
| [windows](https://crates.io/crates/windows/0.62.2) | 0.62.2 | MIT OR Apache-2.0 |
| [windows-collections](https://crates.io/crates/windows-collections/0.3.2) | 0.3.2 | MIT OR Apache-2.0 |
| [windows-core](https://crates.io/crates/windows-core/0.62.2) | 0.62.2 | MIT OR Apache-2.0 |
| [windows-future](https://crates.io/crates/windows-future/0.3.2) | 0.3.2 | MIT OR Apache-2.0 |
| [windows-implement](https://crates.io/crates/windows-implement/0.60.2) | 0.60.2 | MIT OR Apache-2.0 |
| [windows-interface](https://crates.io/crates/windows-interface/0.59.3) | 0.59.3 | MIT OR Apache-2.0 |
| [windows-link](https://crates.io/crates/windows-link/0.2.1) | 0.2.1 | MIT OR Apache-2.0 |
| [windows-numerics](https://crates.io/crates/windows-numerics/0.3.1) | 0.3.1 | MIT OR Apache-2.0 |
| [windows-result](https://crates.io/crates/windows-result/0.4.1) | 0.4.1 | MIT OR Apache-2.0 |
| [windows-strings](https://crates.io/crates/windows-strings/0.5.1) | 0.5.1 | MIT OR Apache-2.0 |
| [windows-threading](https://crates.io/crates/windows-threading/0.2.1) | 0.2.1 | MIT OR Apache-2.0 |
| [zmij](https://crates.io/crates/zmij/1.0.23) | 1.0.23 | MIT |

Windows, Notepad, .NET Framework, Node.js, and optional Ollama are installed separately. Local model downloads use the Ollama library. Each distribution has its own license. The Qwen 2B and 4B tags used here are listed in the [Ollama registry](https://ollama.com/library/qwen3-vl/tags). Upstream research licenses and decisions are in [the research matrix](COMPETITOR-RESEARCH.md).
