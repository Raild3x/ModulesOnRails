---
name: coverage-engine
description: Work on the coverage system itself under tools/coverage (Rust full_moon engine or Lune orchestrator). Use when modifying instrumentation, probes, mutation testing, the report, adapters, or when golden tests fail. Covers building, testing, golden regeneration, and layout boundaries.
---

# Working on tools/coverage

Read `tools/coverage/README.md` first — it is the authoritative architecture
doc (probe model, sentinel protocol, mutation semantics).

## Layout boundary (load-bearing)

- `engine/` (Rust) and `lune/core/` are **repo-agnostic**: nothing there may
  hardcode `lib/`, `_Index`, or `.spec.luau`. Layout knowledge lives only in
  `lune/adapters/modules_on_rails.luau` (this repo) behind the `RepoAdapter`
  interface in `lune/adapter.luau`.
- The engine instruments by **pure text insertion** — existing bytes are never
  modified. Keep that invariant; byte offsets and file hashes depend on it.

## Build & test

```sh
cd tools/coverage/engine && cargo build --release   # or --rebuild-engine on a run
cd tools/coverage/engine && cargo test              # unit + CLI + golden tests
lune run coverage.luau package=self --adapter=./tools/coverage/lune/adapters/coverage_self  # Lune core specs (from repo root)
```

Build/test **release**, not dev: `full_moon` recurses deeply and can overflow
the stack in the dev profile.

## Golden tests

`engine/tests/golden/` pins exact `map.json` + instrumented output for
`engine/tests/fixtures/simple_pkg`. Any intentional change to probe collection,
id allocation, site keys, or splicing requires regeneration + diff review:

```powershell
$env:UPDATE_GOLDEN = "1"; cargo test --test golden; Remove-Item Env:UPDATE_GOLDEN
git diff tests/golden/
```

Fixtures and goldens are pinned to **LF** via `.gitattributes` — never reformat
or re-encode anything under `engine/tests/fixtures/` or `golden/`.

## Runtime gotchas

- Lune 0.10.4 cannot parse `const`; that's why const-using packages route to
  the Studio pipeline. Don't add `const` to `lune/` sources.
- Studio results come back via the base64 stdout sentinel protocol
  (`[[TM-COV ...]]` lines in the adapter's runner template) — base64 is
  load-bearing (UTF-8 byte-slicing hazard), don't "simplify" it.
- Mutation runs each mutant in a fresh child Lune process (`lune/mutant_run.luau`);
  a stop file `.coverage/<pkg>/mutation.stop` ends a run early keeping partials.
