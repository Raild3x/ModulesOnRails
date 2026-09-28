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
| `--mutate-all-tests` | run the whole suite for every mutant, to the end (default: only the tests that can observe the mutant, stopping at the first failure) |
| `--resume` | skip mutants an interrupted `--mutate` run already decided (needs unchanged code and tests) |
| `--status` | print a `--mutate` run's live progress from `progress.json` and exit (exit 1 when there is none or its heartbeat is stale) |
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
`--mutate-jobs=<n>` run is in flight; they are deleted when it ends), plus
`progress.json` and `mutation.partial.json` (live progress and every decided
mutant so far) and `select/` (the per-mutant test lists). Everything is
gitignored.

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
* **Progress** (see [Watching a long run](#watching-a-long-run)): one status
  line every 15 s, plus `progress.json` and `mutation.partial.json` rewritten
  every 2 s. To **stop early and keep partial results**, create the stop file
  the run announces (`.coverage/<package>/mutation.stop`).
* **Test selection** (default; `--mutate-all-tests` turns it off): a child runs
  only the tests that can observe its mutant and exits at the first failure.
  See [Test selection](#test-selection).
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

#### Watching a long run

A `--mutate` run prints one line every 15 s:

```
[mutation] 76/195  killed 67  survived 9  timeout 0  error 0  score 88.2%  elapsed 0m15s  eta 0m23s  [src/OpenList.luau, src/Snap.luau]
```

`score` is detected / run so far, `eta` extrapolates this run's own pace, and
the brackets list the files the workers are mutating right now.

Another process can poll `.coverage/<package>/progress.json`. It is rewritten
every 2 s, via a temp file and a rename, so a reader never sees half a file:

```json
{
  "schema": "tm-coverage-progress/1", "package": "navmesh", "phase": "mutating",
  "started_at": 1790567025, "heartbeat": 1790567040, "elapsed": 15,
  "done": 76, "total": 195, "resumed": 0,
  "killed": 67, "survived": 9, "timeout": 0, "error": 0, "invalid": 0,
  "score": 88.16, "eta_seconds": 23,
  "current": ["src/OpenList.luau", "src/Snap.luau"], "jobs": 16
}
```

`phase` is `baseline`, `mutating`, `done`, `stopped` or `failed`. `heartbeat`
is a Unix time. A `baseline` or `mutating` phase whose heartbeat is more than
30 s old means the run died. Or just ask:

```sh
lune run coverage.luau --status package=navmesh
# navmesh: mutating, heartbeat 1s ago, 16 worker(s)
# [mutation] 76/195  killed 67 ...
# (a dead run reads "DEAD? (mutating, no heartbeat for 95s)" and exits 1)
```

`mutation.partial.json` holds every decided mutant so far (the same records
as `mutation.json`), so a killed run still leaves its survivors. Run again with
`--resume` to skip them. The file carries a sha256 of `mutants.json` plus
every file under the package's source root, specs included, and `--resume`
only reuses it when that matches. Otherwise it says so and starts fresh.

#### Test selection

The coverage run already records which tests hit which probes (tiniest's
per-test attribution), so a mutant only needs the tests that can observe it:

* every test that **entered the function** holding the mutated line. The unit
  is the function, not the line, so a test that reads a cache the function
  fills still runs when it skips the mutated line itself;
* every test of a **spec whose describe bodies** entered it: `describe`-level
  setup (`local mesh = Build(...)` outside any `test`) is shared by that
  spec's tests. The coverage run gives specs a `describe` that drains the
  counters on entering and leaving each top-level describe body, to tell this
  setup apart from module init.

A mutant runs the **whole suite** instead when a value built from it can reach
tests that never run it: the line is module-level code, or one of its
functions ran during module init / spec top-level code, or in a describe body
or test that also initialized a module (a lazy `require`).

The child still collects every spec (so require-time and describe-time code
runs exactly as in a full run), keeps the selected tests in their original
order, and exits at the first failing test: one failure kills the mutant.
Each distinct selection is first run once unmutated. If it is not green on its
own (a test depending on an earlier, unselected one), its mutants fall back to
the whole suite. A selection's timeout is 3x that unmutated run (min 5 s),
like the whole suite's. `mutation.json` records `tests` (how many ran) on each
selected mutant.

Stopping at the first failure changes one classification: a mutant that fails
one test and hangs a later one used to be a `timeout` (the whole suite ran
into the hang) and is now `killed`. Both count as detected, so scores do not
move. Survived and no-coverage mutants are unaffected.

The one assumption: a test that never entered the mutated function cannot
fail because of it, except through state that the rules above already route to
the whole suite. State one test leaves in a module-level cache for a later test
that does not enter the function is the known gap. `--mutate-all-tests` runs
the old way.

#### Where the time goes

Per mutant, the child is `lune` startup (~0.1 s), collecting every spec
(~0.25 s), then the tests. `apply-mutant` is ~0.05 s. On navmesh the whole
suite is 150 tests and 8-10 s, 6.6 s of it one spec (`NavMesh.Build.spec`),
so before selection almost all of a run was tests that could not see the
mutant. Measured on navmesh with `--mutate-jobs=16` on a shared
16-core/24-thread machine, three interleaved old/new runs each (median, range):

| subset | mutants | mutant loop, before | after | whole command, before | after |
|---|---|---|---|---|---|
| `src/OpenList.luau,src/Snap.luau` | 195 | 138 s (124-142) | 20 s (19-20) | 169 s (153-174) | 51 s (49-52) |
| `src/Quantize.luau,src/Search.luau` | 445 | 199 s (198-208) | 79 s (76-82) | 233 s (230-241) | 111 s (109-115) |

Per-mutant outcomes were identical apart from the two `timeout` -> `killed`
mutants above (both confirmed to fail a test before hanging). What remains is
mostly survivors, which must run every selected test, and the fixed ~0.35 s
per child. Not done, and why: reusing worker processes (Lune cannot evict a
module from its require cache, and a hung mutant must be killable), running
likely killers first (killed mutants are at most ~28% of the remaining child
time, and reordering tests would change inter-test state), and applying
mutants without the engine (~5%).

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
                              StdoutCodec, Merge, Mutation, Progress, Recommend,
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
`Report`, `Mutation`, `Progress`, `Recommend` specs in `lune/core/Tests/`, run from the
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
