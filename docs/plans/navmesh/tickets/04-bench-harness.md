# 04: Bench harness in the repo

**What to build:** Every later performance fork can be benchmarked with one documented command, using the audited method.

**Blocked by:** None (can start immediately)

**Status:** done

- [x] The harness (layout generator, shuffled mesh, interleaved rounds, exact checksums, analytic memory) lives under `tools/navmesh/bench/`
- [x] `verification.md` documents the command
- [x] A smoke run reproduces the B1 ranking within documented drift

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Result
- **Harness:** `tools/navmesh/bench/` holds `gen_layouts.py` (the audit's generator; its output
  dir is an argument), `Harness.luau`, `Mesh.luau`, and `run.py`.
  - `run.py` is the one command: generate, rojo build, N Studio runs, medians, gates.
  - Build and raw runs go to `.bench/` (gitignored).
- **Gates:** it exits 1 on an unfinished run, on flood disagreement, or when the shuffled-locate
  ranking (table/buffer topology) drops below 1.3x (audited 1.9x).
- **Smoke:** 2D 1.91x and 3D 1.89x, with per-cell values within drift of the audit.
- **Negative controls:** replaying the saved run gives 5/5 (swapped groups, tampered flood,
  deadline, empty output, real run).
- **Docs:** verification.md F9 "In-repo harness" gives the command and how to add a fork;
  bench.md points at it.
