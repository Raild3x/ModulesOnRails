//! coverage-engine — AST-based Luau coverage instrumentation engine.
//!
//! Repo-agnostic: all layout conventions (source root, spec pattern, excludes)
//! arrive as flags derived from the orchestrator's per-package spec.

mod collect;
mod instrument;
mod model;
mod mutate;
mod parse;
mod pipeline;
mod scopes;

use clap::{Parser, Subcommand};
use std::path::{Path, PathBuf};
use std::process::exit;

use model::{CoverageMap, FileMap, MapOptions, ENGINE_VERSION, MAP_SCHEMA};
use pipeline::{collect_package, PackageData, SourceFile};

#[derive(Parser)]
#[command(name = "coverage-engine", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Static analysis only: emit map.json (no instrumentation).
    Analyze {
        #[arg(long)]
        package_dir: PathBuf,
        #[arg(long)]
        package_name: Option<String>,
        #[arg(long, default_value = "src")]
        source_root: String,
        #[arg(long, default_value = r"\.spec\.luau$")]
        spec_pattern: String,
        #[arg(long)]
        exclude: Vec<String>,
        #[arg(long)]
        out: PathBuf,
        #[arg(long, default_value_t = false)]
        no_conditions: bool,
        /// Also report `local`s never reassigned that could be `const`.
        #[arg(long, default_value_t = false)]
        detect_const: bool,
    },
    /// Instrument a package (in place, or into --out-dir) and emit map.json.
    Instrument {
        #[arg(long)]
        package_dir: PathBuf,
        #[arg(long)]
        package_name: Option<String>,
        #[arg(long, default_value = "src")]
        source_root: String,
        #[arg(long, default_value = r"\.spec\.luau$")]
        spec_pattern: String,
        #[arg(long)]
        exclude: Vec<String>,
        /// If set, copy the package here first and instrument the copy.
        #[arg(long)]
        out_dir: Option<PathBuf>,
        #[arg(long)]
        map_out: PathBuf,
        #[arg(long, default_value_t = false)]
        no_conditions: bool,
        /// Also report `local`s never reassigned that could be `const`.
        #[arg(long, default_value_t = false)]
        detect_const: bool,
    },
    /// Re-parse an instrumented copy and check structural integrity.
    Verify {
        #[arg(long)]
        map: PathBuf,
        #[arg(long)]
        original: PathBuf,
        #[arg(long)]
        instrumented: PathBuf,
    },
    /// Enumerate mutation sites from uninstrumented sources into mutants.json.
    Mutate {
        #[arg(long)]
        package_dir: PathBuf,
        #[arg(long)]
        package_name: Option<String>,
        #[arg(long, default_value = "src")]
        source_root: String,
        #[arg(long, default_value = r"\.spec\.luau$")]
        spec_pattern: String,
        #[arg(long)]
        exclude: Vec<String>,
        #[arg(long)]
        out: PathBuf,
    },
    /// Apply one mutant from mutants.json in place under --root.
    ApplyMutant {
        #[arg(long)]
        mutants: PathBuf,
        #[arg(long)]
        id: u32,
        #[arg(long)]
        root: PathBuf,
    },
}

fn main() {
    let cli = Cli::parse();
    let code = match cli.command {
        Command::Analyze {
            package_dir,
            package_name,
            source_root,
            spec_pattern,
            exclude,
            out,
            no_conditions,
            detect_const,
        } => run_analyze(
            &package_dir,
            package_name,
            &source_root,
            &spec_pattern,
            &exclude,
            &out,
            !no_conditions,
            detect_const,
        ),
        Command::Instrument {
            package_dir,
            package_name,
            source_root,
            spec_pattern,
            exclude,
            out_dir,
            map_out,
            no_conditions,
            detect_const,
        } => run_instrument(
            &package_dir,
            package_name,
            &source_root,
            &spec_pattern,
            &exclude,
            out_dir.as_deref(),
            &map_out,
            !no_conditions,
            detect_const,
        ),
        Command::Verify { map, original, instrumented } => run_verify(&map, &original, &instrumented),
        Command::Mutate {
            package_dir,
            package_name,
            source_root,
            spec_pattern,
            exclude,
            out,
        } => run_mutate(&package_dir, package_name, &source_root, &spec_pattern, &exclude, &out),
        Command::ApplyMutant { mutants, id, root } => run_apply_mutant(&mutants, id, &root),
    };
    exit(code);
}

