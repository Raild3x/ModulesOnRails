//! Binary-level tests: subcommands, exit codes, and the map-sha contract.
//!
//! Exit codes under test: 0 ok, 1 IO/refusal, 2 source parse failure,
//! 3 instrumented-output verification failure.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn engine(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_coverage-engine"))
        .args(args)
        .output()
        .expect("engine binary should run")
}

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)
}

/// Fresh per-test scratch dir; fixtures must never be instrumented in place.
fn tmp(name: &str) -> PathBuf {
    let p = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    if p.exists() {
        std::fs::remove_dir_all(&p).unwrap();
    }
    std::fs::create_dir_all(&p).unwrap();
    p
}

fn path_arg(p: &Path) -> String {
    p.to_string_lossy().to_string()
}

fn instrument_simple_pkg(dir: &Path) -> (PathBuf, PathBuf) {
    let build = dir.join("build");
    let map = dir.join("map.json");
    let out = engine(&[
        "instrument",
        "--package-dir",
        &path_arg(&fixture("simple_pkg")),
        "--package-name",
        "simple_pkg",
        "--exclude",
        "src/_Index/**",
        "--out-dir",
        &path_arg(&build),
        "--map-out",
        &path_arg(&map),
    ]);
    assert_eq!(out.status.code(), Some(0), "stderr: {}", String::from_utf8_lossy(&out.stderr));
    (build, map)
}

#[test]
fn analyze_emits_a_valid_map() {
    let dir = tmp("cli_analyze");
    let map_path = dir.join("map.json");
    let out = engine(&[
        "analyze",
        "--package-dir",
        &path_arg(&fixture("simple_pkg")),
        "--package-name",
        "simple_pkg",
        "--exclude",
        "src/_Index/**",
        "--out",
        &path_arg(&map_path),
    ]);
    assert_eq!(out.status.code(), Some(0), "stderr: {}", String::from_utf8_lossy(&out.stderr));

    let map: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&map_path).unwrap()).unwrap();
    assert_eq!(map["schema"], "tm-coverage-map/1");
    assert_eq!(map["package"], "simple_pkg");
    assert_eq!(map["options"]["conditions"], true);

    let files = map["files"].as_array().unwrap();
    let paths: Vec<&str> = files.iter().map(|f| f["path"].as_str().unwrap()).collect();
    assert_eq!(paths, vec!["src/init.luau", "src/util/deep.luau"]);

    // total_slots covers exactly the highest slot any probe reserves.
    let max_slot = files
        .iter()
        .flat_map(|f| f["probes"].as_array().unwrap())
        .map(|p| {
            let id = p["id"].as_u64().unwrap();
            match p["kind"].as_str().unwrap() {
                "decision" | "cond" => id + 1,
                "loop" => id + 2,
                _ => id,
            }
        })
        .max()
        .unwrap();
    assert_eq!(map["total_slots"].as_u64().unwrap(), max_slot);

    // The fixture exercises gates and dead code; they must be picked up.
    let init = &files[0];
    assert!(!init["gates"].as_array().unwrap().is_empty(), "expected an env gate in init.luau");
    assert!(!init["dead"].as_array().unwrap().is_empty(), "expected dead code in init.luau");
}

#[test]
fn detect_const_is_opt_in_and_reports_candidates() {
    let dir = tmp("cli_detect_const");

    // Off (default): the map carries no const fields at all, so existing
    // consumers and the sha contract see byte-identical output.
    let map_path = dir.join("map.json");
    let out = engine(&[
        "analyze",
        "--package-dir",
        &path_arg(&fixture("simple_pkg")),
        "--exclude",
        "src/_Index/**",
        "--out",
        &path_arg(&map_path),
    ]);
    assert_eq!(out.status.code(), Some(0), "stderr: {}", String::from_utf8_lossy(&out.stderr));
    let map: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&map_path).unwrap()).unwrap();
    assert!(map["options"].get("detect_const").is_none());
    for f in map["files"].as_array().unwrap() {
        assert!(f.get("const_candidates").is_none(), "{} has const_candidates without the flag", f["path"]);
    }

    // On: exactly the never-reassigned declarations, in source order.
    let map_path = dir.join("map_const.json");
    let out = engine(&[
        "analyze",
        "--package-dir",
        &path_arg(&fixture("simple_pkg")),
        "--exclude",
        "src/_Index/**",
        "--detect-const",
        "--out",
        &path_arg(&map_path),
    ]);
    assert_eq!(out.status.code(), Some(0), "stderr: {}", String::from_utf8_lossy(&out.stderr));
    let map: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&map_path).unwrap()).unwrap();
    assert_eq!(map["options"]["detect_const"], true);

    let files = map["files"].as_array().unwrap();
    let init = files.iter().find(|f| f["path"] == "src/init.luau").unwrap();
    let candidates = init["const_candidates"].as_array().unwrap();
    let names: Vec<&str> = candidates.iter().map(|c| c["names"][0].as_str().unwrap()).collect();
    assert_eq!(names, vec!["M", "helper", "cb"]);
    let kinds: Vec<&str> = candidates.iter().map(|c| c["kind"].as_str().unwrap()).collect();
    assert_eq!(kinds, vec!["local", "local_function", "local"]);
    assert_eq!(candidates[0]["site"], "const:src/init.luau:4:1");

    let deep = files.iter().find(|f| f["path"] == "src/util/deep.luau").unwrap();
    let deep_names: Vec<&str> =
        deep["const_candidates"].as_array().unwrap().iter().map(|c| c["names"][0].as_str().unwrap()).collect();
    assert_eq!(deep_names, vec!["Deep"]);
}

