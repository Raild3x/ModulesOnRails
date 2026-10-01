# Bisector-offset funnel: prototype and measurements (ticket 25, Track G)

Branch `proto/g-bisector` (off `feat/navmesh` at bc81b94). Prototype only; nothing here is merged.

## The question

Today's funnel moves each wall-vertex portal end along its portal by min(r, half the portal). The
`Funnel.luau` class doc measured the worst clearance at 0.23-0.71 r on Courtyard and 0.06-0.11 r on
the bench `walls` scene. Would a bisector offset fix that, and at what cost in path length, query
time and spec churn?

## What was built

`Funnel.Mode` is a module-level switch. It is a prototype flag: delete it along with the branches
that lose. `NAVMESH_FUNNEL=<mode> lune run tools/navmesh/specs.luau` forces a mode for a whole
spec run.

| mode | wall-corner portal end becomes |
|---|---|
| `portal` | today: min(r, half the portal) along the portal |
| `bisector` | the corner moved into free space along the bisector of its free sector: r for a reflex sector, r / sin(half angle) for a convex one |
| `checked` | `bisector`, unless a path segment walks into a wall (`Queries.Walk`) or the path is over 1.05x the `portal` path's length; then the `portal` path |
| `-t` suffix (`bisector-t`, `checked-t`) | as above, but a reflex corner moves r / sin(half angle), capped at 2r. A segment leaving the offset point parallel to a wall edge then keeps r from that edge. |
| `arc` | the point on the corner's r-offset boundary in the portal's direction: on the portal at distance r inside the arc's range, else the arc's end on that side |
| `sine` | along the portal by r / sin(a), where a is the angle to the nearer wall edge at the corner, capped at half the portal |

**Shared mechanics (`sector`, `bisector` in Funnel.luau):**
- **Free sector:** walk the corner's triangle fan both ways from the portal's triangle until a wall
  edge (`Storage.IsWallEdge`). Each wall edge's direction bounds the sector. A pinch vertex (more
  than two wall edges) then gets the local sector that holds the portal.
- **Seam corners:** a walk that meets an open (seam) edge is completed from the other floor's fan.
  It is matched in (X, Z), as `wallAt` does.
- **Height and owner:** a `Queries.Walk` from the corner to the offset point gives both. A blocked
  walk falls back to `portal`. Off-portal points are cached per sector, so the funnel's
  `r == right` equality still holds. The owner replaces the portal triangle in `from`, which
  FindPath reads for `Floor`.
- **Inversion guard:** if the moved ends reverse order along the portal, that portal falls back to
  `portal`.

## Method

`tools/navmesh/bench/funnel_clearance.luau` (`pairs=150`, `dump=1`):
- **Scenes:** Courtyard (fixture), `props`, `bench` and `walls` (Scenes.luau), built with
  `MaxAgentRadius = 2`. The cap doesn't change a query at r ≤ 2.
- **Pairs:** seeded random start/goal pairs, both ends at least 2r from the walls by
  `FindDistanceToWall`. A pair is kept when today's funnel returns Success with at least one turn.
  Every mode runs on the same pairs, so the corridor is identical and only the funnel differs.
- **Clearance:** the exact minimum (X, Z) distance from the waypoint polyline to every wall edge,
  over r, capped at 3r. All four scenes are flat and single-floor, so this equals
  `FindDistanceToWall`. It is cross-checked against sampled `FindDistanceToWall` (step 0.05) on the
  first 5 paths of every configuration; the max difference was 0.009 studs, within the sampling
  step.
- **cross:** the share of paths that pass *through* a wall (clearance < 1e-4 r).
- **turn%:** the share of paths whose worst point lies within 1.5r of an interior waypoint.
- **Time:** FindPath per call, the min of 3 passes over all pairs. Modes run one after another,
  not interleaved, so expect about ±10% noise.

**Negative controls:**
1. `portal` reproduces the documented numbers exactly: `walls` 0.06 r (r = 0.5) and 0.11 r
   (r = 1), Courtyard 0.23 r.
2. The measure catches real wall crossings. With `dump=1`, `bench` r = 0.5, pair
   (162.49, 90.33) -> (233.30, 159.83) under `bisector` cuts straight through the box with corners
   (217.36, 128.42) and (223.21, 128.66). The script reports clearance 0 for it.

## Results (150 pairs; clearance in units of r)

### Headline

`props` at r = 1 has only 7 pairs, and r = 2 has none: the map is too dense for both ends to be
2r from a wall.

