//! Shared package collection used by both `analyze` and `instrument`.

use std::path::{Path, PathBuf};

use crate::collect::Collector;
use crate::model::Probe;
use crate::parse;

/// A discovered source file plus its parsed probes.
pub struct FileData {
    pub rel: String,
    pub src: String,
    pub line_starts: Vec<usize>,
    pub sha256: String,
    pub original_lines: usize,
    pub probes: Vec<Probe>,
}

pub struct PackageData {
    pub files: Vec<FileData>,
    pub total_slots: u32,
}

/// Discovers, reads, parses and collects probes for every source file in the
/// package. Returns Err(exit_code) on failure (2 = parse failure).
pub fn collect_package(
    package_dir: &Path,
    source_root: &str,
    spec_pattern: &str,
    exclude: &[String],
    conditions: bool,
) -> Result<PackageData, i32> {
    let sources = match crate::discover_sources(package_dir, source_root, spec_pattern, exclude) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("coverage-engine: {}", e);
            return Err(1);
        }
    };

    let mut next_id: u32 = 1;
    let mut files: Vec<FileData> = Vec::new();
    let mut parse_failures: Vec<(String, String)> = Vec::new();

    for sf in sources {
        let src = match std::fs::read_to_string(&sf.abs) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("coverage-engine: cannot read {}: {}", sf.abs.display(), e);
                return Err(1);
            }
        };
        if src.contains("--!tm-coverage-instrumented") {
            eprintln!(
                "coverage-engine: {} is already instrumented (marker present); refusing to re-instrument",
                sf.rel
            );
            return Err(1);
        }
        let ast = match parse::parse(&src) {
            Ok(a) => a,
            Err(errs) => {
                let msg = errs.iter().map(|e| e.to_string()).collect::<Vec<_>>().join("; ");
                parse_failures.push((sf.rel.clone(), msg));
                continue;
            }
        };
        let line_starts = parse::line_starts(&src);
        let probes = {
            let mut collector = Collector::new(&src, line_starts.clone(), sf.rel.clone(), next_id, conditions);
            collector.collect_ast(ast.nodes());
            next_id = collector.next_id();
            collector.probes
        };

        files.push(FileData {
            rel: sf.rel.clone(),
            sha256: parse::sha256_hex(src.as_bytes()),
            original_lines: parse::line_count(&src),
            line_starts,
            src,
            probes,
        });
    }

    if !parse_failures.is_empty() {
        eprintln!("coverage-engine: parse failures:");
        for (path, msg) in &parse_failures {
            eprintln!("  {}: {}", path, msg);
        }
        return Err(2);
    }

    Ok(PackageData { files, total_slots: next_id - 1 })
}

/// A source file discovered for analysis, path relative to package_dir.
pub struct SourceFile {
    pub abs: PathBuf,
    pub rel: String,
}

/// Environment gates: code the edit-mode Studio harness (run-in-roblox) cannot
/// reach, so an uncovered unit behind one reads as expected, not a test gap.
/// Detected by text scan (matches covaudit's proven approach).
const ENV_GATES: &[(&str, &str)] = &[
    (":IsRunning(", "RunService:IsRunning() is false in edit mode"),
    (":IsRunMode(", "RunService:IsRunMode() is false in edit mode"),
    (".Stepped:", "RunService.Stepped does not fire in edit mode"),
];

pub fn detect_gates(src: &str) -> Vec<crate::model::Gate> {
    let mut gates = Vec::new();
    for (idx, line) in src.lines().enumerate() {
        let line_no = idx + 1;
        for (marker, note) in ENV_GATES {
            if line.contains(marker) {
                gates.push(crate::model::Gate {
                    marker: marker.to_string(),
                    note: note.to_string(),
                    line: line_no,
                    scope: [line_no, line_no],
                });
            }
        }
    }
    gates
}
