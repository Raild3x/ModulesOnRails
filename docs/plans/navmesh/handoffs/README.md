# NavMesh handoffs (round 2, 2026-10-01)

Start here if you are a new session picking up NavMesh work. Read this file, then the handoff
for your track. Everything named here lives on branch `feat/navmesh` unless it says otherwise.

## Where things stand
- **`feat/navmesh`** has NavMesh tickets 01-24, 26 and 27.
  - That covers the local Update with changed regions, the path follower, the off-mesh and
    reachable queries, the Part adapter (`lib/navmeshadapter`), debug drawing, the bake
    format v3 (tagged sections), and the start/goal radius barriers.
  - 297 specs pass (after Track G and its weighted-path follow-up, 2026-10-01).
  - It is **local only. Do not push.** The only remote configured, `github-desktop-Mophyr`, is
    not the project's repo.
- **Docs:** everything is under `docs/plans/navmesh/`:
  - `spec.md` holds the requirements (SR1-SR14).
  - `review.md` holds every user ruling, dated. Read the ones touching your files.
  - `bench.md` holds the measurements.
  - `tickets/NN-*.md` hold the tickets. Their Status and As-built sections are current.
  - `simplification-plan.md` is the geometry-simplification plan.
  - `research/roblox-pathfinding-comparison.md` compares us with Roblox's PathfindingService;
    its rulings D1-D6 are in review.md.
  - [known-gaps.md](known-gaps.md) lists the weak spots and deferred items. Read it before
    touching Search, Clearance, Tiles or Serialize.
  - The glossary is `lib/navmesh/CONTEXT.md`.
- **Dogfood game:** `examples/navmesh-demo/`. Its `REPORT.md` is the first usability report.

## Tracks and order (ruled 2026-10-01: two at a time)

| Order | Track | Handoff | Touches |
|---|---|---|---|
| 1 | G, path output: **merged 2026-10-01** | [G-path-output.md](G-path-output.md): tickets 28 and 25 (minus link items), the Partial-end radius gap. Also built: heron nodes, added footprints; ticket 32 filed. Weighted paths built too (cost-aware funnel, exact edge costs) | Funnel, NavMesh, Types, Search (only if the area-bend fix needs it), the demo |
| 1 | H, measure and dogfood (**done 2026-10-01**: bench.md "Large worlds, 1-4 km", `examples/navmesh-demo2/REPORT.md`, new gaps in known-gaps.md; D6 ruled: fix O(map) costs first) | [H-measure-and-dogfood.md](H-measure-and-dogfood.md): ticket 31 (1-4 km maps), a second dogfood game on the new APIs | `tools/navmesh/bench`, `examples` only; no library code |
| 2 | E, links | [E-links.md](E-links.md): ticket 30, the link gaps, ticket 25's link names and ids | Search, Tiles (links pass), Storage (links), Serialize (links section), NavMesh, Types |
| 3 | F, geometry input | [F-geometry-input.md](F-geometry-input.md): the simplification passes, plus Update on huge rings | Build, Quantize, Tiles (re-snap), Clearance, Serialize (tolerance field), Types, the adapter |
| wave 2 | W, headroom | [W-headroom.md](W-headroom.md): ticket 29 | almost everything; alone, after E and F |

- **Two sessions at a time:**
  1. G and H together. They share no files.
  2. When G merges, start E beside H, or after it.
  3. When E merges, start F.
  4. Ticket 29 (W) starts after E and F have both merged.
- **Merge order:** G, then E, then F. Each later track merges `feat/navmesh` into its branch
  before its own merge.
- **Complex-map tickets 33-38 (added 2026-10-01): Tracks [M1](M1-maps-indoor-urban.md) (33, 34, 35), [M3](M3-maps-street.md) (36) and [M2](M2-maps-outdoor-combined.md) (37, 38). M2 and M3 start once 33 merges:**
  - **Ticket 33 merged 2026-10-01:** the harness is in `tools/navmesh/maps/`. Run
    `lune run tools/navmesh/maps/run.luau`; screenshots come from
    `python tools/navmesh/maps/studio.py <Map>`. The conventions are in ticket 33's as-built
    notes.
  - **Ticket 34 merged 2026-10-01:** the building map (`Building`, `BuildingRamp`) and the
    adapter's step-height rule, `AdapterOptions.MaxStepHeight` (ramp strips, ruled; riser
    seams are ticket 40). M3's curbs can use it now.
  - **Ticket 35 merged 2026-10-01:** the elevator map (`BuildingElevator`), the crowd sim
    `tools/navmesh/maps/ElevatorSim.luau`, and the reroute study
    (`tools/navmesh/bench/elevator_reroute.luau`). Ruled policy, which ticket 38 reuses:
    hysteresis (15%) on the game's own reopen event, plus a broadcast when the elevator goes
    out of service. Library aids are ticket 41.
  - **Ticket 36 merged 2026-10-01 (Track M3):** the street in front of the building
    (`Street` with curbs, `StreetFlush`), the adapter's area-name table (a text `NavArea`;
    `FromParts` returns `(desc, areas)`), and harness changes: `Filter` may be a function of
    the area names, and `Avoids` takes names and checks every floor at the segment's height.
    M2's combined map (38) can start from it.
  - The chain is 33 first; then 34, 36 and 37 in parallel; 35 after 34; 38 joins them all. 39 (voxel Terrain) comes later.
  - They are mostly maps, scenarios and measurements, so they can run beside a library track.
    The exceptions are the adapter changes the maps may force: the step-height rule (34) and
    the area-name table (36). Those touch `lib/navmeshadapter`.
