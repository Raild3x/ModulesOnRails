# NavMesh verification workflow (Phase 0 proof)

Each check below was run in the Phase 0 spike (`spike/navmesh-phase0`, off `feat/navmesh`).
Every check lists the command to run it, what it proved, and the negative control it caught.
Later tickets cite these as their test seams. Commands run from the repo root.

## F1: core unit specs on Lune, plus a permanent pipeline guard
- **Command:** `lune run coverage.luau package=constraineddelaunay` (and `package=navmesh`).
- **Proved:**
  - Both cores are classified `[lune: pure Luau, no datamodel globals]`.
  - Specs pass, and a coverage report is written.
- **Guard spec:** each core has `src/Tests/<Pkg>.Core.spec.luau` with
  `expect(game).never_exists()`, labelled "core must stay on the Lune pipeline".
- **Negative controls:**
  - **A failing `expect`.** `expect(1).is(2)` failed the run with exit 1 and printed
    `Got '1' but expected it to be '2'`, the source line, and the spec path.
  - **The tripwire.** Adding the word `workspace` in a comment of `NavMesh.luau` reclassified
    the package `[roblox: uses datamodel global 'workspace']`, and the guard spec **failed in
    Studio** (`expect(run-in-roblox-place.rbxl).never_exists()`).
- **Scaffolding:** use `printf '<folder>\n<Formatted>\n<description>\n' | python scripts/new_package.py`.
  The template's `require(./"X")` syntax error is fixed in this spike.

## F2: mutation testing on the cores
- **Command:** `lune run coverage.luau package=constraineddelaunay --mutate --mutate-limit=20`.
- **Negative control:** with the collinear case and off-origin triangles unasserted, **5
  mutants survived** (score 54.5%), including the `det > 0` → `>=` boundary mutant.
- **Pass:** after adding collinear, asymmetric and translated-triangle cases, **12/12 run
  mutants were killed** (100%).
- **Tool finding (blind spot):** mutants on an `elseif` condition line are classified
  `no_coverage` and never run, even though tests execute that line. Here that was
  `ConstrainedDelaunay.luau:28` `elseif det < 0`, affecting `<`→`<=` and `0`→`1`.
  - Predicate-heavy CDT code will have many `elseif` chains.
  - **Workaround until the coverage tool is fixed:** write predicates as `if … then return end`
    sequences, not `elseif`, where mutation coverage matters.

## F3: golden snapshots (tiniest `snapshot`, Lune only)
- **Opt-in save:**
  - `SAVE_SNAPSHOTS=1 lune run coverage.luau package=<pkg>` (added to
    `tools/coverage/lune/core/LuneRunner.luau`).
  - Off by default and never set in CI.
  - `mutant_run.luau` stays read-only, so a mutant can never overwrite a golden.
- **Proved the full cycle on `CDT.Fixtures.spec.luau`:**
  1. A new `snapshot()` fails with "New snapshot() call needs to be saved".
  2. Saving writes `test/__snapshots__/srctestscdtfixturesspec.*.snap.luau`.
  3. A re-run matches.
- **Negative control:** moving one fixture coordinate (`6, 4` → `6, 4.5`) failed with
  "Snapshot does not match", printing the fresh DrawList and the on-disk one.
- **Accept path:** `SAVE_SNAPSHOTS=1` accepted the intentional change (1 snapshot updated).
  Reverting and re-saving restored the original.
- **Key collisions:** keys are built from the lowercased spec path plus test labels, so the
  `CDT.` / `NavMesh.` spec-file prefixes keep keys from different packages apart.
- **Finding:** there is no line diff. A mismatch prints both full blobs, about 240 lines for a
  small DrawList. That's readable, but slow to scan for large lists.

## F4: screenshot loop (DrawList → SVG → PNG)
- **Command:** `lune run tools/navmesh/render.luau <scene-module> <out-dir> [--no-png]`.
  - The scene module (a repo-relative path without `.luau`) returns `{ { Name, List, Layers? } }`.
  - The script writes `<Name>.svg` via `SvgBackend` (`lib/constraineddelaunaydebug/src/SvgBackend.luau`),
    then `<Name>.png` via headless Edge.
  - PNGs are inspected with Read.
- **Proved:**
  - Triangles, excluded (hole/obstacle) triangles, constraint colours per group, vertices,
    two overlapping floor layers, path arrows, labels and an agent-radius circle are all
    legible.
  - `Layers` renders one floor at a time.
- **Negative controls:** a dropped triangle shows as a white gap, and an offset waypoint shows
  a broken path chain. Both were plainly visible.
- **Bonus catch:** the throwaway *unconstrained* Delaunay prototype visibly leaks excluded
  triangles past the overlapping-obstacle outlines. The loop exposes constraint violations,
  which is the core CDT failure mode.