| scene | r | portal min / p5 / p50 | checked min / p5 / p50 | checked-t min / p5 / p50 | bisector-t min / p5 / cross | len mean / max (checked-t) | µs/call portal → checked-t |
|---|---|---|---|---|---|---|---|
| walls | 0.5 | 0.06 / 0.06 / 0.07 | 0.71 / 0.71 / 0.71 | **1.00 / 1.00 / 1.00** | 1.00 / 1.00 / 0% | 1.0065 / 1.0133 | 90 → 207 |
| walls | 1 | 0.11 / 0.11 / 0.30 | 0.71 / 0.71 / 0.71 | **1.00 / 1.00 / 1.00** | 1.00 / 1.00 / 0% | 1.0098 / 1.0319 | 57 → 120 |
| walls | 2 | 0.24 / 0.45 / 0.62 | 0.71 / 0.71 / 0.71 | 0.24 / 1.00 / 1.00 | 1.00 / 1.00 / 0% | 1.0133 / 1.0432 | 50 → 88 |
| Courtyard | 0.5 | 0.23 / 0.46 / 0.91 | 0.71 / 0.71 / 0.86 | **1.00 / 1.00 / 1.19** | 1.00 / 1.00 / 0% | 1.0059 / 1.0270 | 28 → 47 |
| Courtyard | 1 | 0.23 / 0.71 / 0.93 | 0.71 / 0.71 / 0.88 | **1.00 / 1.00 / 1.21** | 1.00 / 1.00 / 0% | 1.0109 / 1.0458 | 29 → 46 |
| Courtyard | 2 | 0.71 / 0.71 / 0.71 | 0.71 / 0.71 / 0.75 | 0.71 / 0.71 / 0.97 | 0.90 / 0.96 / 0% (len max 1.28) | 1.0192 / 1.0497 | 30 → 50 |
| bench | 0.5 | 0.08 / 0.16 / 0.56 | 0.12 / 0.71 / 0.72 | 0.08 / 0.89 / 1.00 | 0.00 / 0.90 / 0.7% | 1.0037 / 1.0245 | 255 → 447 |
| bench | 1 | 0.01 / 0.07 / 0.57 | 0.03 / 0.19 / 0.71 | 0.03 / 0.15 / 1.00 | 0.00 / 0.03 / 4.7% | 1.0092 / 1.0378 | 242 → 436 |
| bench | 2 | 0.01 / 0.11 / 0.49 | 0.01 / 0.14 / 0.71 | 0.01 / 0.12 / 0.61 | 0.00 / 0.00 / 8.0% | 1.0160 / 1.0497 | 255 → 476 |
| props | 0.5 | 0.01 / 0.10 / 0.45 | 0.02 / 0.19 / 0.71 | 0.02 / 0.06 / 0.86 | 0.00 / 0.03 / 3.3% | 1.0167 / 1.0477 | 182 → 353 |

Share of paths below 0.5 r and below 0.9 r, and how often `checked*` rejected the offset path:

| scene | r | portal <0.5r / <0.9r | checked <0.5r / <0.9r (rejected) | checked-t <0.5r / <0.9r (rejected) |
|---|---|---|---|---|
| walls | 0.5 | 90% / 99% | 0% / 99% (0) | 0% / 0% (0) |
| walls | 1 | 73% / 95% | 0% / 94% (0) | 0% / 0% (0) |
| walls | 2 | 41% / 85% | 0% / 93% (1) | 0.7% / 1.3% (2) |
| Courtyard | 0.5 | 6% / 45% | 0% / 55% (0) | 0% / 0% (0) |
| Courtyard | 1 | 1.3% / 43% | 0% / 58% (0) | 0% / 0% (0) |
| Courtyard | 2 | 0% / 79% | 0% / 78% (0) | 0% / 43% (70 of 150) |
| bench | 0.5 | 43% / 92% | 0.7% / 93% (1) | 2.7% / 6% (3) |
| bench | 1 | 43% / 95% | 8.7% / 94% (5) | 10% / 27% (7) |
| bench | 2 | 58% / 96% | 20% / 97% (15) | 35% / 72% (41) |
| props | 0.5 | 58% / 93% | 19% / 96% (15) | 33% / 52% (31) |

The full table, with all seven modes, mean/p95/max length and the fallback counters, is in the
appendix.

## Findings

