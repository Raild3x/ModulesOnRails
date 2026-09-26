# 01: Land the Phase 0 skeleton

**What to build:** The four packages and the Phase 0 tooling become a clean, committed baseline that the rest of the work builds on. Phase 0 stubs are gone, the DrawList type has a single owner in the CDT, and the public modules expose their submodules as fields.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] Phase 0 tooling committed: the `new_package` template fix, the `SAVE_SNAPSHOTS` opt-in, the `mutant_run` label fix, the in-repo sibling mechanism, the `.gitignore` CONTEXT exception, `render.luau`
- [ ] Stubs deleted (`_ProbeSibling`, the NavMeshDebug input-service stub, the float `OrientSign`) along with the specs that used them
- [ ] `DrawPrimitive`/`DrawList` live in the CDT's `DrawList` module; the debug modules import it; `SvgBackend` no longer defines it
- [ ] The CDT public module exposes `PlainData` and `Fixtures`; NavMesh exposes `Fixtures`; `NavMeshDebug` returns `{ NavMeshEditor }` (a placeholder is fine)
- [ ] `Fixtures.All` is built automatically and sorted by name; `Fixtures.ToInput(scenario)` returns a `TriangulateInput`
- [ ] `unreleased = true` on all four packages; `--!native` on the NavMesh module
- [ ] All four packages' suites are green on their pipelines; the core pipeline guard still passes

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".