## F5: fixture reach
- `lib/constraineddelaunay/src/Fixtures.luau` loads in all three contexts:
  - a Lune spec (`CDT.Fixtures.spec.luau`, relative require);
  - the render script's scene module (repo-relative require);
  - the Studio bench/draw scripts (`ReplicatedStorage.src.constraineddelaunay.src.Fixtures`,
    `[MARK] fixtures 4`).

## F6: debug package on the Studio pipeline
- **Command:** `lune run coverage.luau package=constraineddelaunaydebug --roblox-runner=studio`.
- **Proved:**
  - The package is classified `[roblox: uses datamodel global 'workspace']`.
  - 3/3 `DrawListRenderer` specs pass in Studio: one adornment per (layer, colour), layer
    hiding, and an error on an unknown `Kind`.
- **Negative control:** the F1 tripwire run showed a failing spec coming back from Studio
  through the runner (`0 passed, 1 failed`).

## F7: Studio screenshot (works)
- **Recipe:**
  1. A scratchpad `place.project.json` mounts the worktree's `lib/` at `ReplicatedStorage.src`,
     then `rojo build … -o phase0.rbxl`.
  2. Start `capture.ps1` in the background. It waits for a Studio window titled
     `*run-in-roblox*`, then maximizes and captures it with `CopyFromScreen`.
  3. Run `run-in-roblox --place phase0.rbxl --script draw.luau`. The script draws with
     `DrawListRenderer`, sets a top-down Scriptable camera, and holds for 12s under a deadline.
- **Proved:** the PNG shows the drawn outlines, obstacles, circle and label in the viewport.
- **Gotchas:**
  - run-in-roblox opens a *copy* named `run-in-roblox-place.rbxl`, so match on that title.
  - The capture briefly maximizes and focuses Studio on the user's desktop.
  - It captures the whole window, not just the viewport.
  - `rojo build` embeds sources, so rebuild the `.rbxl` after every source edit.

## F8: network safety of plain state
- **Authority:** `lib/constraineddelaunay/src/PlainData.luau` (`PlainData.Check`), with 19
  specs and 100% line coverage.
  - Accepts: the fixtures, flat arrays, string dictionaries, buffers, empty tables and `math.huge`.
  - **Negative controls, all rejected with the right reason:** sparse array, mixed table,
    function, metatable, NaN, non-string key, cycle.
