# TableReplicator — Architecture

This document covers the internal architecture: how a single `manager:Set(...)` call on
the server ends up mutating a `TableManager` on the client. For the public API, see the
moonwave docs or the doc comments in `Server/ServerReplicator.luau` and
`Client/ClientReplicator.luau`.

## Module map

| Area | File | Responsibility |
| --- | --- | --- |
| Shared | `Shared/BaseReplicator.luau` | Identity, hierarchy (parent/children), tags, and static discovery (`GetAll`/`OnNew`/`ForEach`/...). Inherited by both `ServerReplicator` and `ClientReplicator`. |
| Shared | `Shared/Types.luau` | Shared type definitions: `BufferedOp`, `WireItem`, `WireMessage`, etc. |
| Shared | `Shared/TokenCache.luau` | Claim-free `ReplicationToken` handle cache (name ↔ object). Ownership ledger lives in `ServerReplicator`. |
| Shared | `Shared/OpBuffer.luau` | `NormalizeAppliedOp`: TableManager2 `AppliedOp` → wire-ready `BufferedOp`. |
| Shared | `Shared/Serialization/FlatCodec.luau` | Numeric-opcode wire item/message shapes. The codec used in the live send path. |
| Shared | `Shared/Serialization/RefCodec.luau` | "Model V" per-message table de-duplication. |
| Shared | `Shared/Serialization/BufferCodec.luau` | Byte-level value codec (not yet wired into the live send path). |
| Shared | `Shared/Transport/Protocol.luau` | Names/constants agreed on by both transports (RemoteEvent name, control strings). |
| Shared | `Shared/Transport/ServerTransport.luau` | Thin wrapper over the replication `RemoteEvent` (server side). |
| Shared | `Shared/Transport/ClientTransport.luau` | Thin wrapper over the replication `RemoteEvent` (client side) + `RequestData` handshake. |
| Server | `Server/ServerReplicator.luau` | Public server API. Owns structural sends (Create/Destroy/SetParent) and the request-data handshake. |
| Server | `Server/ReplicationScope.luau` | Per-top-level-subtree targeting state (active/pending/all players). |
| Server | `Server/FrameCoordinator.luau` | The single, server-wide ordering point for outbound **data ops**. |
| Client | `Client/ClientReplicator.luau` | Builds/destroys/reparents `ClientReplicator`s from incoming wire messages. |
| Client | `Client/OpApplier.luau` | Replays a decoded op list onto a client `TableManager` inside one `Batch`. |

## End-to-end flow: a write on the server, applied on the client

Two kinds of things travel over the wire:

- **Data ops** (`Set`/`ArrayInsert`/`ArrayRemove`/`ArraySet`/batch markers) —
  buffered per-frame by `FrameCoordinator` and sent at most once per player
  per frame.
- **Structural items** (`Create`/`Destroy`/`SetParent`) — sent immediately
  and synchronously by `ServerReplicator` itself, never buffered. Existence
  changes must be ordered relative to the call site (e.g. a child's `Create`
  must reach the client before any op for it does), so these skip the
  per-frame batching entirely.

The diagram below follows the data-op path, since that's the one with real
plumbing (buffer → flush → encode → transport):

```
 SERVER
 ──────────────────────────────────────────────────────────────────────
 [1] Application code
     manager:Set(...) / ArrayInsert / ArrayRemove / ArraySet / Batch(fn)
       │
       ▼  TableManager2 applies the write, fires OnApplied(AppliedOp)
 [2] ServerReplicator.new(...)
     manager:OnApplied(op) -> frameCoordinator:QueueOp(self._Scope, self.Id, op)
       │
       ▼
 [3] FrameCoordinator:QueueOp                 (uses OpBuffer.NormalizeAppliedOp)
     • op -> BufferedOp
     • capture the scope's active-player audience, cached per targeting "era"
       (ReplicationScope:GetActiveVersion) so a hot frame allocates at most
       one player list per scope
     • push { Scope, Audience, Id, Op } onto ONE global, ordered _entries list
       (every scope funnels through here, so cross-replicator/cross-manager
       order is preserved exactly as produced)
     • task.defer(task.defer(Flush))          -- coalesces the rest of this frame
       │
       ▼  (deferred, once per frame)
 [4] FrameCoordinator:Flush
     • group _entries by player, preserving original global arrival order
     • re-check scope:IsActive(player) LIVE (catches a player added/removed
       mid-frame so they never double-apply or receive a stale op)
     • collapse consecutive ops for the same replicator into one OpRun
       │
       ▼
 [5] FrameCoordinator:_SendFrame               -- the encode-and-send seam
     • FlatCodec.OpsItem(id, ops)      BufferedOp (string Kind) -> WireOpEntry (numeric Kind)
     • RefCodec.Encode(items)          dedup tables shared 2+ times -> Refs pool + {Marker=id} placeholders
     • FlatCodec.BuildMessage(items, refs) -> WireMessage { V, Items, Refs }
       │
       ▼
 [6] ServerTransport:SendMessage(player, message)
     remote:FireClient(player, message)
       │
       ▼
 ═══════════════════════════ RemoteEvent "Reliable" ═══════════════════════
       │
       ▼
 CLIENT
 ──────────────────────────────────────────────────────────────────────
 [7] ClientTransport
     remote.OnClientEvent -> MessageReceived:Fire(message)
       │
       ▼
 [8] ClientReplicator.handleMessage(message)       -- Items applied IN ORDER
     • Create     -> buildFromCreateItem: RefCodec.ResolveValue(Data),
                      new TableManager, BaseReplicator.new
     • Destroy    -> destroyInternal (recursive teardown of the subtree)
     • SetParent  -> child:_SetParentRefs(newParent)
     • Ops        -> FlatCodec.DecodeOps + RefCodec.ResolveValue (per op Value)
                      -> OpApplier.Apply(replicator.Manager, ops)
     (ChildAdded / creation listeners fire only AFTER the whole message has
      been built, so a later item in the same message always sees a
      fully-formed hierarchy)
       │
       ▼
 [9] OpApplier.Apply(manager, ops)
     manager:Batch(function()
         Set              -> manager:Set(path, value, true)
         ArraySet         -> manager:Set(path .. {index}, value, true)
         ArrayInsert      -> manager:ArrayInsert(path, index, value)
         ArrayRemove      -> manager:ArrayRemove(path, index)
         BatchBegin/End   -> manager:Suspend() / manager:Resume()
     end)
       │
       ▼
 [10] Client TableManager2 instance is now mutated
      -> fires its own :Observe / :OnChanged / :OnArrayInsert / etc.
      -> application code reacts (UI, gameplay, ...)
```