fn package_name_or_dir(package_dir: &Path, package_name: Option<String>) -> String {
    package_name.unwrap_or_else(|| {
        package_dir
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "unknown".to_string())
    })
}

fn run_mutate(
    package_dir: &Path,
    package_name: Option<String>,
    source_root: &str,
    spec_pattern: &str,
    exclude: &[String],
    out: &Path,
) -> i32 {
    let sources = match discover_sources(package_dir, source_root, spec_pattern, exclude) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("coverage-engine: {}", e);
            return 1;
        }
    };

    let mut files: Vec<mutate::MutantFile> = Vec::new();
    let mut next_id: u32 = 1;
    let mut parse_failures: Vec<(String, String)> = Vec::new();
    for sf in sources {
        let src = match std::fs::read_to_string(&sf.abs) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("coverage-engine: cannot read {}: {}", sf.abs.display(), e);
                return 1;
            }
        };
        if src.contains("--!tm-coverage-instrumented") {
            eprintln!(
                "coverage-engine: {} is instrumented (marker present); mutate targets pristine sources",
                sf.rel
            );
            return 1;
        }
        let ast = match parse::parse(&src) {
            Ok(a) => a,
            Err(errs) => {
                let msg = errs.iter().map(|e| e.to_string()).collect::<Vec<_>>().join("; ");
                parse_failures.push((sf.rel.clone(), msg));
                continue;
            }
        };
        let (mutants, next) = mutate::collect_file(ast.nodes(), &sf.rel, next_id);
        next_id = next;
        files.push(mutate::MutantFile {
            path: sf.rel,
            sha256: parse::sha256_hex(src.as_bytes()),
            mutants,
        });
    }
    if !parse_failures.is_empty() {
        eprintln!("coverage-engine: parse failures:");
        for (path, msg) in &parse_failures {
            eprintln!("  {}: {}", path, msg);
        }
        return 2;
    }

    let doc = mutate::MutantsDoc {
        schema: mutate::MUTANTS_SCHEMA.to_string(),
        engine_version: ENGINE_VERSION.to_string(),
        package: package_name_or_dir(package_dir, package_name),
        total: next_id - 1,
        files,
    };
    let json = match serde_json::to_string_pretty(&doc) {
        Ok(j) => j,
        Err(e) => {
            eprintln!("coverage-engine: serialize error: {}", e);
            return 1;
        }
    };
    if let Some(parent) = out.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            eprintln!("coverage-engine: cannot create {}: {}", parent.display(), e);
            return 1;
        }
    }
    if let Err(e) = std::fs::write(out, &json) {
        eprintln!("coverage-engine: cannot write {}: {}", out.display(), e);
        return 1;
    }
    eprintln!(
        "coverage-engine: enumerated {} mutant(s) across {} file(s) -> {}",
        doc.total,
        doc.files.len(),
        out.display()
    );
    0
}

fn run_apply_mutant(mutants_path: &Path, id: u32, root: &Path) -> i32 {
    let raw = match std::fs::read_to_string(mutants_path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("coverage-engine: cannot read {}: {}", mutants_path.display(), e);
            return 1;
        }
    };
    let doc: mutate::MutantsDoc = match serde_json::from_str(&raw) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("coverage-engine: bad mutants json: {}", e);
            return 1;
        }
    };
    if doc.schema != mutate::MUTANTS_SCHEMA {
        eprintln!("coverage-engine: unexpected mutants schema {:?}", doc.schema);
        return 1;
    }
    match mutate::apply(&doc, id, root) {
        Ok(rel) => {
            eprintln!("coverage-engine: applied mutant {} to {}", id, rel);
            0
        }
        Err((code, msg)) => {
            eprintln!("coverage-engine: {}", msg);
            code
        }
    }
}

