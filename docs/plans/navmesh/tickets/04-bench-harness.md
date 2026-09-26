# 04: Bench harness in the repo

**What to build:** Every later performance fork can be benchmarked with one documented command, using the audited method.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] The harness (layout generator, shuffled mesh, interleaved rounds, exact checksums, analytic memory) lives under `tools/navmesh/bench/`
- [ ] `verification.md` documents the command
- [ ] A smoke run reproduces the B1 ranking within documented drift

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".
