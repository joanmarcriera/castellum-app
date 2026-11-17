// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Riera Technologies Ltd
//! Guard: no crate in the workspace writes straight into the system temp dir.
//!
//! A test helper that joins a file name onto the process temp dir, instead of
//! onto `castellum_testutil::scratch_root()`, leaks whatever it does not delete
//! by hand. SQLite makes that easy to miss: a helper that removes `x.db` still
//! leaves `x.db-wal` and `x.db-shm` behind (castellum-db's inbox_splits tests
//! did, until 9 Nov 2026). The scratch root is removed whole at exit, sidecars
//! included.
//!
//! Scans every `*.rs` file under `native/crates/*/src` and `native/crates/*/tests`.
//! Production code under `src/` is covered on purpose: the app keeps its data in
//! the profile directory, so a temp-dir call there is a bug too. Skipped: this
//! crate (it owns the one legitimate call, and this file names the pattern) and
//! `examples/` (stand-alone perf and demo binaries that manage and report their
//! own work directories). `tempfile` guards are fine: they clean up on drop.
//!
//! Matching ignores `//` comment lines and all whitespace, so `temp_dir ()`,
//! a call split across lines and `use std::env::temp_dir; temp_dir()` are caught.

use std::path::{Path, PathBuf};

/// Whether `text` (Rust source) calls `temp_dir(` outside a `//` comment line.
fn calls_raw_temp_dir(text: &str) -> bool {
    let code: String = text
        .lines()
        .filter(|l| !l.trim_start().starts_with("//"))
        .flat_map(str::chars)
        .filter(|c| !c.is_whitespace())
        .collect();
    code.contains("temp_dir(")
}

/// Every `*.rs` file under `dir`, recursively; symlinks are not followed.
fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        let path = entry.path();
        if kind.is_dir() {
            rust_files(&path, out);
        } else if kind.is_file() && path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

#[test]
fn matcher_catches_the_variants_and_ignores_comments() {
    assert!(calls_raw_temp_dir(
        "let p = std::env::temp_dir().join(\"x\");"
    ));
    assert!(calls_raw_temp_dir("let p = env::temp_dir ();"));
    assert!(calls_raw_temp_dir("let p = std::env::temp_dir\n    ();"));
    assert!(calls_raw_temp_dir(
        "use std::env::temp_dir;\nlet p = temp_dir();"
    ));
    assert!(!calls_raw_temp_dir(
        "// was std::env::temp_dir()\nlet p = scratch_root();"
    ));
    assert!(!calls_raw_temp_dir("    /// see std::env::temp_dir()"));
    assert!(!calls_raw_temp_dir("let d = tempfile::tempdir().unwrap();"));
}

#[test]
fn no_crate_uses_the_raw_temp_dir() {
    let this_crate = Path::new(env!("CARGO_MANIFEST_DIR"));
    let crates = this_crate.parent().expect("native/crates");

    let mut files = Vec::new();
    for krate in std::fs::read_dir(crates)
        .expect("read native/crates")
        .flatten()
    {
        let dir = krate.path();
        if !dir.is_dir() || dir == this_crate {
            continue;
        }
        rust_files(&dir.join("src"), &mut files);
        rust_files(&dir.join("tests"), &mut files);
    }
    assert!(files.len() > 50, "scan found only {} files", files.len());

    let hits: Vec<String> = files
        .iter()
        .filter(|f| calls_raw_temp_dir(&std::fs::read_to_string(f).expect("read source")))
        .map(|f| f.display().to_string())
        .collect();
    assert!(
        hits.is_empty(),
        "use castellum_testutil::scratch_root() instead of the system temp dir:\n{}",
        hits.join("\n")
    );
}