fn build_map(
    package_dir: &Path,
    package_name: Option<String>,
    conditions: bool,
    detect_const: bool,
    data: &PackageData,
) -> CoverageMap {
    let package = package_name_or_dir(package_dir, package_name);
    let files = data
        .files
        .iter()
        .map(|f| FileMap {
            path: f.rel.clone(),
            sha256: f.sha256.clone(),
            original_lines: f.original_lines,
            probes: f.probes.clone(),
            gates: f.gates.clone(),
            dead: f.dead.clone(),
            const_candidates: f.const_candidates.clone(),
        })
        .collect();
    CoverageMap {
        schema: MAP_SCHEMA,
        engine_version: ENGINE_VERSION,
        package,
        package_dir: package_dir.to_string_lossy().replace('\\', "/"),
        generated_at: unix_secs(),
        options: MapOptions { conditions, detect_const },
        total_slots: data.total_slots,
        files,
    }
}

fn write_json(map: &CoverageMap, out: &Path) -> Result<String, i32> {
    let json = serde_json::to_string_pretty(map).map_err(|e| {
        eprintln!("coverage-engine: serialize error: {}", e);
        1
    })?;
    if let Some(parent) = out.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            eprintln!("coverage-engine: cannot create {}: {}", parent.display(), e);
            return Err(1);
        }
    }
    if let Err(e) = std::fs::write(out, &json) {
        eprintln!("coverage-engine: cannot write {}: {}", out.display(), e);
        return Err(1);
    }
    Ok(json)
}

fn run_analyze(
    package_dir: &Path,
    package_name: Option<String>,
    source_root: &str,
    spec_pattern: &str,
    exclude: &[String],
    out: &Path,
    conditions: bool,
    detect_const: bool,
) -> i32 {
    let data = match collect_package(package_dir, source_root, spec_pattern, exclude, conditions, detect_const) {
        Ok(d) => d,
        Err(code) => return code,
    };
    let map = build_map(package_dir, package_name, conditions, detect_const, &data);
    if write_json(&map, out).is_err() {
        return 1;
    }
    eprintln!(
        "coverage-engine: analyzed {} file(s), {} probe(s) -> {}",
        map.files.len(),
        map.total_slots,
        out.display()
    );
    0
}

fn run_instrument(
    package_dir: &Path,
    package_name: Option<String>,
    source_root: &str,
    spec_pattern: &str,
    exclude: &[String],
    out_dir: Option<&Path>,
    map_out: &Path,
    conditions: bool,
    detect_const: bool,
) -> i32 {
    let data = match collect_package(package_dir, source_root, spec_pattern, exclude, conditions, detect_const) {
        Ok(d) => d,
        Err(code) => return code,
    };

    // Target dir: either a fresh copy (out_dir) or the package dir in place.
    let target: PathBuf = match out_dir {
        Some(dir) => {
            if let Err(e) = copy_tree(package_dir, dir) {
                eprintln!("coverage-engine: copy failed: {}", e);
                return 1;
            }
            dir.to_path_buf()
        }
        None => package_dir.to_path_buf(),
    };

    // map.json must be byte-identical to what we hash into _cov.luau.
    let map = build_map(package_dir, package_name, conditions, detect_const, &data);
    let json = match serde_json::to_string_pretty(&map) {
        Ok(j) => j,
        Err(e) => {
            eprintln!("coverage-engine: serialize error: {}", e);
            return 1;
        }
    };
    let map_sha = parse::sha256_hex(json.as_bytes());

    // Splice + header + in-line verify each file.
    for f in &data.files {
        let spliced = instrument::splice_file(&f.src, &f.probes, &f.line_starts);
        let cov_path = instrument::cov_require_path(&f.rel, source_root);
        let body = format!("{}{}", instrument::header_line(&cov_path), spliced);

        if let Err(errs) = parse::parse(&body) {
            eprintln!("coverage-engine: instrumented {} does not parse (verify failed):", f.rel);
            for e in errs.iter().take(3) {
                eprintln!("  {}", e);
            }
            if std::env::var("COV_DUMP_BROKEN").is_ok() {
                let dump = target.join(format!("{}.broken", f.rel));
                if let Some(parent) = dump.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                let _ = std::fs::write(&dump, &body);
                eprintln!("  (dumped to {})", dump.display());
            }
            return 3;
        }

        let dest = target.join(&f.rel);
        if let Some(parent) = dest.parent() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                eprintln!("coverage-engine: cannot create {}: {}", parent.display(), e);
                return 1;
            }
        }
        if let Err(e) = std::fs::write(&dest, body) {
            eprintln!("coverage-engine: cannot write {}: {}", dest.display(), e);
            return 1;
        }
    }

    // Emit the runtime module at <target>/<source_root>/_cov.luau.
    let cov_path = target.join(source_root).join("_cov.luau");
    if let Err(e) = std::fs::write(&cov_path, instrument::cov_module(data.total_slots, &map_sha)) {
        eprintln!("coverage-engine: cannot write {}: {}", cov_path.display(), e);
        return 1;
    }

    if write_json(&map, map_out).is_err() {
        return 1;
    }
    eprintln!(
        "coverage-engine: instrumented {} file(s), {} probe(s) -> {} (map: {})",
        data.files.len(),
        data.total_slots,
        target.display(),
        map_out.display()
    );
    0
}

