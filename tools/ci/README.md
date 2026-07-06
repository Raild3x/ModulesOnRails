# `tools/ci` — real-Roblox test running via Open Cloud

Runs this repo's specs on **real Roblox servers** using the Open Cloud
[Luau Execution Session API](https://create.roblox.com/docs/cloud/reference/LuauExecutionSessionTask),
with no Roblox Studio install. This is how CI tests the datamodel/`const` packages
that the fast Lune pipeline cannot run (`run-in-roblox` needs a local Studio).

## Layers

| File | Role |
| --- | --- |
| `OpenCloud.luau` | Generic transport: publish a place → run a script as a Luau Execution task → poll → return terminal state + logs. Knows nothing about tests or coverage. |
| `PlaceTree.luau` | Builds the rojo project tree that mounts every `lib/<pkg>` under `ReplicatedStorage.src` plus `test/tiniest`. Shared with the coverage adapter. |
| `run_tests.luau` | Standalone entry: builds a **plain** place, runs `test/ci/runTests.luau` on it via `OpenCloud`, streams the tiniest report, exits non-zero on failure. Takes an optional package name to scope the run. |

The coverage system reuses `OpenCloud.luau` from its own runner
(`tools/coverage/lune/core/OpenCloudRunner.luau`), which builds an *instrumented*
place instead and decodes a coverage payload from the logs. Select it with
`lune run coverage.luau package=<name> --roblox-runner=opencloud`.

## Usage

```sh
export ROBLOX_API_KEY=...  ROBLOX_UNIVERSE_ID=...  ROBLOX_PLACE_ID=...

# Standalone, coverage-free PASS/FAIL, one Open Cloud task:
lune run tools/ci/run_tests.luau            # every package's specs
lune run tools/ci/run_tests.luau tablemanager   # scope to one package

# Coverage on real Roblox (one task per package), via the coverage system:
lune run coverage.luau package=<name> --roblox-runner=opencloud

# What CI runs — coverage for every Roblox-pipeline package via Open Cloud:
python scripts/test_package.py all --roblox-only --roblox-runner=opencloud
```

Packages whose Wally deps can't be resolved (e.g. `tablereplicator`, pending its
`raild3x/tablemanager` release) are **skipped with a warning**, not run.

## One-time setup (owner)

Open Cloud needs an experience to publish into and an API key. This is a
prerequisite that can't be created from code:

1. Create a **private, throwaway experience** in Roblox. Note its **universe ID**
   and its start **place ID** (these are what the runner publishes into and
   overwrites every run — do not point it at a real game).
2. Create an **Open Cloud API key** scoped to that place with:
   - `universe-places:write`
   - `universe.place.luau-execution-session:write`
   - `universe.place.luau-execution-session:read`
3. Add the three values as repository secrets: `ROBLOX_API_KEY`,
   `ROBLOX_UNIVERSE_ID`, `ROBLOX_PLACE_ID`.

CI's `test-roblox` job (`.github/workflows/ci.yml`) runs
`python scripts/test_package.py all --roblox-only --roblox-runner=opencloud`
(coverage for every Roblox-pipeline package on real Roblox). It uses these secrets
and **skips cleanly** when they're absent (e.g. pull requests from forks, which
can't read secrets).

## Notes / limitations

- **Execution context** differs from `run-in-roblox`: Open Cloud runs a **server**
  context, not Studio **edit mode / plugin security**. Fine for these packages;
  keep it in mind if a test depends on edit-mode-only behavior.
- **5-minute per-task cap** and publish/spin-up latency per run.
- Logs paginate, so there is **no ~1 MB payload cap** (unlike `run-in-roblox`); the
  coverage `--per-test` payload survives here.

The reference driver this was adapted from lives in `test/REFERENCE_CI/` (lent from
another project).