#[test]
fn instrument_upholds_the_map_sha_contract() {
    let dir = tmp("cli_instrument");
    let (build, map) = instrument_simple_pkg(&dir);

    for rel in ["src/init.luau", "src/util/deep.luau"] {
        let body = std::fs::read_to_string(build.join(rel)).unwrap();
        assert!(body.contains("--!tm-coverage-instrumented"), "{} lacks the marker", rel);
    }
    // Excluded/spec files are copied but never instrumented.
    for rel in ["src/init.spec.luau", "src/_Index/vendor.luau"] {
        let body = std::fs::read_to_string(build.join(rel)).unwrap();
        assert!(!body.contains("--!tm-coverage-instrumented"), "{} must not be instrumented", rel);
    }

    // The runtime's embedded map_sha must hash the emitted map.json exactly.
    let cov = std::fs::read_to_string(build.join("src/_cov.luau")).unwrap();
    let sha_start = cov.find("map_sha = \"").unwrap() + "map_sha = \"".len();
    let sha_end = cov[sha_start..].find('"').unwrap() + sha_start;
    let embedded = &cov[sha_start..sha_end];

    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(std::fs::read(&map).unwrap());
    let expected = format!("{:x}", h.finalize());
    assert_eq!(embedded, expected);
}

#[test]
fn reinstrumenting_an_instrumented_copy_is_refused() {
    let dir = tmp("cli_reinstrument");
    let (build, _) = instrument_simple_pkg(&dir);

    let out = engine(&[
        "instrument",
        "--package-dir",
        &path_arg(&build),
        "--out-dir",
        &path_arg(&dir.join("build2")),
        "--map-out",
        &path_arg(&dir.join("map2.json")),
    ]);
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).contains("already instrumented"));
}

#[test]
fn instrumented_marker_fixture_is_refused_by_analyze_too() {
    let dir = tmp("cli_marker");
    let out = engine(&[
        "analyze",
        "--package-dir",
        &path_arg(&fixture("instrumented_pkg")),
        "--out",
        &path_arg(&dir.join("map.json")),
    ]);
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).contains("already instrumented"));
}

#[test]
fn mutate_emits_a_valid_mutants_doc() {
    let dir = tmp("cli_mutate");
    let out_path = dir.join("mutants.json");
    let out = engine(&[
        "mutate",
        "--package-dir",
        &path_arg(&fixture("simple_pkg")),
        "--package-name",
        "simple_pkg",
        "--exclude",
        "src/_Index/**",
        "--out",
        &path_arg(&out_path),
    ]);
    assert_eq!(out.status.code(), Some(0), "stderr: {}", String::from_utf8_lossy(&out.stderr));

    let doc: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&out_path).unwrap()).unwrap();
    assert_eq!(doc["schema"], "tm-coverage-mutants/1");
    assert_eq!(doc["package"], "simple_pkg");

    let files = doc["files"].as_array().unwrap();
    let paths: Vec<&str> = files.iter().map(|f| f["path"].as_str().unwrap()).collect();
    assert_eq!(paths, vec!["src/init.luau", "src/util/deep.luau"]);

    // Dense ids across files, total matching the last id.
    let all: Vec<u64> = files
        .iter()
        .flat_map(|f| f["mutants"].as_array().unwrap())
        .map(|m| m["id"].as_u64().unwrap())
        .collect();
    assert!(!all.is_empty());
    assert_eq!(all, (1..=all.len() as u64).collect::<Vec<_>>());
    assert_eq!(doc["total"].as_u64().unwrap(), all.len() as u64);

    // Every mutant's span slices its file to exactly the original text.
    for f in files {
        let src = std::fs::read_to_string(fixture("simple_pkg").join(f["path"].as_str().unwrap())).unwrap();
        for m in f["mutants"].as_array().unwrap() {
            let (s, e) = (m["byte_start"].as_u64().unwrap() as usize, m["byte_end"].as_u64().unwrap() as usize);
            assert_eq!(&src[s..e], m["original"].as_str().unwrap(), "span of {}", m["site"]);
        }
    }
}