1. **The low clearance is at turns, not on straight stretches.** In 79-100% of `portal` paths the
   worst point is within 1.5r of a turn waypoint. It's the first mechanism in the Funnel doc: a
   portal that leaves a wall corner nearly parallel to a wall edge puts the offset point only
   r sin(a) off that wall. On `walls` (0.5-stud-thick walls) that gives 0.06 r. The doc's
   "straight stretches can pass within 0.06 r" framing (repeated in the handoff and in the Roblox
   comparison) should say "turns".
2. **Any off-portal offset distorts the corridor.** That covers `bisector`, `arc` and `-t`. The
   simple stupid funnel is correct only when each portal lies on the shared triangle edge. A
   portal end moved off its edge rotates the portal about its other end, which can:
   - **sweep the portal past a wall.** The path then cuts through an obstacle: 0.7-8% of `bench`
     paths and 1-3% of `props` paths cross a wall under unchecked `bisector*`/`arc`;
   - **sweep the portal past the goal or the next portal.** This forces a detour, for example
     `walls` r = 2, (75.5, 66.5) -> (119.2, 10.3) runs 1.33x via a flat wall vertex at (128, 0).
     Length max reaches 1.20-1.37x.

   The inversion guard (ends reversed along the portal) catches none of the crossings. They are
   not inversions.
3. **On sparse maps the offset point works, and `-t` gives exactly r.** On `walls` and Courtyard
   (r ≤ 1) `bisector-t` keeps every path at 1.00 r or more, for +0.6-1.1% mean length (max +4.6%).
   Plain `bisector` floors at 0.71 r: one waypoint per 90° corner leaves a 45° chord. `-t`
   lengthens the offset to r / sin(θ/2), so the chord is tangent.
4. **On dense maps the post-check is mandatory and caps the gain.**
   - `checked` and `checked-t` never cross a wall (cross = 0% everywhere).
   - But they reject 10-47% of paths where it matters (`bench` r = 2, `props`, Courtyard r = 2
     under `-t`), and a rejected path falls back to today's path.
   - So the tail barely moves: `bench` min stays 0.01-0.12 r, against 0.01-0.08 today.
   - The median does move: `bench` p50 0.56 → 1.00 r at r = 0.5.
5. **On-portal alternatives (`sine`, and `arc` inside its range) are safe but barely help.**
   `sine`'s points can't leave the portal, and it is capped at half the portal. Near thin walls
   the portals are slivers lying within r of the wall along their whole length. `walls`: 0.06 →
   0.10 r. `arc` floors at 0.46-0.61 r on `walls` and still crosses walls through its off-portal
   arc ends.
6. **Time.** FindPath goes from +40% to +130% per call (for example `walls` r = 0.5: 90 → 207 µs;
   `bench`: 255 → 447 µs). A profile on `walls` (200 paths, r = 0.5):
   - the funnel's own time rose from 2.3 ms to 15 ms. About 5 ms of that is the height/owner
     `Queries.Walk` calls; most of the rest is the per-portal-end fan walks;
   - `checked` adds one `Walk` per output segment plus a second, along-portal pull: about 15-25%
     more.

   Precomputing each wall vertex's sector(s) at Build would remove most of the fan-walk cost. The
   post-check can't be removed.
7. **The specs don't catch the dangerous case.**
   - `bisector` and `checked`: 271/271 pass. The specs only use small, sparse fixtures.
   - `bisector-t`, `checked-t`: 270/271. "Corners are passed at the agent's radius" expects corner
     waypoints exactly r from their corner. `-t` puts a 90° corner's waypoint at r/sin(135°) ≈
     1.41 r. That is an expected new number, not a bug: the spec would assert ≥ r from the walls
     instead.
   - `arc`, `sine`: 270/271. The same spec gets 5 waypoints instead of 4, because a corner splits
     into two offset points. That is expected for those variants.
   - No spec has a dense-map pair. Shipping any off-portal mode needs a spec built from the
     `bench` pair above as a negative control.
8. **A cheap exact clearance check exists.** The minimum distance between two segments is reached
   at an endpoint of one of them. So a path has clearance ≥ r exactly when (a) every waypoint is
   ≥ r from the walls, and (b) every path segment is ≥ r from every wall *vertex* near it. That
   check is cheaper and stricter than the `Walk` post-check, and a radius-aware funnel could
   assert it.

## Options

