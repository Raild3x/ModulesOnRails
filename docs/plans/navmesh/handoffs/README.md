# NavMesh handoffs (2026-09-28)

Start here if you are a new session picking up NavMesh work. Read this file, then the handoff
for your track. Everything named here lives on branch `feat/navmesh` unless it says otherwise.

## Where things stand
- **`feat/navmesh`** has NavMesh tickets 01-22, the hardening and dogfood fixes, the Serialize
  v2 format, and the faster coverage tool.
  - It is **local only. Do not push.** The only remote configured, `github-desktop-Mophyr`, is
    not the project's repo.
- **Docs:** everything is under `docs/plans/navmesh/`:
  - `spec.md` holds the requirements (SR1-SR14).
  - `review.md` holds every user ruling, dated. Read the ones touching your files.
  - `bench.md` holds the measurements.
  - `tickets/NN-*.md` hold the tickets. Their Status and As-built sections are current.
  - `simplification-plan.md` is the geometry-simplification plan.
  - The glossary is `lib/navmesh/CONTEXT.md`.
- **Dogfood game:** `examples/navmesh-demo/`. Its `REPORT.md` is the usability report that
  tickets 22-27 came from, and `repros.luau` reproduces each issue.

## Tracks, and what can run in parallel

| Track | Handoff | Can start | Touches | Conflicts with |
|---|---|---|---|---|
| A | [A-ticket24-then-23.md](A-ticket24-then-23.md): finish ticket 24, then 23 | now; WIP exists | NavMesh, Queries, Snap, Search, Types, Funnel, the demo | B on `Search.luau`; C on `Types.luau` |
| B | [B-core-correctness-v3.md](B-core-correctness-v3.md): ticket 27 and the 1-pixel Update mismatch, one v3 bake format | now | Storage, Clearance, Tiles, Build, Search, Serialize | A on `Search.luau` |
| C | [C-ticket26-adapter-debug.md](C-ticket26-adapter-debug.md): Part adapter and debug drawing (ticket 26) | now | a new adapter module, DrawList, navmeshdebug, the demo's Studio side | A only in its last step (the `vector` typing) |
| D | [D-later.md](D-later.md): ticket 25, the simplification passes, deferred items | after A (25) and C (simplification) | Funnel, Build, Quantize | everything; run it alone |

**New tickets from the Roblox comparison (2026-09-28, rulings D1-D6 in review.md; research in
`research/roblox-pathfinding-comparison.md`), not yet assigned to a track:**

| Ticket | Can start | Touches | Conflicts with |
|---|---|---|---|
| [28](../tickets/28-blocked-ahead.md): `FirstAffectedSegment`, which part of a path an `Update` blocked | now (22 and 23 are merged) | NavMesh, Types, the demo | A on `NavMesh.luau`/`Types.luau` if A is still open |
| [29](../tickets/29-agent-height.md): agent height (headroom) | after B's v3 | Build, Storage, Search, Queries, Serialize, Types | B (format); the adapter emits its rings (C) |
| [30](../tickets/30-generated-links.md): generated jump and drop links, runtime `AddLink`/`RemoveLink` | after B's v3 | Search, Tiles, Storage, Serialize, NavMesh | B, and D's ticket 25 (`LinkDesc.Name`) |
| [31](../tickets/31-large-world-measure.md): measure 1-4 km maps (bench only) | now | `tools/navmesh/bench` only | none |

- **A, B and C can run at the same time**, each in its own worktree off `feat/navmesh`.
- **Merge order:** merge A before B's Search changes land, or rebase B on A. Leave C's
  `vector` typing step until A is merged.
- **One human task:** the editor's manual Play-mode check.
  1. `npm run setup navmeshdebug`
  2. `python tools/navmesh/studio/studio.py play`
  3. Press F5. The key list is in ticket 21.

## House rules (every track)
- **Worktree:** never work in the main checkout. Create one:
  `git -C C:\Users\Logan\Documents\GitHub\TableManager worktree add .claude/worktrees/<name> -b <branch> <base>`
  - Then run `npm run setup navmesh` in it, or copy `lib/navmesh/_Index`,
    `lib/navmesh/ConstrainedDelaunay.lua` and `lib/navmesh/wally.lock` (gitignored) from another
    navmesh worktree.
- **Tests:**
  - Quick run: `lune run tools/navmesh/specs.luau` (about 10 s, prints `PASS n FAIL m`).
  - Gate: `lune run coverage.luau package=navmesh`. It must pass; 210 specs on `feat/navmesh`.
  - Mutation:
    `lune run coverage.luau package=navmesh --mutate --mutate-jobs=8 --mutate-files=src/X.luau,src/Y.luau`
    - `--status package=navmesh` shows progress; `--resume` continues a killed run.
    - Scores are the covered-line score.
    - Don't let a file drop below its figure in the ticket notes. Triage survivors, and write
      specs for the real ones.
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
- `navmesh-ticket24` (worktree `.claude/worktrees/ticket24`) has the ticket 24 WIP (15d0c4c),
  not gated, based on e88ad15 (before ticket 22). Track A owns it.
- Reference-only prototypes, not for merge:
  - `proto/simplify` (worktree `simplify-proto`; also untracked probe scripts at its root);
  - `proto/local-update` and `proto/local-update-77` (ticket 22 variants).
- Untracked scratch:
  - `tools/navmesh/bench/zz_*.luau` in the `navmesh-phase0` and `update-proto` worktrees. Track B
    needs `update-proto`'s `zz_search2.luau` (the random sliver search) and
    `zz_oracle_proto.luau` (the bench-map Update oracle).
  - Gitignored `.bench/` and `.coverage/` folders: benchmark and triage outputs.
- **Not NavMesh work:** the other `feat/*`, `fix/*`, `package/*` and `pr/*` branches, and the
  untracked `lib/component/*`, `lib/profiletrademanager/` and `lib/remotecomponent/CONTEXT.md` in
  the main checkout, belong to other sessions. Leave them alone.