fn run_verify(map_path: &Path, _original: &Path, instrumented: &Path) -> i32 {
    let raw = match std::fs::read_to_string(map_path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("coverage-engine: cannot read map {}: {}", map_path.display(), e);
            return 1;
        }
    };
    let json: serde_json::Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("coverage-engine: bad map json: {}", e);
            return 1;
        }
    };
    let files = json.get("files").and_then(|f| f.as_array());
    let files = match files {
        Some(f) => f,
        None => {
            eprintln!("coverage-engine: map has no files array");
            return 1;
        }
    };
    let mut problems = 0;
    for file in files {
        let rel = file.get("path").and_then(|p| p.as_str()).unwrap_or("");
        let path = instrumented.join(rel);
        let body = match std::fs::read_to_string(&path) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("coverage-engine: verify: cannot read {}: {}", path.display(), e);
                problems += 1;
                continue;
            }
        };
        if !body.contains("--!tm-coverage-instrumented") {
            eprintln!("coverage-engine: verify: {} lacks instrumentation marker", rel);
            problems += 1;
        }
        if let Err(errs) = parse::parse(&body) {
            eprintln!("coverage-engine: verify: {} does not parse:", rel);
            for e in errs.iter().take(2) {
                eprintln!("    {}", e);
            }
            problems += 1;
            continue;
        }
        if let Some(probes) = file.get("probes").and_then(|p| p.as_array()) {
            for probe in probes {
                if let Some(id) = probe.get("id").and_then(|i| i.as_u64()) {
                    if !body.contains(&format!("({}", id)) {
                        eprintln!("coverage-engine: verify: {} missing probe id {}", rel, id);
                        problems += 1;
                    }
                }
            }
        }
    }
    if problems > 0 {
        eprintln!("coverage-engine: verify failed with {} problem(s)", problems);
        return 3;
    }
    eprintln!("coverage-engine: verify OK ({} file(s))", files.len());
    0
}

/// Recursively copy a directory tree.
fn copy_tree(from: &Path, to: &Path) -> std::io::Result<()> {
    if to.exists() {
        std::fs::remove_dir_all(to)?;
    }
    for entry in walkdir::WalkDir::new(from) {
        let entry = entry?;
        let rel = entry.path().strip_prefix(from).unwrap();
        let dest = to.join(rel);
        if entry.file_type().is_dir() {
            std::fs::create_dir_all(&dest)?;
        } else if entry.file_type().is_file() {
            if let Some(parent) = dest.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::copy(entry.path(), &dest)?;
        }
    }
    Ok(())
}

/// Walks `<package_dir>/<source_root>` for `.luau` files, dropping spec files
/// (matched by `spec_pattern`) and `--exclude` globs. Paths are relative to
/// `package_dir` with forward slashes.
pub fn discover_sources(
    package_dir: &Path,
    source_root: &str,
    spec_pattern: &str,
    exclude: &[String],
) -> Result<Vec<SourceFile>, String> {
    let root = package_dir.join(source_root);
    if !root.is_dir() {
        return Err(format!("source root not found: {}", root.display()));
    }
    let spec_re = simple_regex(spec_pattern);
    let mut out = Vec::new();
    for entry in walkdir::WalkDir::new(&root).sort_by_file_name() {
        let entry = entry.map_err(|e| e.to_string())?;
        if !entry.file_type().is_file() {
            continue;
        }
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("luau") {
            continue;
        }
        let rel = match path.strip_prefix(package_dir) {
            Ok(r) => r.to_string_lossy().replace('\\', "/"),
            Err(_) => continue,
        };
        let name = path.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
        if spec_re.matches(&name) {
            continue;
        }
        if exclude.iter().any(|g| glob_match(g, &rel)) {
            continue;
        }
        out.push(SourceFile { abs: path.to_path_buf(), rel });
    }
    out.sort_by(|a, b| a.rel.cmp(&b.rel));
    Ok(out)
}

