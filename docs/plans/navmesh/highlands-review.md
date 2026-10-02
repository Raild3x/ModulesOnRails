# Highlands review: what to decide (2026-10-02)

A review agent went over the Highlands map (commit 16cc6e3) as a game developer would: NPCs that
patrol, wander, chase, flee, prefer trails and avoid water. It wrote no code. Studio couldn't
render while the displays were off, so it worked from top-down plan views (`plan.luau`) and about
a dozen Lune probe scripts. Its evidence (PNGs, probe scripts and outputs) is in
`.claude/worktrees/navmesh-maps-outdoor/.bench/review/`.

The two most serious claims were re-checked before writing this: the sinkhole really is flat
(height 3.0 at its centre), and 7 generated jumps really do cross the cave's walls.

## In one paragraph

The mesh works: 97% of the ground is reachable from the plain once links are on, and paths take
2-4 ms. Five problems would hurt real NPCs. Jumps are generated through thin walls. Some places
can be jumped into but never left. Links break their own limits. A start brushing a rock fails
to path. Cost areas push paths onto jumps. Separately, five landforms on the map don't come out
as designed. Those are map bugs that I can just fix. For your floor-merging work: most floors
are 1-4 triangles, and merging floors whose slopes differ by up to 5 degrees would cut 3,461
floors to about 1,535.

---

## Library decisions (each needs your ruling)

### 1. Jumps generated through walls (severity: breaks NPCs)

`GenerateLinks` made 7 two-way jumps straight through the cave's 12-stud walls, for example
(124.5, 3.9, 87) → (125, 3.9, 94). An NPC outside the cave "jumps" through rock into it. The
path is 26 studs with the jump against 52 without.

**Why:** the generator stops its probe at a wall only when the wall stands inside the starting
floor's own outline. On terrain every floor is one or two triangles, so a wall always stands in
*another* floor's outline, and the check never fires. Any wall thinner than the jump distance
(6 studs) gets jumped wherever the ground is fragmented.

| Option | What it means | Trade-off |
|---|---|---|
| **A. Check every floor's outline (recommended)** | The probe stops at any column that lies inside some floor's outline but has no ground there. | A small change in `Generate.luau`. A wall that sits over a hole in the mesh would now also block jumps that were fine before; that seems right. |
| B. Test the jump's arc against obstacles | Sweep the arc against the cut-out footprints. | Catches more (low ceilings, the arc clipping a ledge), but it's more code and slower on a run that already takes 42 s. |
| C. Wait for floor merging | Bigger floors make the existing check work more often. | Doesn't fix it, only makes it rarer. Today's meshes stay wrong. |

### 2. Links break their own limits (severity: surprising)

- 18 "Drop" links fall less than 1 stud, and 5 of them actually go *up*.
- Jumps climb up to 3.88 studs when the limit is 3.
- Jumps reach 8.27 studs across when the limit is 6.

**Why:** the ends are checked first and then pushed away from walls to fit the agent. On sloped
ground the push moves them up, down or further apart.

| Option | Trade-off |
|---|---|
| **A. Re-check the limits after the push, and drop any link that fails (recommended)** | Honest limits. A few links disappear on slopes. |
| B. Re-label by the final height difference (a drop that ends flat becomes a jump), and keep the limits as they are | Labels become honest, but distances can still exceed the options. |
| C. Document that the limits apply before the push | No code change. Developers would still be surprised. |

### 3. A start near a wall fails to path (severity: surprising)

A start closer to a wall than the agent's radius returns Partial even in open ground. Of 400
random starts beside a wall: 7.5% fail at radius 1 and 10.5% at radius 2. Pushing the start off
the wall first rescues about half of them. FindPath already does this for the goal, but not for
the start. An NPC brushing a rock is common, so this will bite.

| Option | Trade-off |
|---|---|
| **A. Push the start off the walls, like the goal (recommended)** | The path's first point can sit up to one radius from where the NPC stands, as the goal's already can. |
| B. Leave it, and return a reason ("start pinched") with the Partial | Clearer to debug, but the NPC still can't move. |

### 4. Cost areas push paths onto links (severity: surprising)

Every generated link uses one area id (20) at cost 1. When the ground costs more (scree 3,
sand 2), paths start hopping. From the fan to the sinkhole, a cost-aware path spends 31 studs on
links against 7 without costs. A jump also ignores the cost of where it lands.

| Option | Trade-off |
|---|---|
| **A. A cost per link kind (recommended)** | GenerateLinks takes, say, `Costs = { Drop = 2, Jump = 3 }`, using `LinkDesc.Cost`, which already exists. Small change, and the developer tunes it. |
| B. Charge the landing area's cost | More faithful, but the core has to look up the landing triangle's area per link during the search. |
| C. Leave it, and document picking a link area cost | No change, but every developer meets the surprise. |

