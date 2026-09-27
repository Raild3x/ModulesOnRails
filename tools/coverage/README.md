# Coverage System

AST-instrumented test coverage for the ModulesOnRails packages, integrated with
the `tiniest` framework. Supersedes the old `covaudit` static heuristic with true
per-line / per-branch / per-condition coverage.

## Usage

```sh
lune run coverage.luau package=<name>      # one package
lune run coverage.luau package=all         # every package with specs
lune run coverage.luau package=last        # last package tested (test/last_tested_package.txt)
```

Flags:

| flag | effect |
|------|--------|
| `--json` | also print the merged `coverage.json` to stdout |
| `--per-test` | include per-test attribution (Lune pipeline only) |
| `--per-file` | show a per-file line-coverage breakdown (worst first) after the totals |
| `--no-conditions` | measure decisions/branches but not boolean-operand conditions |
| `--suggest-const` | report `local`s never reassigned that could be `const` (opt-in; see below) |
| `--mutate` | mutation-test the package after the coverage run (Lune pipeline only) |
| `--mutate-limit=<n>` | cap the number of mutants run (deterministic sampling across files) |
| `--mutate-ops=<csv>` | only run these operators (`ror`, `lor`, `aor`, `not`, `lit`) |
| `--mutate-timeout=<sec>` | per-mutant suite timeout (default 3x the baseline duration, min 5s) |
| `--mutate-jobs=<n>` | run mutants on `n` parallel workers, each in its own build copy (default: half the logical cores, 1 if unknown; results identical to serial) |
| `--mutate-files=<csv>` | only mutate these package-relative files/globs, e.g. `src/Tiles.luau,src/**/Snap*.luau` |
| `--recommend` | end the report with a ranked list of concrete next steps |
| `--lune-only` | skip Roblox-pipeline packages; run only Lune ones (used by the fast CI job) |
| `--roblox-only` | skip Lune-pipeline packages; run only Roblox ones (used by the Open Cloud CI job) |
| `--roblox-runner=<opencloud\|studio>` | transport for Roblox-pipeline packages (default: `opencloud` if `ROBLOX_API_KEY` set, else `studio`) |
| `--rebuild-engine` | force a `cargo build --release` of the Rust engine |
| `--timeout=<sec>` | tiniest safe-mode watchdog override (Lune) |
| `--adapter=<path>` | use a different repo adapter |

Outputs land in `.coverage/<package>/`: `map.json` (probe registry), `hits.json`
(runtime counters), `coverage.json` (merged report), plus the instrumented
`build/` copy — and with `--mutate`, `mutants.json` (enumerated sites),
`mutation.json` (per-mutant results), and a pristine `mutbuild/` copy the loop
mutates and restores (plus `mutbuild-2/`..`mutbuild-<n>/` while a
`--mutate-jobs=<n>` run is in flight; they are deleted when it ends). Everything
is gitignored.

## Metrics

Line, statement, function, branch (arm), decision (both-ways), and condition
(each boolean operand both-ways) coverage. The report explains *why* coverage is
incomplete — functions never entered, decisions never taken both ways (with the
condition source and which side is missing), and conditions that never varied.

### Const candidates (`--suggest-const`)

A scope-aware second pass in the engine reports `local` declarations (including
`local function`s) whose names are never reassigned anywhere in the file, so
the statement could use `const`. Shadowing-correct (a reassignment to an inner
shadowing `local` doesn't disqualify the outer one), closure-aware (a closure
writing an upvalue does disqualify it), and interior-mutation-aware
(`t.x = 1` is not a rebind of `t`). Params, loop variables, and
initializer-less locals are never reported. **Opt-in** because Lune cannot
parse `const` yet: adopting a suggestion moves a Lune-pipeline package onto the
Roblox pipeline (the report says so). The usual ignore-rule forms
(`src/path.luau:LINE`, `site:const:...`) suppress individual findings.

### Mutation testing (`--mutate`)

