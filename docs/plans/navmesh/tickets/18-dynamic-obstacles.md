# 18: Dynamic obstacles

**What to build:** Doors and crates can be added and removed at runtime, cheaply and safely.

**Blocked by:** 15, 16

**Status:** ready-for-agent

- [ ] Atomic `Update` with rollback (SR13), tile and vertex reclamation (SR14), snapped-bbox dirtying, clearance refresh
- [ ] Add then remove equals a fresh Build; toggling doesn't grow memory

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".