| | clearance (worst / typical) | length | FindPath time | spec churn | risk |
|---|---|---|---|---|---|
| **A. Keep today's funnel** (fix the doc's "straight stretches" wording) | 0.01-0.24 r min, p50 0.07-0.93 r | 1.00 | 1.00x | none | known and documented |
| **B. Opt-in `checked-t`** (a `QueryFilter` key, e.g. `CornerOffset = "Bisector"`) | sparse maps: **1.00 r** min; dense: min unchanged (0.01-0.08 r), p50 up to 1.00 r; < 0.5r share 43% → 3% (`bench` 0.5) but 58% → 35% only at r = 2 | +0.6-1.9% mean, ≤ +5% max (the 1.05 guard) | 1.6-2.3x (about 1.3-1.5x with precomputed sectors, estimated) | 1 spec gains a 1.41 r expectation (only in the opt-in path); needs new dense-map negative-control specs | two funnels to maintain and mutation-test; the gain disappears exactly where the guard rejects |
| **C. Replace with an offset funnel** (`checked-t` as default) | as B | as B | as B, on every query | 1 spec changes; seam spec still passes | ships a mechanism whose unchecked form cuts through walls on 0.7-8% of dense-map paths; correctness rests on the post-check |

**Not prototyped, the sound version of C: a radius-aware funnel.** Keep the portals on their
edges. Treat every wall-corner portal end as an r-circle: the funnel sides become tangent lines,
and the apex is a circle (Demyen's modified funnel). Then:
- no corridor distortion, so no crossings or detours;
- with the endpoint check above, the result is r by construction at every wall corner the corridor
  touches.

It would rewrite `pull`, not `push`, and is a ticket of its own.

## Recommendation

**A now, and open a ticket for the radius-aware funnel if real clearance is a product need. Not B
or C on this prototype.**
- Off-portal offsetting is unsound on its own (finding 2). Its safe form is a guard that falls
  back to today's path on 10-47% of dense-map paths. So it fixes sparse maps, which were never the
  bad case for agents getting stuck, and leaves the dense-map tail where it was.
- It costs up to 2.3x FindPath time. B would be an honest opt-in for sparse maps only, but it
  means two funnels to mutation-test.
- The cheap, certain wins are:
  - correct the Funnel doc and `QueryFilter.AgentRadius` wording: the low clearance is at turns
    (finding 1);
  - keep `funnel_clearance.luau` as the yardstick for a future radius-aware funnel.

## Not measured, or uncertain

- **Multi-floor and seam corners:** not in the bench, which is all flat single-floor scenes. The
  seam-corner code path is exercised only by the spec suite, which passes in every mode. Whether
  seam corners get a sensible offset in practice is unverified.
- **Pinch vertices:** handled by construction (the fan walk stays in the portal's local sector). No
  dedicated case was measured.
- **Coverage gaps:** `terrain` is not in the bench. `props` has only 7 pairs at r = 1 and none at
  r = 2.
- **Timing:** single sequential runs per mode, about ±10%. The "precomputed sectors" saving is
  estimated from a profile, not built.
- **Height:** off-portal points take their height from a surface walk. That is exact on the flat
  bench scenes and untested on slopes.
- **Gates not run:** the mutation gate (as instructed) and luau-lsp analyze on the prototype.
- **`CHECK_SLACK`:** 1.05 is a guess. At 1.02, `checked-t` rejected far more paths, because `-t`
  legitimately lengthens paths by 1-3%.

## Reproduce

```sh
git -C C:/Users/Logan/Documents/GitHub/TableManager worktree add .claude/worktrees/g-bisector proto/g-bisector
# copy lib/navmesh/_Index, ConstrainedDelaunay.lua, wally.lock into the worktree's lib/navmesh/
lune run tools/navmesh/bench/funnel_clearance.luau pairs=150        # about 12 s
lune run tools/navmesh/bench/funnel_clearance.luau pairs=20 dump=1  # bad paths, with waypoints
NAVMESH_FUNNEL=checked-t lune run tools/navmesh/specs.luau          # also bisector, checked, bisector-t, arc, sine
```

## Appendix: full output (pairs=150)

```
| scene | r | mode | n | min | p5 | p50 | cross | <0.5r | <0.9r | turn% | len mean | len p95 | len max | us/call | fallbacks |
| Courtyard | 0.5 | portal | 150 | 0.23 | 0.46 | 0.91 | 0.0% | 6.0% | 45.3% | 89% | 1 | 1 | 1 | 28 | - |
| Courtyard | 0.5 | bisector | 150 | 0.71 | 0.71 | 0.86 | 0.0% | 0.0% | 55.3% | 89% | 0.9997 | 1.0018 | 1.0042 | 39 | 0/835 (inv 0) rej 0 |
| Courtyard | 0.5 | checked | 150 | 0.71 | 0.71 | 0.86 | 0.0% | 0.0% | 55.3% | 89% | 0.9997 | 1.0018 | 1.0042 | 47 | 0/835 (inv 0) rej 0 |
| Courtyard | 0.5 | bisector-t | 150 | 1.00 | 1.00 | 1.19 | 0.0% | 0.0% | 0.0% | 93% | 1.0059 | 1.0184 | 1.0270 | 43 | 0/835 (inv 0) rej 0 |
| Courtyard | 0.5 | checked-t | 150 | 1.00 | 1.00 | 1.19 | 0.0% | 0.0% | 0.0% | 93% | 1.0059 | 1.0184 | 1.0270 | 47 | 0/835 (inv 0) rej 0 |
| Courtyard | 0.5 | arc | 150 | 0.60 | 0.67 | 0.93 | 0.0% | 0.0% | 40.7% | 90% | 1.0051 | 1.0024 | 1.3668 | 38 | 0/835 (inv 0) rej 0 |
| Courtyard | 0.5 | sine | 150 | 0.44 | 0.58 | 0.91 | 0.0% | 2.7% | 38.7% | 89% | 1.0001 | 1.0008 | 1.0036 | 34 | - |
| Courtyard | 1 | portal | 150 | 0.23 | 0.71 | 0.93 | 0.0% | 1.3% | 43.3% | 93% | 1 | 1 | 1 | 29 | - |
| Courtyard | 1 | bisector | 150 | 0.71 | 0.71 | 0.88 | 0.0% | 0.0% | 58.0% | 91% | 0.9996 | 1.0035 | 1.0068 | 41 | 0/812 (inv 0) rej 0 |
| Courtyard | 1 | checked | 150 | 0.71 | 0.71 | 0.88 | 0.0% | 0.0% | 58.0% | 91% | 0.9996 | 1.0035 | 1.0068 | 49 | 0/812 (inv 0) rej 0 |
| Courtyard | 1 | bisector-t | 150 | 1.00 | 1.00 | 1.21 | 0.0% | 0.0% | 0.0% | 94% | 1.0109 | 1.0318 | 1.0458 | 39 | 0/812 (inv 0) rej 0 |
| Courtyard | 1 | checked-t | 150 | 1.00 | 1.00 | 1.21 | 0.0% | 0.0% | 0.0% | 94% | 1.0109 | 1.0318 | 1.0458 | 46 | 0/812 (inv 0) rej 0 |
| Courtyard | 1 | arc | 150 | 0.65 | 0.85 | 0.94 | 0.0% | 0.0% | 27.3% | 93% | 1.0008 | 1.0042 | 1.0089 | 38 | 0/812 (inv 0) rej 0 |
| Courtyard | 1 | sine | 150 | 0.36 | 0.75 | 0.93 | 0.0% | 0.7% | 31.3% | 93% | 1.0003 | 1.0016 | 1.0049 | 34 | - |
| Courtyard | 2 | portal | 150 | 0.71 | 0.71 | 0.71 | 0.0% | 0.0% | 78.7% | 100% | 1 | 1 | 1 | 30 | - |
| Courtyard | 2 | bisector | 150 | 0.71 | 0.71 | 0.75 | 0.0% | 0.0% | 78.0% | 98% | 1.0001 | 1.0060 | 1.0088 | 42 | 0/830 (inv 0) rej 0 |
| Courtyard | 2 | checked | 150 | 0.71 | 0.71 | 0.75 | 0.0% | 0.0% | 78.0% | 98% | 1.0001 | 1.0060 | 1.0088 | 48 | 0/830 (inv 0) rej 0 |
| Courtyard | 2 | bisector-t | 150 | 0.90 | 0.96 | 1.00 | 0.0% | 0.0% | 0.0% | 100% | 1.0561 | 1.1225 | 1.2783 | 42 | 145/830 (inv 145) rej 0 |
| Courtyard | 2 | checked-t | 150 | 0.71 | 0.71 | 0.97 | 0.0% | 0.0% | 42.7% | 100% | 1.0192 | 1.0491 | 1.0497 | 50 | 145/830 (inv 145) rej 70 |
| Courtyard | 2 | arc | 150 | 0.85 | 0.85 | 0.85 | 0.0% | 0.0% | 75.3% | 100% | 1.0038 | 1.0087 | 1.0114 | 41 | 0/830 (inv 0) rej 0 |
| Courtyard | 2 | sine | 150 | 0.75 | 0.75 | 0.75 | 0.0% | 0.0% | 75.3% | 100% | 1.0012 | 1.0035 | 1.0042 | 36 | - |
| props | 0.5 | portal | 150 | 0.01 | 0.10 | 0.45 | 0.0% | 58.0% | 93.3% | 93% | 1 | 1 | 1 | 182 | - |
| props | 0.5 | bisector | 150 | 0.00 | 0.35 | 0.71 | 2.0% | 16.0% | 96.7% | 88% | 1.0105 | 1.1000 | 1.1978 | 298 | 42/7612 (inv 0) rej 0 |
| props | 0.5 | checked | 150 | 0.02 | 0.19 | 0.71 | 0.0% | 19.3% | 96.0% | 91% | 1.0017 | 1.0109 | 1.0324 | 347 | 42/7612 (inv 0) rej 15 |
| props | 0.5 | bisector-t | 150 | 0.00 | 0.03 | 0.88 | 3.3% | 30.0% | 50.7% | 75% | 1.0376 | 1.1446 | 1.2749 | 326 | 136/7612 (inv 87) rej 0 |
| props | 0.5 | checked-t | 150 | 0.02 | 0.06 | 0.86 | 0.0% | 33.3% | 52.0% | 85% | 1.0167 | 1.0372 | 1.0477 | 353 | 136/7612 (inv 87) rej 31 |
| props | 0.5 | arc | 150 | 0.00 | 0.09 | 0.71 | 1.3% | 28.0% | 88.7% | 91% | 1.0068 | 1.0203 | 1.2250 | 291 | 28/7612 (inv 0) rej 0 |
| props | 0.5 | sine | 150 | 0.01 | 0.08 | 0.50 | 0.0% | 50.0% | 90.7% | 89% | 1.0024 | 1.0091 | 1.0291 | 236 | - |
| props | 1 | portal | 7 | 0.01 | 0.01 | 0.01 | 0.0% | 100.0% | 100.0% | 100% | 1 | 1 | 1 | 85 | - |
| props | 1 | bisector | 7 | 0.56 | 0.56 | 0.56 | 0.0% | 0.0% | 100.0% | 100% | 1.0127 | 1.0135 | 1.0135 | 126 | 0/139 (inv 0) rej 0 |
| props | 1 | checked | 7 | 0.56 | 0.56 | 0.56 | 0.0% | 0.0% | 100.0% | 100% | 1.0127 | 1.0135 | 1.0135 | 126 | 0/139 (inv 0) rej 0 |
| props | 1 | bisector-t | 7 | 0.46 | 0.46 | 0.46 | 0.0% | 85.7% | 100.0% | 100% | 1.0292 | 1.0530 | 1.0530 | 111 | 2/139 (inv 2) rej 0 |
| props | 1 | checked-t | 7 | 0.46 | 0.46 | 0.46 | 0.0% | 100.0% | 100.0% | 100% | 1.0216 | 1.0252 | 1.0252 | 126 | 2/139 (inv 2) rej 1 |
| props | 1 | arc | 7 | 0.48 | 0.48 | 0.48 | 0.0% | 85.7% | 100.0% | 14% | 1.0080 | 1.0084 | 1.0084 | 105 | 0/139 (inv 0) rej 0 |
| props | 1 | sine | 7 | 0.01 | 0.01 | 0.01 | 0.0% | 100.0% | 100.0% | 100% | 1.0005 | 1.0006 | 1.0006 | 93 | - |
| props | 2 | - | 0 | no pairs with both ends 2r from walls |
| bench | 0.5 | portal | 150 | 0.08 | 0.16 | 0.56 | 0.0% | 42.7% | 92.0% | 91% | 1 | 1 | 1 | 255 | - |
| bench | 0.5 | bisector | 150 | 0.00 | 0.71 | 0.72 | 0.7% | 0.7% | 92.7% | 93% | 1.0003 | 1.0019 | 1.0050 | 376 | 6/8789 (inv 0) rej 0 |
| bench | 0.5 | checked | 150 | 0.12 | 0.71 | 0.72 | 0.0% | 0.7% | 92.7% | 94% | 1.0004 | 1.0019 | 1.0050 | 429 | 6/8789 (inv 0) rej 1 |
| bench | 0.5 | bisector-t | 150 | 0.00 | 0.90 | 1.00 | 0.7% | 2.0% | 4.7% | 96% | 1.0050 | 1.0080 | 1.0964 | 383 | 19/8789 (inv 3) rej 0 |
| bench | 0.5 | checked-t | 150 | 0.08 | 0.89 | 1.00 | 0.0% | 2.7% | 6.0% | 97% | 1.0037 | 1.0074 | 1.0245 | 447 | 19/8789 (inv 3) rej 3 |
| bench | 0.5 | arc | 150 | 0.00 | 0.32 | 0.77 | 0.7% | 14.0% | 88.7% | 95% | 1.0003 | 1.0015 | 1.0036 | 383 | 1/8789 (inv 0) rej 0 |
| bench | 0.5 | sine | 150 | 0.08 | 0.16 | 0.59 | 0.0% | 38.7% | 91.3% | 93% | 1.0008 | 1.0026 | 1.0211 | 315 | - |
| bench | 1 | portal | 150 | 0.01 | 0.07 | 0.57 | 0.0% | 43.3% | 94.7% | 94% | 1 | 1 | 1 | 242 | - |
| bench | 1 | bisector | 150 | 0.00 | 0.05 | 0.71 | 3.3% | 8.7% | 94.0% | 92% | 1.0015 | 1.0036 | 1.0659 | 366 | 18/8769 (inv 0) rej 0 |
| bench | 1 | checked | 150 | 0.03 | 0.19 | 0.71 | 0.0% | 8.7% | 94.0% | 95% | 1.0008 | 1.0033 | 1.0141 | 430 | 18/8769 (inv 0) rej 5 |
| bench | 1 | bisector-t | 150 | 0.00 | 0.03 | 1.00 | 4.7% | 10.0% | 27.3% | 86% | 1.0096 | 1.0221 | 1.0633 | 382 | 70/8769 (inv 26) rej 0 |
| bench | 1 | checked-t | 150 | 0.03 | 0.15 | 1.00 | 0.0% | 10.0% | 27.3% | 91% | 1.0092 | 1.0214 | 1.0378 | 436 | 70/8769 (inv 26) rej 7 |
| bench | 1 | arc | 150 | 0.00 | 0.13 | 0.73 | 2.0% | 24.7% | 92.7% | 93% | 1.0011 | 1.0026 | 1.0417 | 364 | 2/8769 (inv 0) rej 0 |
| bench | 1 | sine | 150 | 0.01 | 0.07 | 0.64 | 0.0% | 32.7% | 93.3% | 90% | 1.0021 | 1.0113 | 1.0544 | 314 | - |
| bench | 2 | portal | 150 | 0.01 | 0.11 | 0.49 | 0.0% | 58.0% | 96.0% | 79% | 1 | 1 | 1 | 255 | - |
| bench | 2 | bisector | 150 | 0.00 | 0.00 | 0.71 | 6.7% | 16.7% | 97.3% | 85% | 1.0055 | 1.0287 | 1.2065 | 416 | 33/10145 (inv 0) rej 0 |
| bench | 2 | checked | 150 | 0.01 | 0.14 | 0.71 | 0.0% | 20.0% | 97.3% | 93% | 1.0009 | 1.0072 | 1.0285 | 467 | 33/10145 (inv 0) rej 15 |
| bench | 2 | bisector-t | 150 | 0.00 | 0.00 | 0.66 | 8.0% | 32.7% | 72.0% | 77% | 1.0405 | 1.1340 | 1.3309 | 417 | 182/10145 (inv 143) rej 0 |
| bench | 2 | checked-t | 150 | 0.01 | 0.12 | 0.61 | 0.0% | 35.3% | 72.0% | 82% | 1.0160 | 1.0438 | 1.0497 | 476 | 182/10145 (inv 143) rej 41 |
| bench | 2 | arc | 150 | 0.00 | 0.00 | 0.54 | 7.3% | 42.7% | 94.0% | 66% | 1.0046 | 1.0079 | 1.3223 | 389 | 8/10145 (inv 0) rej 0 |
| bench | 2 | sine | 150 | 0.01 | 0.12 | 0.49 | 0.0% | 53.3% | 96.0% | 69% | 1.0012 | 1.0031 | 1.0226 | 329 | - |
| walls | 0.5 | portal | 150 | 0.06 | 0.06 | 0.07 | 0.0% | 90.0% | 98.7% | 100% | 1 | 1 | 1 | 90 | - |
| walls | 0.5 | bisector | 150 | 0.71 | 0.71 | 0.71 | 0.0% | 0.0% | 98.7% | 100% | 1.0018 | 1.0035 | 1.0050 | 167 | 0/5147 (inv 0) rej 0 |
| walls | 0.5 | checked | 150 | 0.71 | 0.71 | 0.71 | 0.0% | 0.0% | 98.7% | 100% | 1.0018 | 1.0035 | 1.0050 | 212 | 0/5147 (inv 0) rej 0 |
| walls | 0.5 | bisector-t | 150 | 1.00 | 1.00 | 1.00 | 0.0% | 0.0% | 0.0% | 100% | 1.0065 | 1.0112 | 1.0133 | 173 | 0/5147 (inv 0) rej 0 |
| walls | 0.5 | checked-t | 150 | 1.00 | 1.00 | 1.00 | 0.0% | 0.0% | 0.0% | 100% | 1.0065 | 1.0112 | 1.0133 | 207 | 0/5147 (inv 0) rej 0 |
| walls | 0.5 | arc | 150 | 0.46 | 0.49 | 0.50 | 0.0% | 56.7% | 96.7% | 100% | 1.0017 | 1.0030 | 1.0039 | 166 | 0/5147 (inv 0) rej 0 |
| walls | 0.5 | sine | 150 | 0.10 | 0.11 | 0.12 | 0.0% | 75.3% | 96.0% | 99% | 1.0116 | 1.0266 | 1.0549 | 130 | - |
| walls | 1 | portal | 150 | 0.11 | 0.11 | 0.30 | 0.0% | 73.3% | 94.7% | 99% | 1 | 1 | 1 | 57 | - |
| walls | 1 | bisector | 150 | 0.71 | 0.71 | 0.71 | 0.0% | 0.0% | 94.0% | 99% | 1.0024 | 1.0065 | 1.0106 | 105 | 0/2669 (inv 0) rej 0 |
| walls | 1 | checked | 150 | 0.71 | 0.71 | 0.71 | 0.0% | 0.0% | 94.0% | 99% | 1.0024 | 1.0065 | 1.0106 | 120 | 0/2669 (inv 0) rej 0 |
| walls | 1 | bisector-t | 150 | 1.00 | 1.00 | 1.00 | 0.0% | 0.0% | 0.0% | 99% | 1.0098 | 1.0241 | 1.0319 | 99 | 0/2669 (inv 0) rej 0 |
| walls | 1 | checked-t | 150 | 1.00 | 1.00 | 1.00 | 0.0% | 0.0% | 0.0% | 99% | 1.0098 | 1.0241 | 1.0319 | 120 | 0/2669 (inv 0) rej 0 |
| walls | 1 | arc | 150 | 0.34 | 0.61 | 0.69 | 0.0% | 0.7% | 90.7% | 99% | 1.0029 | 1.0070 | 1.0171 | 99 | 0/2669 (inv 0) rej 0 |
| walls | 1 | sine | 150 | 0.19 | 0.19 | 0.57 | 0.0% | 48.0% | 87.3% | 97% | 1.0123 | 1.0322 | 1.0582 | 76 | - |
| walls | 2 | portal | 150 | 0.24 | 0.45 | 0.62 | 0.0% | 40.7% | 84.7% | 98% | 1 | 1 | 1 | 50 | - |
| walls | 2 | bisector | 150 | 0.71 | 0.71 | 0.71 | 0.0% | 0.0% | 92.0% | 98% | 1.0038 | 1.0065 | 1.3318 | 73 | 1/1634 (inv 0) rej 0 |
| walls | 2 | checked | 150 | 0.71 | 0.71 | 0.71 | 0.0% | 0.0% | 92.7% | 98% | 1.0016 | 1.0062 | 1.0276 | 86 | 1/1634 (inv 0) rej 1 |
| walls | 2 | bisector-t | 150 | 1.00 | 1.00 | 1.00 | 0.0% | 0.0% | 0.0% | 99% | 1.0141 | 1.0308 | 1.0580 | 73 | 5/1634 (inv 0) rej 0 |
| walls | 2 | checked-t | 150 | 0.24 | 1.00 | 1.00 | 0.0% | 0.7% | 1.3% | 99% | 1.0133 | 1.0280 | 1.0432 | 88 | 5/1634 (inv 0) rej 2 |
| walls | 2 | arc | 150 | 0.33 | 0.70 | 0.83 | 0.0% | 1.3% | 68.7% | 98% | 1.0066 | 1.0076 | 1.3317 | 67 | 0/1634 (inv 0) rej 0 |
| walls | 2 | sine | 150 | 0.36 | 0.57 | 0.80 | 0.0% | 3.3% | 67.3% | 93% | 1.0068 | 1.0230 | 1.0719 | 58 | - |
cross-check: max |exact - sampled FindDistanceToWall| = 0.0090 studs
```
