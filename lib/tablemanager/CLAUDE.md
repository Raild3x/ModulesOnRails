# TableManager — package context

A pure-Luau library for managing and observing data in a table. Entry point is
`src/TableManager.luau` — this package must **never** gain a `src/init.luau`
(publishing generates one; a real one breaks Lune testing).

Run its tests: `lune run coverage.luau package=tablemanager` (from the repo root).

## Behavioral contract

`src/Docs/CONTRACT.md` is the authoritative spec for observable behavior
(paths, fire modes, batching semantics). Read it before changing behavior;
update it when behavior intentionally changes. `src/Docs/EXAMPLES.md` and
`src/Docs/PROXY_USERDATA_NOTES.md` cover usage patterns and proxy edge cases.

The `src/Docs/TM_*.luau` files are moonwave guide pages (doc comments only, no
code) registered in the root `moonwave.toml` `classOrder`. Notable:
`TM_Wildcards.luau` documents wildcard (`*`) path fan-out in
Set/Update/Increment/GetMatching — a recent feature whose logic lives in
`PathHelpers.luau`, `Batching/`, and `Propagation.luau`.

## Architecture map

| Area | Files | Role |
| --- | --- | --- |
| Facade | `TableManager.luau`, `Mutator.luau`, `TMTypes.luau` | Public API, mutation entry points, shared types |
| Paths | `PathHelpers.luau`, `SchemaNavigator.luau` | Path parsing/expansion (incl. wildcards), schema traversal |
| Change detection | `Diffing/` (`ChangeDetector`, `Diff`, `ArrayDiff`, `Coverage`) | What changed between states |
| Baseline | `Baseline/` (`Baseline`, `ShadowNode`) | Shadow copy the diffing compares against |
| Batching | `Batching/` (`BatchFlush`, `CoalescedFlush`, `BatchUtils`) | Deferred/coalesced flush of changes |
| Listeners | `Listening/` (`ListenerRegistry`, `Emitter`, `IsDeferred`) | Subscription storage and event dispatch |
| Fan-out | `Propagation.luau`, `IgnoreTrie.luau` | Routing changes to listeners, suppression |
| Views | `ForMap.luau`, `ProxyManager.luau`, `OpaqueRegistry.luau` | Reactive For/Map views, direct-access proxies, opaque values |

Specs live in `src/Tests/`. Coverage is high (~95% lines) — new behavior needs
matching specs to keep it that way.
