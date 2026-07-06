---
name: test-package
description: Run tests and coverage for a package in this repo. Use when asked to run tests, check coverage, run the test suite, or verify a package's specs pass. Covers command forms, flags, pipeline selection (Lune vs Roblox Studio), and reading the output.
---

# Running tests for a package

The test runner IS the coverage tool. Always run from the repo root:

```sh
lune run coverage.luau package=<name>    # e.g. package=tablemanager
lune run coverage.luau package=all       # every lib/ package with specs
lune run coverage.luau package=last      # reads test/last_tested_package.txt
```

`<name>` is a directory name under `lib/`. `tests.luau` no longer exists — do
not try to run it. To test the coverage tool's own Lune core:

```sh
lune run coverage.luau package=self --adapter=./tools/coverage/lune/adapters/coverage_self
```

If requires/types are broken on a fresh checkout, run `npm run setup` first
(installs wally deps, generates sourcemap + package types — all gitignored).

## Flags

- `--per-file` — per-file line-coverage breakdown (worst first).
- `--per-test` — per-test hit attribution (Lune pipeline only).
- `--recommend` — ranked list of concrete next steps; best flag when the goal
  is "improve this package's tests".
- `--mutate` — mutation testing (Lune pipeline only; slow). `--mutate-limit=<n>` caps it.
- `--json` — print merged coverage.json to stdout.
- `--timeout=<sec>` — tiniest watchdog override for hanging suites.
- `--rebuild-engine` — force `cargo build --release` of the Rust engine.

## Pipeline selection (why did Studio open?)

The adapter picks the pipeline automatically per package:
- **Lune** (fast, in-process): pure-Luau packages.
- **Real Roblox** (slow): packages that touch the datamodel (`game`,
  `Instance.new`, ...) **or contain `const`** — Lune 0.10.4 cannot parse `const`.
  This is expected behavior, not a hang; give it time or check the printed
  pipeline reason. The transport is either local **Studio** via `run-in-roblox`
  (one Studio launch) or headless **Open Cloud** (for CI, no Studio) — select
  with `--roblox-runner=studio|opencloud`. Default: `opencloud` when
  `ROBLOX_API_KEY` is set (plus `ROBLOX_UNIVERSE_ID`/`ROBLOX_PLACE_ID`), else
  `studio`.

For a coverage-free "do the specs pass on real Roblox?" run (all packages, one
Open Cloud task), use `lune run tools/ci/run_tests.luau`.

## Output

Console report ranks gaps (uncovered functions, one-sided decisions,
never-varied conditions). Artifacts land in `.coverage/<package>/`
(`coverage.json`, `map.json`, `hits.json`, instrumented `build/`) — all
gitignored. Full system docs: `tools/coverage/README.md`.
