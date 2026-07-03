# Coverage System

AST-instrumented test coverage for the ModulesOnRails packages, integrated with
the `tiniest` framework. Supersedes the old `covaudit` static heuristic with true
per-line / per-branch / per-condition coverage.

## Usage

```sh
lune run coverage.luau package=<name>      # one package
lune run coverage.luau package=all         # every package with specs
lune run coverage.luau package=last        # last package tested via tests.luau
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
| `--recommend` | end the report with a ranked list of concrete next steps |
| `--rebuild-engine` | force a `cargo build --release` of the Rust engine |
| `--timeout=<sec>` | tiniest safe-mode watchdog override (Lune) |
| `--adapter=<path>` | use a different repo adapter |

Outputs land in `.coverage/<package>/`: `map.json` (probe registry), `hits.json`
(runtime counters), `coverage.json` (merged report), plus the instrumented
`build/` copy — and with `--mutate`, `mutants.json` (enumerated sites),
`mutation.json` (per-mutant results), and a pristine `mutbuild/` copy the loop
mutates and restores. Everything is gitignored.

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
   `const` (which Lune 0.10.4 can't parse) run in **Roblox Studio** via
   `run-in-roblox`, with coverage marshalled back through a stdout sentinel
   protocol.
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
`Report`, `Mutation`, `Recommend` specs in `lune/core/Tests/`, run through the
repo's tiniest runner from the repo root):

```sh
lune run tests.luau package=tools/coverage/lune
```

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
