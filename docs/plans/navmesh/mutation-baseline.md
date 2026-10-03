# NavMesh mutation baseline (2026-10-01)

This is the floor for round-2 tracks: a file a track changes must not drop below its row.

**The run:**
- Whole package on `feat/navmesh` at b232d00 (271 specs).
- Command: `lune run coverage.luau package=navmesh --mutate --mutate-jobs=16`, about 18
  minutes with per-mutant test selection.
- Log: `.coverage/navmesh-fullgate-2026-10-01.log` (gitignored).

**Score:** killed, timeout and error count as detected. The score is detected / (detected +
survived), the covered-line score.

**Package:** 4,316 mutants. 3,936 ran: 2,297 killed, 114 timed out, 875 errored, 650 survived.
380 had no coverage. Covered-line score **83.5%**.

| File | Score | Detected / decided | Survived | Earlier figure |
|---|---|---|---|---|
| Build | 83.5% | 726 / 869 | 143 | 83.5 (Track B gate) |
| Clearance | 80.1% | 598 / 747 | 149 | 80.1 (Track B gate) |
| DrawList | 98.2% | 54 / 55 | 1 | 97.5 |
| Funnel | 83.3% | 80 / 96 | 16 | 85.9 (hardening) |
| NavMesh | 94.7% | 180 / 190 | 10 | 99.0 (hardening) |
| OpenList | 86.7% | 26 / 30 | 4 | 86.7 |
| Quantize | 85.3% | 256 / 300 | 44 | 85.3 |
| Queries | 83.0% | 234 / 282 | 48 | 81.4 (hardening) |
| Search | 84.0% | 157 / 187 | 30 | 84.0 (Track B gate) |
| Serialize | 87.5% | 119 / 136 | 17 | 87.5 (Track B gate) |
| Snap | 89.2% | 166 / 186 | 20 | 89.1 |
| Storage | 95.6% | 301 / 315 | 14 | 95.6 (Track B gate) |
| Tiles | 80.4% | 316 / 393 | 77 | 80.4 (Track B gate) |

**Notes:**
- **Funnel and NavMesh are lower than their hardening figures.** Tickets 23 and 24 added code
  there without re-gating the whole file. Track G owns Funnel and NavMesh next. It should
  triage those survivors and win the lost points back if the mutants turn out to be real.
- **Build dropped to 82.3% in Track M2 (2026-10-01; 762 / 923 decided, 161 survived).** The
  drop is all in `onWalkable`, the new check that a seam cut away by obstacles did lie on its
  floor (ticket 37's core fix): 19 of its mutants survive, against 18 more survivors in the
  file.
  - **Triaged as not real:** they change the size or direction of the one-pixel probe offset
    (`len`, `nx`, `nz`, `* side` against `/ side` for side = ±1, `+` against `-` when both
    sides are probed), or the even-odd test's ties at a vertex. Any offset under a ring's width
    gives the same answer, so killing them would need floors narrower than the offset.
  - Every behaviour of the change has a spec that fails without it: the edge probe, a seam off
    a floor that has obstacles, floors on one side of a seam with one partly cut, and floors
    crossing at the seam (the overlap rule).
- **`src/Tests/Helpers/Flood.luau` is a test helper**, and it gets mutated too (48.7%, 77
  survivors). It's not library code, so leave it out of the baseline. Excluding `Tests/` from
  `--mutate` is a small tooling fix for whoever touches the coverage tool next.
- **Funnel after the cross-floor wall-corner fix (2026-10-02, branch `navmesh-vertex-stall`):**
  85.3% (285 / 334 decided, 49 survived; `--mutate-files=src/Funnel.luau`). It was 79.8%
  before the "Wall corners where floors meet" specs (NavMesh.Floors). The 12 survivors in the
  new code (`vertexAt`, `wallAt`, `corner`) are triaged as not real:
  - `PIXEL`'s `1e-9` -> 0: grid coordinates are exact, so a copy one pixel off is still
    `<= 1/256`.
  - `vertexAt`'s loop from 0, and `k == 2` -> `~=`: both still look at all three vertices.
    `<=` -> `<`: a tie needs two vertices of a triangle at the same distance within a pixel.
  - `wallAt`'s `side` loop from 0, and `side == 1` -> `~=`: each walks both ways round, and
    the answer doesn't depend on the order. The step loop from 0 runs 65 steps, not 64.
  - The vertex index `else 3` -> 0: 0 and 3 give the same edges mod 3.
  - `ends <= PIXEL` -> `<`: a portal end exactly `1/256 + 1e-9` off needs off-grid input.
  - The two `radius > 0` -> `>=` guards: at radius 0 the push ignores the flags.
  - `vi == 0` -> `vi == 1` after a seam crossing finds no copy: walking on can only get back
    to the vertex through a portal ending there. No mesh tried changed the answer (12 layouts
    in 8 orientations); treated as not real in practice.