fn unix_secs() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs().to_string())
        .unwrap_or_else(|_| "0".to_string())
}

/// Minimal matcher for the tail-anchored patterns we pass (`\.spec\.luau$`).
struct SimpleRegex {
    needle: String,
    anchored_end: bool,
}
fn simple_regex(pat: &str) -> SimpleRegex {
    let anchored_end = pat.ends_with('$');
    let body = pat.trim_end_matches('$');
    let needle = body.replace(r"\.", ".").replace('\\', "");
    SimpleRegex { needle, anchored_end }
}
impl SimpleRegex {
    fn matches(&self, s: &str) -> bool {
        if self.anchored_end {
            s.ends_with(&self.needle)
        } else {
            s.contains(&self.needle)
        }
    }
}

/// Glob matcher supporting `**` (any path segments), `*` (within a segment).
fn glob_match(pattern: &str, path: &str) -> bool {
    fn helper(p: &[u8], s: &[u8]) -> bool {
        if p.is_empty() {
            return s.is_empty();
        }
        if p.starts_with(b"**") {
            let rest = &p[2..];
            let rest = rest.strip_prefix(b"/").unwrap_or(rest);
            if helper(rest, s) {
                return true;
            }
            for i in 0..s.len() {
                if helper(rest, &s[i + 1..]) {
                    return true;
                }
            }
            return helper(rest, &[]);
        }
        match p[0] {
            b'*' => {
                if helper(&p[1..], s) {
                    return true;
                }
                if !s.is_empty() && s[0] != b'/' {
                    return helper(p, &s[1..]);
                }
                false
            }
            c => {
                if !s.is_empty() && s[0] == c {
                    helper(&p[1..], &s[1..])
                } else {
                    false
                }
            }
        }
    }
    helper(pattern.as_bytes(), path.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn simple_regex_tail_anchored_matches_suffix_only() {
        let re = simple_regex(r"\.spec\.luau$");
        assert!(re.matches("x.spec.luau"));
        assert!(re.matches("nested.name.spec.luau"));
        assert!(!re.matches("x.spec.luau.bak"));
        assert!(!re.matches("x.luau"));
    }

    #[test]
    fn simple_regex_unanchored_falls_back_to_contains() {
        let re = simple_regex("spec");
        assert!(re.matches("myspecfile.luau"));
        assert!(!re.matches("plain.luau"));
    }

    #[test]
    fn glob_double_star_crosses_path_segments() {
        assert!(glob_match("src/_Index/**", "src/_Index/x.luau"));
        assert!(glob_match("src/_Index/**", "src/_Index/a/b.luau"));
        assert!(!glob_match("src/_Index/**", "src/other/x.luau"));
        assert!(glob_match("**/x.luau", "a/b/x.luau"));
    }

    #[test]
    fn glob_single_star_stays_within_a_segment() {
        assert!(glob_match("src/*.luau", "src/a.luau"));
        assert!(!glob_match("src/*.luau", "src/a/b.luau"));
    }

    #[test]
    fn glob_literal_patterns_match_exactly() {
        assert!(glob_match("src/a.luau", "src/a.luau"));
        assert!(!glob_match("src/a.luau", "src/b.luau"));
    }

    #[test]
    fn discover_sources_drops_specs_excludes_and_non_luau() {
        let pkg = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/simple_pkg");
        let found = discover_sources(&pkg, "src", r"\.spec\.luau$", &["src/_Index/**".to_string()]).unwrap();
        let rels: Vec<&str> = found.iter().map(|f| f.rel.as_str()).collect();
        assert_eq!(rels, vec!["src/init.luau", "src/util/deep.luau"]);
    }

    #[test]
    fn discover_sources_errors_on_a_missing_source_root() {
        let pkg = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/simple_pkg");
        let err = discover_sources(&pkg, "no_such_root", r"\.spec\.luau$", &[]).err().unwrap();
        assert!(err.contains("source root not found"));
    }
}