#[test]
fn apply_mutant_round_trips_and_guards_against_staleness() {
    let dir = tmp("cli_apply_mutant");
    // Work on a copy: apply mutates in place.
    let root = dir.join("pkg");
    copy_fixture(&fixture("simple_pkg"), &root);
    let mutants_path = dir.join("mutants.json");
    let out = engine(&[
        "mutate",
        "--package-dir",
        &path_arg(&root),
        "--exclude",
        "src/_Index/**",
        "--out",
        &path_arg(&mutants_path),
    ]);
    assert_eq!(out.status.code(), Some(0));

    let doc: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&mutants_path).unwrap()).unwrap();
    let file = &doc["files"][0];
    let rel = file["path"].as_str().unwrap();
    let mutant = &file["mutants"][0];
    let id = mutant["id"].as_u64().unwrap().to_string();

    let pristine = std::fs::read_to_string(root.join(rel)).unwrap();
    let out = engine(&["apply-mutant", "--mutants", &path_arg(&mutants_path), "--id", &id, "--root", &path_arg(&root)]);
    assert_eq!(out.status.code(), Some(0), "stderr: {}", String::from_utf8_lossy(&out.stderr));

    // The file changed at exactly the mutant span and still parses (the engine
    // verified the reparse before writing).
    let mutated = std::fs::read_to_string(root.join(rel)).unwrap();
    assert_ne!(mutated, pristine);
    let (s, e) = (
        mutant["byte_start"].as_u64().unwrap() as usize,
        mutant["byte_end"].as_u64().unwrap() as usize,
    );
    assert_eq!(&mutated[s..s + mutant["replacement"].as_str().unwrap().len()], mutant["replacement"].as_str().unwrap());
    assert_eq!(&mutated[..s], &pristine[..s]);
    assert_eq!(&mutated[s + mutant["replacement"].as_str().unwrap().len()..], &pristine[e..]);

    // Applying again without restoring: the sha no longer matches -> exit 1.
    let out = engine(&["apply-mutant", "--mutants", &path_arg(&mutants_path), "--id", &id, "--root", &path_arg(&root)]);
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).contains("sha mismatch"));

    // Restoring the pristine bytes makes it applicable again.
    std::fs::write(root.join(rel), &pristine).unwrap();
    let out = engine(&["apply-mutant", "--mutants", &path_arg(&mutants_path), "--id", &id, "--root", &path_arg(&root)]);
    assert_eq!(out.status.code(), Some(0));

    // An unknown id -> exit 1.
    std::fs::write(root.join(rel), &pristine).unwrap();
    let out = engine(&["apply-mutant", "--mutants", &path_arg(&mutants_path), "--id", "999999", "--root", &path_arg(&root)]);
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).contains("no mutant with id"));
}

#[test]
fn mutate_refuses_an_instrumented_tree() {
    let dir = tmp("cli_mutate_instrumented");
    let (build, _) = instrument_simple_pkg(&dir);
    let out = engine(&[
        "mutate",
        "--package-dir",
        &path_arg(&build),
        "--exclude",
        "src/_Index/**",
        "--out",
        &path_arg(&dir.join("mutants.json")),
    ]);
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).contains("instrumented"));
}

fn copy_fixture(from: &Path, to: &Path) {
    for entry in walk(from) {
        let rel = entry.strip_prefix(from).unwrap();
        let dest = to.join(rel);
        std::fs::create_dir_all(dest.parent().unwrap()).unwrap();
        std::fs::copy(&entry, &dest).unwrap();
    }
}

fn walk(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            out.extend(walk(&path));
        } else {
            out.push(path);
        }
    }
    out
}

#[test]
fn parse_failures_exit_2() {
    let dir = tmp("cli_bad_parse");
    let out = engine(&[
        "analyze",
        "--package-dir",
        &path_arg(&fixture("bad_parse_pkg")),
        "--out",
        &path_arg(&dir.join("map.json")),
    ]);
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("parse failures"));
}

#[test]
fn verify_passes_on_a_fresh_copy_and_fails_on_a_corrupted_one() {
    let dir = tmp("cli_verify");
    let (build, map) = instrument_simple_pkg(&dir);
    let original = path_arg(&fixture("simple_pkg"));

    let out = engine(&["verify", "--map", &path_arg(&map), "--original", &original, "--instrumented", &path_arg(&build)]);
    assert_eq!(out.status.code(), Some(0), "stderr: {}", String::from_utf8_lossy(&out.stderr));

    // Strip the header (marker + runtime binding) from one file: exit 3.
    let target = build.join("src/init.luau");
    let body = std::fs::read_to_string(&target).unwrap();
    let stripped = body.splitn(2, '\n').nth(1).unwrap().to_string();
    std::fs::write(&target, stripped).unwrap();
    let out = engine(&["verify", "--map", &path_arg(&map), "--original", &original, "--instrumented", &path_arg(&build)]);
    assert_eq!(out.status.code(), Some(3));

    // A map that references files the copy lacks: exit 3.
    let empty = dir.join("empty");
    std::fs::create_dir_all(&empty).unwrap();
    let out = engine(&["verify", "--map", &path_arg(&map), "--original", &original, "--instrumented", &path_arg(&empty)]);
    assert_eq!(out.status.code(), Some(3));
}
