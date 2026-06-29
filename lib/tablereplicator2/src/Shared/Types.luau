--!strict
--[=[
	@ignore
	@class Types

	Shared type definitions used across the Server, Client, and Shared modules.
]=]

const TableManagerModule = require("../../TableManager")
const Signal = require("../../Signal")
const TokenCache = require("./TokenCache")

export type TableManager<T = { [any]: any }> = TableManagerModule.TableManager<T>
export type AppliedOp = TableManagerModule.AppliedOp
export type ReplicationToken = TokenCache.ReplicationToken

export type Id = number
export type PathArray = { any }
export type Path = string | PathArray
export type Tags = { [string]: any }

export type Signal<Fn, Args...> = Signal.Signal<Fn, Args...>

--[=[
	@within Types
	@type ReplicationTargets "all" | Player | {Player}
	The Player(s) that a top-level replicator should replicate to.
	`"all"` replicates to all current and future players.
]=]
export type ReplicationTargets = "all" | Player | { Player }

--[=[
	@within Types
	@type SearchCondition string | ReplicationToken | Tags | (replicator: any) -> boolean
	A condition used to filter replicators in `ForEach`/`OnNew`/`FindFirstChild`/etc.
	- `string`: matches a replicator whose token name equals the string.
	- `ReplicationToken`: matches a replicator using that exact token.
	- `Tags`: matches a replicator whose tags are a superset of the given tags.
	- `function`: a custom predicate.
]=]
export type SearchCondition = string | ReplicationToken | Tags | (replicator: any) -> boolean

-- The kind of a single normalized, wire-ready operation. Mirrors `AppliedOp.Kind`
-- (see TableManager2's TMTypes) with no changes -- BatchBegin/BatchEnd are
-- pass-through markers, not state-bearing ops.
export type OpKind = "Set" | "ArrayInsert" | "ArrayRemove" | "ArraySet" | "BatchBegin" | "BatchEnd"

--[=[
	@within Types
	@interface BufferedOp
	.Kind OpKind
	.Path PathArray
	.Value any? -- final value for Set / ArrayInsert / ArraySet; unused for ArrayRemove/Batch*
	.Index number? -- array ops only

	One normalized operation queued in a `ReplicationScope`'s per-frame buffer,
	derived from a TableManager2 `AppliedOp` (a `Diff`-carrying op is flattened
	to one `BufferedOp` per changed leaf before being queued).
]=]
export type BufferedOp = {
	Kind: OpKind,
	Path: PathArray,
	Value: any?,
	Index: number?,
}

-- A single item in a wire message. `Op` distinguishes the item shape; see
-- WireFormat for the opcode constants. Replicator hierarchy uses `ParentId = 0`
-- to mean "top level" since `0` is never a valid replicator Id.
export type WireCreateItem = {
	Op: number,
	Id: Id,
	ParentId: Id,
	Token: string,
	Tags: Tags,
	Data: { [any]: any },
}

export type WireDestroyItem = {
	Op: number,
	Id: Id,
}

export type WireSetParentItem = {
	Op: number,
	Id: Id,
	ParentId: Id,
}

export type WireOpEntry = {
	Kind: number,
	Path: PathArray?,
	Value: any?,
	Index: number?,
}

export type WireOpsItem = {
	Op: number,
	Id: Id,
	Ops: { WireOpEntry },
}

export type WireItem = WireCreateItem | WireDestroyItem | WireSetParentItem | WireOpsItem

export type WireMessage = {
	V: number,
	Items: { WireItem },
	-- Model V table de-dup pool (see RefCodec): present only when a table was
	-- shared across this message's items. Maps a per-message ref id to the
	-- table's contents; placeholders `{ [RefCodec.Marker] = id }` in item Data /
	-- op Values resolve against it. Absent in the common no-aliasing case.
	Refs: { [number]: any }?,
}

return {}
