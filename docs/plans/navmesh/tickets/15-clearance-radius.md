# 15: Clearance and agent radius

**What to build:** Paths respect any agent radius; the P4 reach numbers come back to the user for the U-a ruling.

**Blocked by:** 14

**Status:** ready-for-agent

- [x] Wall-only clearance (SR4), radius-aware funnel offsets, the tile-corner fixture
- [x] The P4 reach benchmark, presented for U-a

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## P4 reach probe (2026-09-27): `tools/navmesh/bench/clearance_probe.luau`
- **Width model:** as shipped in `Clearance.luau`; see its docs.
- **Reach:** a width of 2r* can change only when a wall within r* of its triangle changes.
- **Setup:** Lune, default adaptive TileSize. Only corners between two crossable edges count.
- **Correction:** the numbers first shown for U-a came from a probe that also counted disc
  overlaps outside the triangle, which under-counted r* along wall loops. They were re-run with
  the shipped model below; the ruling holds.

| scene | tile | r* p50 / p90 / p99 / max (studs) | reach p99 / max (tiles) | capped at R = 2 / 4 / 8 | Build ms |
|---|---|---|---|---|---|
| props | 8 | 0.6 / 1.5 / 2.8 / 3.4 | 0.35 / 0.42 | 3.8% / 0.0% / 0.0% | 777 |
| bench | 32 | 2.1 / 5.5 / 8.1 / 11.8 | 0.25 / 0.37 | 52.3% / 22.8% / 1.1% | 668 |
| terrain | 256 | 11.7 / 32.1 / 52.4 / 65.0 | 0.20 / 0.25 | 91.4% / 81.6% / 63.7% | 254 |
| walls | 64 | 2.9 / 10.1 / 23.0 / 29.5 | 0.36 / 0.46 | 61.3% / 43.4% / 18.3% | 172 |
| open (TileSize 16) | 16 | 48.4 / 96.0 / 121.5 / 126.5 | 7.59 / 7.91 | 100% / 100% / 98.9% | 203 |

- On the default tiles every width depends only on the 3x3 neighbouring tiles. The one blow-up
  is open floor with small hand-set tiles.
- A cap trades that for truncated widths: at R = 8, 64% of the terrain corners are capped.
- **Ruling (U-a):** no cap by default, plus an optional `MaxAgentRadius`; see review.md.

## Built (2026-09-27)
- **Code:**
  - `Clearance.luau`: widths at Build, with `MaxAgentRadius` in Build.
  - Storage: corner and portal widths (f64), wall flags, the cap.
  - Search: corner widths between the entry and exit edges, and portal widths out of the start.
  - Funnel: wall-vertex portal ends shifted r along the portal.
  - `QueryFilter.AgentRadius`.
- **Width model, SR4 made exact:** r-discs around wall edges, cut to the region, must chain from
  corner C to the far edge AB.
  - A link counts only where its two discs meet inside the triangle. Counting overlaps outside
    it closed every passage, because wall loops are connected.
  - A wall vertex bounds; a free (tile, area, seam) vertex does not.
- **Speed:** clearance is the bulk of Build. Each step was checked against a width parity dump
  (all 36,915 readable widths within 6e-9 of the first exact version).

| step | props | bench | terrain | walls |
|---|---|---|---|---|
| first exact version | 5526 ms | 3609 | 1143 | 1007 |
| skip unreadable widths, shared pair gaps, facing edges only | 3046 | 2213 | 739 | 544 |
| prune links against the best chain | 1570 | 1419 | 547 | 359 |
| closed-form minima + regula falsi instead of golden section | 886 | 778 | 306 | 182 |
| each portal computed once, for both triangles | 753 | 597 | 228 | 129 |

  - Tried and dropped: a starting search radius other than 4 studs (+-15%, mixed), and per-edge
    link lower bounds (within noise).
  - Still about 0.1-0.25 ms per triangle. Ticket 18's `Update` must recompute only the dirty
    tiles' and the within-r* neighbours' triangles; measure there before optimizing further.
- **Specs** (`NavMesh.Clearance.spec`):
  - exact corridor widths;
  - widths never below twice the distance to the nearest wall;
  - SR4 open floor across tile corners;
  - Demyen's bound at wall corners;
  - fit up to half the gap and no wider;
  - corners passed at exactly r;
  - the cap, and validation.
  - Negative controls, each failing the right tests: links counted anywhere, free vertices
    bounding, no funnel offsets, no radius check.