### 5. Places you can enter but never leave (severity: breaks wander and flee)

- The crater: 192 sq studs, reached only by one-way jumps off the rim.
- A scrap of riverbank (8 sq studs) that three one-way jumps land on.

An NPC that wanders in is stuck forever. Nothing in the API flags these places. The reviewer's
flood fill finds them in under a second on 10,665 triangles.

| Option | Trade-off |
|---|---|
| A. A GenerateLinks option to drop links into dead ends | Simple for developers, but some games want one-way traps (pits). |
| B. Report trap areas (a list or a per-triangle flag), and let the game decide | Flexible, but it's new API. |
| **C. Both: report them by default, drop them only when asked (recommended)** | Most useful, and the most code of the three. |

### 6. Adapter: seams shorter than the grid (carried from this morning)

M1's step-height code keeps seams as short as 0.001 studs, which is shorter than the core's
1/256-stud grid, so the core rejects them. The rest of the adapter uses 0.01 as its cutoff. The
map currently dodges it.

**Recommendation: change the one threshold to 0.01**, with a spec and a negative control, and
merge early.

### 7. Floors with no triangles (severity: cosmetic)

74 floors (e.g. "Cave Wall") end up with no triangles but are still stored in the mesh.
**Recommendation: drop them at Build.** It's cheap, but it changes floor ids and names in the
bake, so it wants your OK.

---

## Input for your floor-merging work

This is not a decision for now; it's data. Floor sizes on Highlands:

| Triangles per floor | Floors |
|---|---|
| 1 | 480 |
| 2 | 1,159 |
| 3-4 | 1,449 |
| over 16 | 13 |

If floors joined by a seam merged whenever their slopes differ by at most:

| Angle | Seams removed | Floors left (of 3,461) |
|---|---|---|
| 1° | 926 | 2,652 |
| 2° | 1,436 | 2,222 |
| 5° | 2,341 | 1,535 |
| 10° | 3,093 | 1,070 |

These counts are an upper bound: one merge can chain into the next. Merging would also make
problem 1 rarer. It would probably shorten the two known gaps that showed up here: paths up to
14% longer than a clear straight line, through points where four floors meet, and an occasional
follower stall beside a seam.

---

## Map fixes (no ruling needed; say go and I'll do them)

These are mistakes in my Highlands height formula, not in the library. Four scenarios currently
pass without testing what they claim.

1. **The sinkhole doesn't exist.** The plateau's "at least 3 high" rule refills the pit, and
   also flattens the rolling plains (that's why 35% of the map is under 0.5°). Fix: apply the
   plateau as a mask.
2. **The terraced hill isn't terraced.** Its 3-stud shelves are finer than the 4-stud cells.
   Fix: 1-2-stud cells on the hill, or real stepped Parts.
3. **The east trail is unusable.** The dunes overlap the plateau ramp, so the trail on it is
   mostly scree and holes; only 14 of 93 studs of a trail-loving path stay on the trail. Fix:
   keep the dunes off the ramp.
4. **The offshore islands are missing.** They're small bumps that fall between the grid's
   samples. Fix: sample at feature centres.
5. **No snow is reachable,** so the snow cost never matters. Fix: a snow field on the saddle or
   the glacier head.
6. **Fidelity misplaced.** The excluded lava strip spends 413 triangles at 2-stud cells. The
   shoreline, where it would matter, is a 45° sawtooth. Fix: lava as an area outline on coarse
   ground, and fine cells along the shore instead.

## Tooling requests (small; I'll do them unless you say otherwise)

- Bake to a temporary folder and swap it in, so `plan.luau` and probes don't crash while Studio
  re-bakes.
- `plan.luau`: fit non-square regions instead of padding them to a square; print each probe's
  length per area; add a `--color component` mode that shows islands and traps.

## Game-dev wishlist (new API; for later planning)

- **Reachability:**
  - `FindRandomPoint` that only returns points reachable from an origin (today, 20% of picks
    near the mesa are unreachable);
  - an `IsReachable(a, b)` or component id per triangle, answering in O(1) instead of a 6.6 ms
    failed search.
- **Point queries:** the area and its name, the slope and normal, the floor and its height, and
  "can an agent of radius r stand here".
- **Per-agent link permissions:** allow or deny by link label, each with its own cost. A "can't
  jump" agent should still be able to drop.
- **Line of sight at a radius:** `Raycast` with `AgentRadius`, for chasing and steering
  shortcuts.
- **Flee and gather queries:** "the farthest reachable point from X within cost N", and a cost
  map from a point.
- **Partial should say why:** start pinched, goal unreachable, or radius too big.