- **Informational Studio BindableEvent round-trip** (`roundtrip.luau`):
  - Fixtures and flat coords with a buffer arrive intact.
  - A mixed table is mangled.
  - A metatable is **silently stripped** (the raw keys survive, the behaviour doesn't).
  - A **sparse array arrived intact on the Bindable**, which is exactly why the Bindable is not
    the authority: remotes are documented to truncate at a nil hole.
  - The NaN result is inconclusive (`NaN ~= NaN` in the equality check).
- Remote size limits are untested.

## F9: bench harness (Studio)
- **Recipe:**
  - The place mounts `lib/` plus a scratchpad `bench/` folder at `ReplicatedStorage.Bench`.
  - `run-in-roblox --script bench.luau` runs 5 interleaved rounds, rotating the order.
  - Each round records the best of 5 reps; the output is median, min, max.
- **Results** (200k-point orientation loop):

  | variant | median ms | min | max |
  |---|---|---|---|
  | native 1x | 2.272 | 2.261 | 2.327 |
  | native 2x (CONTROL) | 4.568 | 4.552 | 5.362 |
  | interpreted 1x | 6.591 | 6.578 | 6.973 |

- **Negative control:** the 2x control lands at 2.01x the baseline, clearly separated from the
  ~3% spread.
- **`--!native` does apply under run-in-roblox:** it runs 2.9x faster than the identical
  interpreted module, so the Open Cloud fallback is not needed. `debug.dumpcodesize()` is
  CommandBar-only, so the on/off delta is the native check.

### In-repo harness (ticket 04): the command for every later performance fork
- **Command** (from the repo root; it launches Studio):
  ```sh
  python tools/navmesh/bench/run.py --suite 2d|3d --runs 3 --rounds 5   # audited B1 method
  python tools/navmesh/bench/run.py --suite 2d --runs 1 --rounds 1      # smoke, about 1 min
  ```
- **What it does:**
  - `gen_layouts.py` expands one workload template per layout, so the code is monomorphic.
  - It builds a place in `.bench/navmesh/<suite>/` (gitignored), runs Studio N times, and saves
    the raw `run<i>.txt` output.
  - It prints the median table for the grid mesh and the shuffled-id mesh.
- **Harness files:** `Harness.luau` (interleaved rotated rounds, best-of-3, deadline plus
  `[MARK]`) and `Mesh.luau` (jittered grid plus a shuffle).
- **Gates:** it exits 1 when any of these fails:
  - a run misses `[MARK] done` or hits its deadline;
  - layouts disagree on the topology-only flood;
  - the audited ranking does not reproduce. On the shuffled mesh, the group median of
    table-topology locate divided by the buffer-topology group median must be at least 1.3.
    Audited: about 1.9x. Studio drift is 10-30%, so 1.3 only fails when the ranking flips.
- **To add a fork:** add a storage class or layout entry in `gen_layouts.py`, and list it under
  `buffer` or `table` in `run.py`'s `SUITES`.
- **Smoke (2026-09-25):**
  - 2D: 1.91x (C64 shuffled locate 20.7 ms, audited 21.2; typed Vector3 plus buffer-topology
    dijkstra 27.4, audited 27.2).
  - 3D: 1.89x.
- **Negative controls** (the saved run replayed through `report()`, 5/5):
  - swapped groups: FAIL at 0.52x;
  - a tampered flood check: FAIL;
  - a deadline marker: FAIL;
  - empty output: FAIL;
  - the real run: PASS.

## F10: unpublished sibling dependencies (ruling D2: simplest in-repo mechanism)
- **Declare:** `[custom] siblings = "a,b"` in the dependent's `wally.toml`, kept out of
  `[dependencies]` until publish.
- **Setup** (`scripts/setup_package_for_testing.py`, `link_siblings`):
  - Runs at the **end** of `setup_package`, after the registry `Packages/` move. Running it
    earlier nests the registry `_Index` inside the sibling `_Index`; that happened during this
    proof and was fixed.
  - Sets up each sibling first, recursively, so transitive siblings resolve.
  - Copies it to `_Index/raild3x_<name>@local/<name>/` with an `init.luau` Lune shim
    (`return require("@self/src/<Formatted>")`).
  - Writes a `<Formatted>.lua` link module at the package root, which is exactly the Wally shape.
- **Test time** (`tools/coverage/lune/adapters/modules_on_rails.luau`):
  - `M.materialize` calls `refreshSiblings`, which overwrites each vendored sibling's `src` (and
    its siblings', recursively) with the current `lib/<sibling>/src` on every run.
  - A sibling that was never vendored is a loud error naming the setup command.
- **Gates:** `hasWallyDependencies` (adapter) and `_has_wally_dependencies` (`scripts/test_package.py`)
  count a non-empty `siblings` as a dependency, so a sibling-only package gets set up by CI's
  `_ensure_setup`.
- **Controls, all passed:**
  - **(a)** `npm run clear`, then `python scripts/test_package.py navmesh --lune-only` (the CI
    entry point): it detected "not set up", ran setup, linked the sibling, and the specs passed.
  - **(b)** CDT `OrientSign` was edited to return 42 without re-running setup. The vendored copy
    was stale, yet the navmesh run saw the edit and failed with `Got '42' but expected it to be '1'`.
  - **(c)** the `navmeshdebug` stub resolves `navmesh`, `constraineddelaunay` (transitively),
    `constraineddelaunaydebug` and the registry better-signal: 3/3 specs pass **in Studio**.
    better-signal touches Roblox APIs when required (`IsDeferred.luau:12`), so any package using
    it runs on the Studio pipeline. navmeshdebug will anyway, because of the editor.
- **Whole repo:** a no-argument `npm run setup` still completes (35 setups for 29 packages; the
  extras are recursive sibling set-ups).
- **Regression:** graphutil 181/181, and the coverage tool's own suite 116/116.
- **Editor types:** after editing a sibling, re-run `npm run setup <dependent>` to refresh its
  luau-lsp view. Tests never need this.
- **Deferred (D2):** publish-time conversion to `[dependencies]`, and re-running dependents in CI
  when only a sibling changed. **Do not publish-label these packages yet.**

## F2 addendum (spec debate): mutation with goldens present
- **Bug:** once `CDT.Fixtures.spec.luau` (which uses `snapshot()`) existed, the mutation baseline
  went red. `mutant_run.luau` labelled specs with the full build path while `LuneRunner`
  labelled them relative to the build dir. Snapshot keys come from labels, so every snapshot
  looked new, and mutation was **silently skipped** ("baseline suite is not green").
- **How it was missed:** F2 and F3 each passed on their own. The F2 run predates the golden
  spec.
- **Fix:** `mutant_run.luau` now labels relative to `buildDir`.
- **Verified:** `--mutate --mutate-limit=40` runs a green baseline, with 38 of 40 killed.
- **Remaining noise:** 73 `no_coverage` mutants on fixture data literals, and 16 on `elseif`
  lines in `PlainData`. Both are ticketed (adapter `EXCLUDE`, the `elseif` fix).
