--!strict
--[=[
	@ignore
	@class FlatCodec

	The generic (fallback) wire codec. Items use small numeric opcodes instead
	of string tags so a frame is cheap to inspect/iterate, but variable-length
	fields (paths, tags, raw table data) stay as ordinary Luau tables -- true
	byte-level packing is the job of the schema-driven codec (a later phase),
	not this one. Every public function here is a pure data transform; nothing
	touches a Roblox Instance, which keeps it directly unit-testable.
]=]

local Types = require("../Types")

type Id = Types.Id
type PathArray = Types.PathArray
type Tags = Types.Tags
type BufferedOp = Types.BufferedOp
type OpKind = Types.OpKind
type WireItem = Types.WireItem
type WireMessage = Types.WireMessage
type WireCreateItem = Types.WireCreateItem
type WireDestroyItem = Types.WireDestroyItem
type WireSetParentItem = Types.WireSetParentItem
type WireOpsItem = Types.WireOpsItem
type WireOpEntry = Types.WireOpEntry

local FlatCodec = {}

-- Wire format version. Bump when the `WireItem`/`WireOpEntry` shapes change
-- in a way that isn't backwards-readable.
FlatCodec.Version = 2

-- `0` is reserved to mean "no parent" (top-level) since real replicator Ids
-- start at 1; this avoids sending a separate `ParentId: number?` optional field.
FlatCodec.NoParent = 0 :: Id

-- Item opcodes.
local Op = table.freeze {
	Create = 1,
	Destroy = 2,
	SetParent = 3,
	Ops = 4,
}
FlatCodec.Op = Op

-- Op-entry kinds. Maps 1:1 onto `Types.OpKind`.
local Kind = table.freeze {
	Set = 1,
	ArrayInsert = 2,
	ArrayRemove = 3,
	ArraySet = 4,
	BatchBegin = 5,
	BatchEnd = 6,
	-- Ordered signal / ordered function response fired through the ops buffer so
	-- it arrives at the client in the same sequence as adjacent data ops.
	-- Wire layout: Path = { signalName }, Value = { ...args }.
	Signal = 7,
}
FlatCodec.Kind = Kind

const KindToOpKind: { [number]: OpKind } = table.freeze {
	[Kind.Set] = "Set" :: OpKind,
	[Kind.ArrayInsert] = "ArrayInsert" :: OpKind,
	[Kind.ArrayRemove] = "ArrayRemove" :: OpKind,
	[Kind.ArraySet] = "ArraySet" :: OpKind,
	[Kind.BatchBegin] = "BatchBegin" :: OpKind,
	[Kind.BatchEnd] = "BatchEnd" :: OpKind,
	[Kind.Signal] = "Signal" :: OpKind,
}

const OpKindToKind = table.freeze {
	Set = Kind.Set,
	ArrayInsert = Kind.ArrayInsert,
	ArrayRemove = Kind.ArrayRemove,
	ArraySet = Kind.ArraySet,
	BatchBegin = Kind.BatchBegin,
	BatchEnd = Kind.BatchEnd,
	Signal = Kind.Signal,
} :: { [OpKind]: number }


function FlatCodec.BuildMessage(items: { WireItem }): WireMessage
	return { V = FlatCodec.Version, Items = items }
end

function FlatCodec.CreateItem(id: Id, parentId: Id?, token: string, tags: Tags, data: { [any]: any }, remotes: { [string]: string }?): WireCreateItem
	return {
		Op = Op.Create,
		Id = id,
		ParentId = parentId or FlatCodec.NoParent,
		Token = token,
		Tags = tags,
		Data = data,
		Remotes = remotes,
	}
end

function FlatCodec.DestroyItem(id: Id): WireDestroyItem
	return { Op = Op.Destroy, Id = id }
end

function FlatCodec.SetParentItem(id: Id, parentId: Id?): WireSetParentItem
	return { Op = Op.SetParent, Id = id, ParentId = parentId or FlatCodec.NoParent }
end

--[=[
	Converts a list of `BufferedOp` (internal, string-`Kind` form) into one
	`WireOpsItem` (wire, numeric-`Kind` form) for replicator `id`.
]=]
function FlatCodec.OpsItem(id: Id, ops: { BufferedOp }): WireOpsItem
	local entries = table.create(#ops) :: { WireOpEntry }
	for i, op in ops do
		entries[i] = {
			Kind = OpKindToKind[op.Kind],
			Path = op.Path,
			Value = op.Value,
			Index = op.Index,
		}
	end
	return { Op = Op.Ops, Id = id, Ops = entries }
end

--[=[
	Inverse of `OpsItem`: converts a decoded `WireOpsItem`'s entries back into
	`BufferedOp`s with friendly string `Kind`s for `OpApplier` to consume.
]=]
function FlatCodec.DecodeOps(item: WireOpsItem): { BufferedOp }
	local ops = table.create(#item.Ops) :: { BufferedOp }
	for i, entry in item.Ops do
		ops[i] = {
			Kind = KindToOpKind[entry.Kind],
			Path = entry.Path or {},
			Value = entry.Value,
			Index = entry.Index,
		}
	end
	return ops
end

return FlatCodec