### Why the double `task.defer`

`FrameCoordinator:_ScheduleFlush` defers twice before flushing. This is a
best-effort attempt to let as many same-frame writes as possible land in the
buffer before it drains, so a frame with many `Set` calls across many
replicators still produces only one wire message per player.

### Structural items (Create / Destroy / SetParent)

These bypass `FrameCoordinator` and go straight from `ServerReplicator`
through `ReplicationScope:SendTo` / `transport:SendMessage`, still encoded
with the same `RefCodec.Encode` → `FlatCodec.BuildMessage` pair (see
`buildMessage` in `Server/ServerReplicator.luau`). Because a child's `Create`
must always precede any op targeting it, and a `Destroy` must always be the
last thing sent for a replicator, these stay synchronous rather than
sharing the per-frame buffer. `ServerReplicator.Destroy` also calls
`frameCoordinator:DropReplicator(id)` first, so any op already queued this
frame for a replicator can't flush out *after* its `Destroy` item.

### Initial snapshot (the `RequestData` handshake)

```
Client                                  Server
  │  ClientReplicator.RequestData()       │
  │  -> remote:FireServer("RequestData")  │
  ├───────────────────────────────────────▶
  │                                       │ transport.PlayerRequestedData fires
  │                                       │ for each top-level replicator targeting
  │                                       │ this player: scope:Activate(player),
  │                                       │ DFS-collect Create items (parent before child)
  │  ◀── WireMessage { Items = [Create...] } (one message, all snapshots)
  │                                       │
  │  ◀── "RequestDataComplete" (bare string marker)
  │  _dataComplete:Fire() -> RequestData()'s Promise resolves
```

Both messages travel over the same reliable `RemoteEvent`, so Roblox's
ordered-delivery guarantee is what lets the client trust that every snapshot
item already arrived by the time `RequestDataComplete` does.

## Ordering & consistency guarantees

- **Global order, not per-scope.** All scopes funnel data ops through one
  `FrameCoordinator`, so ops from *different* replicators/`TableManager`s
  replay on the client in the exact order the server produced them.
- **Audience captured at enqueue, validated at flush.** A player added to a
  scope mid-frame never double-applies an op already baked into their
  snapshot; a player removed mid-frame never receives an op for a replicator
  they were already told to drop.
- **At most one message per player per frame** for data ops, via the
  deferred flush.
- **One `Batch` per flush on the client.** `OpApplier.Apply` wraps a whole
  flush's ops in a single `manager:Batch`, so client-side listeners see one
  coalesced update regardless of how many writes the server made.

## Wire format

`Shared/Types.luau` defines the wire shapes; `FlatCodec.luau` is the encoder/
decoder for them.

| Opcode (`FlatCodec.Op`) | Item | Carries |
| --- | --- | --- |
| `Create` | `WireCreateItem` | `Id`, `ParentId` (`0` = top-level), `Token` (Namespace string; `""` = anonymous), `Tags`, `Data` |
| `Destroy` | `WireDestroyItem` | `Id` |
| `SetParent` | `WireSetParentItem` | `Id`, `ParentId` |
| `Ops` | `WireOpsItem` | `Id`, `Ops: { WireOpEntry }` (numeric `Kind`, `Path`, `Value?`, `Index?`) |

A `WireMessage` is `{ V, Items, Refs? }` — `V` is `FlatCodec.Version`, `Refs`
is the optional Model V de-dup pool below.

### RefCodec ("Model V" table de-duplication)

A Luau table referenced from two or more places in the **same message**
(e.g. one inner table shared at two paths in a snapshot, or fanned out to two
managers) is sent once: its contents go into `WireMessage.Refs[id]`, and every
occurrence in the items is replaced by a placeholder `{ ["\0RR_REF"] = id }`.
The client (`RefCodec.ResolveValue`) expands each placeholder into an
**independent copy** per top-level value — two managers that shared a table
on the server end up with two equal-but-separate client tables, kept in sync
by the server continuing to fan out ops to both. No-op fast path (no rewrite,
no `Refs`) when nothing in a message is actually shared.
