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
    pub gates: Vec<crate::model::Gate>,
    pub dead: Vec<crate::model::Dead>,
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
        let (probes, gates, dead) = {
            let mut collector = Collector::new(&src, line_starts.clone(), sf.rel.clone(), next_id, conditions);
            collector.collect_ast(ast.nodes());
            next_id = collector.next_id();
            (collector.probes, collector.gates, collector.dead)
        };

        files.push(FileData {
            rel: sf.rel.clone(),
            sha256: parse::sha256_hex(src.as_bytes()),
            original_lines: parse::line_count(&src),
            line_starts,
            src,
            probes,
            gates,
            dead,
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
