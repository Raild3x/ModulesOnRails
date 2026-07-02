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
| `--no-conditions` | measure decisions/branches but not boolean-operand conditions |
| `--rebuild-engine` | force a `cargo build --release` of the Rust engine |
| `--timeout=<sec>` | tiniest safe-mode watchdog override (Lune) |
| `--adapter=<path>` | use a different repo adapter |

Outputs land in `.coverage/<package>/`: `map.json` (probe registry), `hits.json`
(runtime counters), `coverage.json` (merged report), plus the instrumented
`build/` copy. Everything is gitignored.

## Metrics

Line, statement, function, branch (arm), decision (both-ways), and condition
(each boolean operand both-ways) coverage. The report explains *why* coverage is
incomplete — functions never entered, decisions never taken both ways (with the
condition source and which side is missing), and conditions that never varied.

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
  engine/                     Rust crate (full_moon): analyze | instrument | verify
  lune/
    adapter.luau              RepoAdapter / PackageSpec types
    adapters/modules_on_rails.luau   this repo's adapter
    core/                     Orchestrator, Engine, LuneRunner, RobloxRunner,
                              StdoutCodec, Merge, Analyze/Report, CoverageJson
test/tiniest/tiniest_coverage.luau   the tiniest plugin
```

## Known limitations

- Loop iteration counts (zero/one/many) and dead-code detection are reserved but
  not yet computed.
- `.coverage-ignore` suppression files are recognized by the adapter but not yet
  applied in analysis.

## Building the engine

The orchestrator builds it on demand. Manually:

```sh
cd tools/coverage/engine && cargo build --release
```
