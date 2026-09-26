# 06: CDT Storage plus contract suite

**What to build:** The CDT's layout is owned by one module that can be swapped behind a proven contract.

**Blocked by:** 01

**Status:** done

- [x] The S1 Storage module: f64 coordinate buffer, i32 topology buffers, the coverage CSR, input/vertex maps, doubling growth, `Reserve`
- [x] A contract suite round-trips every accessor, grows past capacity, passes `PlainData.Check`, and asserts every exported function has a case

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Result
- **The S1 Storage module:** f64 coordinates; i32 buffers for triangles, neighbours, coverage
  heads, the input/vertex maps and winding.
  - Coverage is a linked-list node pool rather than CSR, because coverage must move between
    edges during construction (the spec is updated).
  - Also `Compact` and `DropLeadingVertices` for the triangulator.
- **Contract suite:** 11 cases, including a completeness test. Negative control: adding
  `Storage.UntestedAccessor` fails the suite with its name.