- **Ticket 29 is rewritten and parked:** ceilings come from obstacles, with per-NPC postures.
  Revisit it with the user before wave 2 starts.
- **Human tasks:**
  - **The editor's manual Play-mode check:** `npm run setup navmeshdebug`, then
    `python tools/navmesh/studio/studio.py play`, then press F5. The key list is in ticket 21.
  - **Where `feat/navmesh` goes:** a remote, or a PR to main. Nothing has been pushed.

## House rules (every track)
- **Worktree:** never work in the main checkout. Create one:
  `git -C C:\Users\Logan\Documents\GitHub\TableManager worktree add .claude/worktrees/<name> -b <branch> <base>`
  - Then run `npm run setup navmesh` in it, or copy `lib/navmesh/_Index`,
    `lib/navmesh/ConstrainedDelaunay.lua` and `lib/navmesh/wally.lock` (gitignored) from another
    navmesh worktree.
- **Tests:**
  - Quick run: `lune run tools/navmesh/specs.luau` (about 10 s, prints `PASS n FAIL m`).
  - Gate: `lune run coverage.luau package=navmesh`. It must pass; 297 specs on `feat/navmesh` (after Track G, 2026-10-01).
  - Mutation:
    `lune run coverage.luau package=navmesh --mutate --mutate-jobs=8 --mutate-files=src/X.luau,src/Y.luau`
    - `--status package=navmesh` shows progress; `--resume` continues a killed run.
    - Scores are the covered-line score.
    - Don't let a file drop below its baseline in `docs/plans/navmesh/mutation-baseline.md`
      (whole-package run, 2026-10-01). Triage survivors, and write specs for the real ones.
- **Spec-first, with negative controls:** every new behaviour gets a spec that fails without the
  change. Show that it fails (revert the fix, run, restore).
- **Benchmark before options:** any performance or architecture fork gets prototyped and measured
  before it goes to the user.
- **User decisions:** ask only for genuine calls. Give 2-4 options with pros, cons and numbers,
  and say why the decision is needed. Record each ruling in `review.md`, dated.
- **stylua:** run `stylua --config-path stylua.toml <files>` from the repo root (rokit needs the
  manifest there), then `--check` until clean.
  - `stylua --line-endings Windows` **ignores stylua.toml**. That is how `f({...})` calls crept
    in.
  - With `core.autocrlf=true` a checkout is CRLF, and `--check` flags every file. Check LF copies
    if that happens.
- **Shell:** keep Bash commands ASCII-only, because the wrapper mangles non-ASCII. Use the
  Write/Edit tools for prose.
- **Studio:** launching it for benches or screenshots is fine anytime, with no need to ask.
  - Capture with `tools/navmesh/studio/capture.ps1` (PrintWindow).
  - If run-in-roblox panics with `os error 2`, point the HKCU
    `Software\Roblox\RobloxStudio` ContentFolder at the live `Versions\version-*\content\`.
- **Commits:** logical commits, each ending with
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
  - Merge into `feat/navmesh` only after the gate passes, and fast-forward where possible.
  - Never push.

## Not on `feat/navmesh`
- Reference-only prototypes, not for merge:
  - `proto/simplify` (worktree `simplify-proto`; also untracked probe scripts at its root),
    which Track F builds from;
  - `proto/local-update` and `proto/local-update-77` (ticket 22 variants).
- `research/roblox-pathfinding` is merged (b232d00); its worktree `rbx-pathfinding-research`
  can be removed.
- **Scratch:** the old `zz_*` probes are archived in the main checkout's gitignored
  `.bench/navmesh/archive/`.
- **Not NavMesh work:** the other `feat/*`, `fix/*`, `package/*` and `pr/*` branches, and the
  untracked `lib/component/*`, `lib/profiletrademanager/` and `lib/remotecomponent/CONTEXT.md` in
  the main checkout, belong to other sessions. Leave them alone.