Measures test *strength*: the engine enumerates single-token mutations
(`==`<->`~=`, `<`<->`<=`, `>`<->`>=`, `and`<->`or`, `+`<->`-`, `*`<->`/`,
`not` removal, `true`<->`false`, number literal swaps — value expressions only,
never types/strings/comments), then per mutant the orchestrator applies it to a
pristine copy (sha-guarded byte replacement, reparse-verified), runs the spec
suite in a **fresh child Lune process** (cold require cache; a busy-looping
mutant is killed at the timeout), classifies the result, and restores the file.

* killed / timeout / error count as **detected**; **survived** means the tests
  pass despite the change — a real gap.
* Mutants on lines no test executes are skipped as `no coverage` (reported, not
  run); the gap between the two scores is the plain-coverage story.
* The baseline suite must be green or the phase aborts.
* Progress prints per mutant with an ETA. To **stop early and keep partial
  results**, create the stop file the run announces
  (`.coverage/<package>/mutation.stop`).
* **Parallel runs** (`--mutate-jobs=<n>`): `n` workers pull mutants from one
  queue in plan order. Each has its own pristine build copy, so applying a
  mutant in place never races another worker, and each restores its own file
  after every mutant. Outcomes are merged back in plan order, so
  `mutation.json` matches a serial run apart from the `duration` fields. The
  stop file halts every worker after its current mutant. The timeout is per
  child; its default comes from a serial baseline, so with many workers on a
  busy machine pass a larger `--mutate-timeout` if slow mutants start timing out.
  The default is half the logical cores, read from `NUMBER_OF_PROCESSORS`
  (Windows) or `/proc/cpuinfo` (Linux), or 1 where neither exists (macOS).
  `--mutate-jobs=1` restores the old serial loop. On a 16-core/24-thread
  machine, navmesh (`--mutate-files=src/OpenList.luau,src/Snap.luau`, 172
  mutants) took 434 s serial, 119 s with 4 jobs, 68 s with 8, and 43 s with 16,
  with identical results each time.
* **File filter** (`--mutate-files=<csv>`): only mutants in matching files are
  run or counted (`*`/`?` match within a path segment, `**` spans directories;
  paths are package-relative, e.g. `src/Snap.luau`). Coverage still runs the
  whole package. The report and `totals.files_filter` in `mutation.json` /
  `coverage.json` mark the score as a filtered subset, and a filter that
  matches nothing prints a warning.
* Roblox-pipeline packages are skipped (one Studio launch per mutant).

### Recommendations (`--recommend`)

Post-processes everything above into a ranked top-10 of concrete next steps:
failing tests, mutation survivors, uncovered public functions (with their
parameter list), one-sided decisions, never-varied conditions, single-iteration
loops, and const hygiene. Mirrored into `coverage.json` under
`recommendations`.

## How it works

Seven phases, three hosts:

1. **Static analysis + instrumentation** — the Rust engine (`engine/`, built on
   `full_moon`) parses each source file, allocates dense probe ids, and splices
   probe calls in by *pure text insertion* (existing bytes are never modified, so
   `const`/comments/formatting can't be corrupted). Statement/function probes are
   `_COV(id)` inserts; decisions/conditions are `_COVD`/`_COVC` expression wrappers
   that preserve Lua short-circuit and multi-value semantics. A `verify` pass
   re-parses the output.
2. **Runtime collection** — an emitted `_cov.luau` module holds a dense counter
   array; recording is one array increment per probe (O(1)).
3. **Framework integration** — `test/tiniest/tiniest_coverage.luau` is a tiniest
   plugin that attributes hits to each test via an `after_test` delta scan. The
   `_for_lune`/`_for_roblox` wrappers accept an extra `plugins` option.
4. **Run** — pure-Luau packages run in **Lune**; packages using the datamodel or
   `const` (which Lune 0.10.4 can't parse) run on **real Roblox**, with coverage
   marshalled back through a stdout/log sentinel protocol. Two interchangeable
   Roblox transports: local **Studio** via `run-in-roblox`, or headless
   **Open Cloud** (for CI) via the driver in `tools/ci/OpenCloud.luau`. Pick one
   with `--roblox-runner=studio|opencloud`; the default is `opencloud` when
   `ROBLOX_API_KEY` is set, else `studio`.
5. **Analysis + reporting** — `Merge` joins hits onto the map; `Report` prints the
   ranked console report; `CoverageJson` writes the versioned `coverage.json`.

## Architecture

The core is **repo-agnostic**. All ModulesOnRails-specific knowledge (package
discovery, layout, pipeline choice, Studio scaffolding) lives behind the
`RepoAdapter` interface in `lune/adapters/modules_on_rails.luau`. The Rust engine
takes layout as flags (`--source-root`, `--spec-pattern`, `--exclude`); nothing
under `engine/` or `lune/core/` hardcodes `lib/`, `_Index`, or `.spec.luau`.

```
coverage.luau                 CLI: args -> adapter -> core
tools/coverage/
  engine/                     Rust crate (full_moon): analyze | instrument |
                              verify | mutate | apply-mutant
  lune/
    adapter.luau              RepoAdapter / PackageSpec types
    adapters/modules_on_rails.luau   this repo's adapter
    mutant_run.luau           per-mutant child entry (fresh Lune process)
    core/                     Orchestrator, Engine, LuneRunner, RobloxRunner,
                              StdoutCodec, Merge, Mutation, Recommend,
                              Analyze/Report, CoverageJson
test/tiniest/tiniest_coverage.luau   the tiniest plugin
```

## Building the engine

The orchestrator builds it on demand. Manually:

```sh
cd tools/coverage/engine && cargo build --release
```

## Testing

The coverage program has its own test suite on both hosts.

**Rust engine** (unit tests per module, CLI/exit-code integration tests, and
golden-file drift tests against `engine/tests/fixtures/simple_pkg`):

```sh
cd tools/coverage/engine && cargo test
```

**Lune core modules** (`Merge`, `Ignore`, `StdoutCodec`, `CoverageJson`,
`Report`, `Mutation`, `Recommend` specs in `lune/core/Tests/`, run from the
repo root via the self adapter — the default adapter only resolves `lib/`
packages):

```sh
lune run coverage.luau package=self --adapter=./tools/coverage/lune/adapters/coverage_self
```

**Adapter specs** (`lune/adapters/Tests/`: runner scaffolding and the in-repo sibling
refresh in `materialize`). These are outside the self adapter's `core/` source root, so they
have their own runner:

```sh
lune run tools/coverage/lune/adapters/Tests/run.luau
```

**Ignore rule forms** (`.coverage-ignore` at a package root; one rule per line, no inline
comments):
- `Qualified.Name`: a function and its body.
- `src/path.luau:LINE`: any site on that line.
- `site:<key>`: one exact site.
- `src/path.luau`: the **whole file**. It is dropped from the metrics and its mutants are
  excluded (for fixture data and test helpers).

`lib/*/.coverage-ignore` is re-included by `.gitignore`.

**Mutation gating:** a mutant runs when its line executed. A line counts as executed when a
statement probe *or a decision probe* on it was reached, so `elseif` conditions are mutated.

**Known gap:** mutants on continuation lines of multi-line statements (e.g. a multi-line
table constructor or wrapped arithmetic) still report "no coverage". The map records only a
statement's start line.

**Self-coverage** — the pipeline can measure its own Lune core via the
`coverage_self` adapter (specs live under the source root, so the runner picks
them up like any package's):

```sh
lune run coverage.luau package=self --adapter=./tools/coverage/lune/adapters/coverage_self
```

The IO/process-bound modules (Orchestrator, Engine, the runners, Report) are
included rather than excluded, so they read as honest gaps in the report.

The golden files under `engine/tests/golden/` pin the exact `map.json` and
instrumented output for the fixture package, so any change to probe collection,
id allocation, site keys, or splicing fails loudly. When such a change is
intentional, regenerate and review the diff before committing:

```powershell
$env:UPDATE_GOLDEN = "1"; cargo test --test golden; Remove-Item Env:UPDATE_GOLDEN
git diff tests/golden/
```

Fixture and golden files are pinned to LF line endings via `.gitattributes`
(probe byte offsets and file hashes depend on exact source bytes) — do not
reformat `engine/tests/fixtures/`.
