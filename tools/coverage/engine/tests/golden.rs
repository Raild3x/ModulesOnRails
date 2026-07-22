//! Golden-file drift alarm: any change to probe collection, ids, sites, or
//! splice output against the representative fixture package fails here with a
//! full diff. Intentional changes: regenerate with UPDATE_GOLDEN=1 and review
//! the git diff of tests/golden/ before committing.

use std::path::{Path, PathBuf};
use std::process::Command;

fn fixture_pkg() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/simple_pkg")
}

fn tmp(name: &str) -> PathBuf {
    let p = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    if p.exists() {
        std::fs::remove_dir_all(&p).unwrap();
    }
    std::fs::create_dir_all(&p).unwrap();
    p
}

fn engine(args: &[&str]) {
    let out = Command::new(env!("CARGO_BIN_EXE_coverage-engine"))
        .args(args)
        .output()
        .expect("engine binary should run");
    assert_eq!(out.status.code(), Some(0), "stderr: {}", String::from_utf8_lossy(&out.stderr));
}

/// Compares CRLF-normalized `actual` against the golden file, or rewrites the
/// golden when UPDATE_GOLDEN is set.
fn assert_golden(actual: &str, golden_rel: &str) {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/golden").join(golden_rel);
    let actual = actual.replace("\r\n", "\n");
    if std::env::var("UPDATE_GOLDEN").is_ok() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, actual.as_bytes()).unwrap();
        return;
    }
    let expected = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read golden {}: {} (create it with UPDATE_GOLDEN=1)", path.display(), e))
        .replace("\r\n", "\n");
    assert_eq!(
        actual, expected,
        "golden mismatch for {golden_rel}; if the change is intentional, regenerate with UPDATE_GOLDEN=1 and review the diff"
    );
}

#[test]
fn map_json_matches_golden() {
    let dir = tmp("golden_map");
    let map_path = dir.join("map.json");
    engine(&[
        "analyze",
        "--package-dir",
        &fixture_pkg().to_string_lossy(),
        "--package-name",
        "simple_pkg",
        "--exclude",
        "src/_Index/**",
        "--out",
        &map_path.to_string_lossy(),
    ]);

    let mut map: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&map_path).unwrap()).unwrap();
    // Mask the two nondeterministic fields (timestamp, absolute path).
    map["generated_at"] = "0".into();
    map["package_dir"] = "<fixture>".into();
    let pretty = serde_json::to_string_pretty(&map).unwrap() + "\n";
    assert_golden(&pretty, "simple_pkg.map.json");
}

#[test]
fn map_json_with_const_detection_matches_golden() {
    let dir = tmp("golden_map_const");
    let map_path = dir.join("map.json");
    engine(&[
        "analyze",
        "--package-dir",
        &fixture_pkg().to_string_lossy(),
        "--package-name",
        "simple_pkg",
        "--exclude",
        "src/_Index/**",
        "--detect-const",
        "--out",
        &map_path.to_string_lossy(),
    ]);

    let mut map: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&map_path).unwrap()).unwrap();
    map["generated_at"] = "0".into();
    map["package_dir"] = "<fixture>".into();
    let pretty = serde_json::to_string_pretty(&map).unwrap() + "\n";
    assert_golden(&pretty, "simple_pkg.map.const.json");
}

#[test]
fn mutants_json_matches_golden() {
    let dir = tmp("golden_mutants");
    let out_path = dir.join("mutants.json");
    engine(&[
        "mutate",
        "--package-dir",
        &fixture_pkg().to_string_lossy(),
        "--package-name",
        "simple_pkg",
        "--exclude",
        "src/_Index/**",
        "--out",
        &out_path.to_string_lossy(),
    ]);
    let pretty = std::fs::read_to_string(&out_path).unwrap() + "\n";
    assert_golden(&pretty, "simple_pkg.mutants.json");
}

#[test]
fn instrumented_output_matches_golden() {
    let dir = tmp("golden_instrument");
    let build = dir.join("build");
    engine(&[
        "instrument",
        "--package-dir",
        &fixture_pkg().to_string_lossy(),
        "--package-name",
        "simple_pkg",
        "--exclude",
        "src/_Index/**",
        "--out-dir",
        &build.to_string_lossy(),
        "--map-out",
        &dir.join("map.json").to_string_lossy(),
    ]);

    for rel in ["src/init.luau", "src/util/deep.luau"] {
        let body = std::fs::read_to_string(build.join(rel)).unwrap();
        assert_golden(&body, &format!("instrumented/{}", rel));
    }

    // The runtime module embeds the map sha; mask it (its correctness is
    // pinned by the cli.rs sha-contract test).
    let cov = std::fs::read_to_string(build.join("src/_cov.luau")).unwrap();
    let masked = mask_sha(&cov);
    assert_golden(&masked, "instrumented/src/_cov.luau");
}

fn mask_sha(cov: &str) -> String {
    let needle = "map_sha = \"";
    let start = cov.find(needle).expect("_cov.luau should embed map_sha") + needle.len();
    let end = cov[start..].find('"').unwrap() + start;
    format!("{}<SHA>{}", &cov[..start], &cov[end..])
}
