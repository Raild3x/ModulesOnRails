# TableReplicator — package context

Replicates a TableManager instance from server to client. This is a
**datamodel package**: `src/init.luau` is the real entry point, exposing
`.Server` and `.Client`. Tests therefore run on the Roblox Studio pipeline
(`run-in-roblox`), not Lune — expect a Studio launch.

Run its tests: `lune run coverage.luau package=tablereplicator` (from the repo root).

## Architecture

`src/Docs/ARCHITECTURE.md` is the internals doc — read it before structural
changes. The `src/Docs/TR_*.luau` files are moonwave guide pages (custom
remotes, discovery/targeting, namespaces/tokens, parent-child,
performance/ordering).

- `Server/`: `ServerReplicator`, `ReplicationScope` (who receives what),
  `FrameCoordinator` (per-frame send scheduling), `ServerCustomRemote`.
- `Client/`: `ClientReplicator`, `OpApplier` (applies received ops to the
  local TableManager), `ClientCustomRemote`.
- `Shared/`: `BaseReplicator`, `OpBuffer` (op ordering/dedup),
  `TokenCache`, `Types`, plus `Serialization/` and `Transport/`.

Known exception: this package currently reaches into `tablemanager` via a
relative cross-package require (pending tablemanager's next wally release) —
don't "fix" that without checking `tools/coverage/lune/adapters/modules_on_rails.luau`,
whose Studio scaffold mounts all of `lib/` to support it.

## Writing specs

Specs live in `src/Tests/`. Multi-client end-to-end specs do not need real
networking: `src/Tests/Helpers/FakeIntermediary.luau` is a fake server↔client
transport bridge (with `FakeManager.luau` and `SpecUtils.luau` alongside).
See `TR.EndToEnd.spec.luau` / `TR.ClientReplicator.spec.luau` for the pattern.
