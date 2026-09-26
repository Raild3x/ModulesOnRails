# 06: CDT Storage plus contract suite

**What to build:** The CDT's layout is owned by one module that can be swapped behind a proven contract.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] The S1 Storage module: f64 coordinate buffer, i32 topology buffers, the coverage CSR, input/vertex maps, doubling growth, `Reserve`
- [ ] A contract suite round-trips every accessor, grows past capacity, passes `PlainData.Check`, and asserts every exported function has a case

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".
