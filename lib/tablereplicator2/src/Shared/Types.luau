--!strict
--[=[
	@ignore
	@class Types

	Shared type definitions used across the Server, Client, and Shared modules.
]=]

const TableManagerModule = require("../../../tablemanager2/src/TableManager")
const Signal = require("../../Signal")
const Promise = require("../../Promise")
const Janitor = require("../../Janitor")
const TokenCache = require("./TokenCache")
const ReplicationScope = require("../Server/ReplicationScope")

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
}

--------------------------------------------------------------------------------
	--// Type Functions //--
--------------------------------------------------------------------------------

-- Currently unused. Waiting for Luau type functions to better support generics.
export type function xorKeySets(tbl, specA, specB)
    assert(tbl:is("table"), "xorKeySets: first argument must be a table type")
    assert(specA:is("table"), "xorKeySets: second argument must be a table type")
    assert(specB:is("table"), "xorKeySets: third argument must be a table type")

    local function keyName(key)
        return key:is("singleton") and key:value() or nil
    end

    -- collect key names belonging to each branch
    local aKeys, bKeys = {}, {}
    for key in specA:properties() do
        aKeys[keyName(key)] = true
    end
    for key in specB:properties() do
        bKeys[keyName(key)] = true
    end

    local nilType = types.singleton(nil)

    -- shared base = everything in tbl that isn't in either branch's keyset
    local base = types.newtable({})
    for key, prop in tbl:properties() do
        local k = keyName(key)
        if not aKeys[k] and not bKeys[k] then
            base:setproperty(key, prop.read)
        end
    end

    -- branch where A's keys are present, B's keys are forced nil
    local onlyA = types.newtable({})
    for key, prop in base:properties() do
        onlyA:setproperty(key, prop.read)
    end
    for key, prop in specA:properties() do
        onlyA:setproperty(key, prop.read)
    end
    for key in pairs(bKeys) do
		assert(typeof(key) == "string", "xorKeySets: key name must be a string")
        onlyA:setproperty(types.singleton(key), nilType)
    end

    -- branch where B's keys are present, A's keys are forced nil
    local onlyB = types.newtable({})
    for key, prop in base:properties() do
        onlyB:setproperty(key, prop.read)
    end
    for key, prop in specB:properties() do
        onlyB:setproperty(key, prop.read)
    end
    for key in pairs(aKeys) do
		assert(typeof(key) == "string", "xorKeySets: key name must be a string")
        onlyB:setproperty(types.singleton(key), nilType)
    end

    return types.unionof(onlyA, onlyB)
end

--------------------------------------------------------------------------------
	--// Replicator type definitions //--
--------------------------------------------------------------------------------
export type BR_Public<BR> = {
	-- Signals
	ChildAdded: Signal.Signal<(child: BR) -> (), BR>,
	ChildRemoved: Signal.Signal<(child: BR) -> (), BR>,
	ParentChanged: Signal.Signal<
		(newParent: BR?, oldParent: BR?) -> (),
		BR?,
		BR?
	>,

	-- Readable Fields
	Id: Id,
	Tags: Tags,
	Manager: TableManager<any>,

	-- Methods
	GetTokenName: (self: BR) -> string,
	IsTopLevel: (self: BR) -> boolean,

	GetParent: (self: BR) -> BR?,
	GetChildren: (self: BR) -> { BR },
	GetDescendants: (self: BR) -> { BR },
	FindFirstChild: (self: BR, condition: SearchCondition?, recursive: boolean?) -> BR?,
	PromiseFirstChild: (self: BR, condition: SearchCondition?) -> Promise.TypedPromise<BR>,

	IsSupersetOfTags: (self: BR, tags: Tags) -> boolean,
	IsSubsetOfTags: (self: BR, tags: Tags) -> boolean,

	Destroy: (self: BR) -> (),
}


export type BR_Internal<BR = BR_Internal> = {
	_Token: ReplicationToken,
	_Parent: BR?,
	_Children: { BR },
	_Janitor: Janitor.Janitor,
	_CreationListenersFired: boolean,

	_FireCreationListeners: (self: BR) -> (),
	_SetParentRefs: (self: BR, newParent: BR?) -> (),
} & BR_Public<BR>


export type BaseReplicator = BR_Public<BaseReplicator>

---------------------------------------------------------------
export type SR_Public<SR> = {
	SetTargets: (self: SR, targets: ReplicationTargets) -> (),
	AddTarget: (self: SR, target: Player | { Player }) -> (),
	RemoveTarget: (self: SR, target: Player | { Player }) -> (),
	GetTargets: (self: SR) -> { Player },
	IsReplicatingTo: (self: SR, player: Player) -> boolean,
	SetParent: (self: SR, newParent: SR?) -> (),
}

export type SR_Internal = {
	_Scope: ReplicationScope.ReplicationScope,
	_Coalesced: boolean,
	_Unreliable: boolean,

	_SendSnapshotTo: (self: SR_Internal, player: Player) -> (),
	_AddTarget: (self: SR_Internal, player: Player) -> (),
	_RemoveTarget: (self: SR_Internal, player: Player) -> (),
} & SR_Public<SR_Internal> & BR_Internal<SR_Internal>

export type ServerReplicator = SR_Public<ServerReplicator> & BR_Public<ServerReplicator>

---------------------------------------------------------------

export type CR_Internal = BR_Internal<CR_Internal>

--[=[
	@within Types
	@type ClientReplicator
	Client-side mirror of a ServerReplicator.
]=]
export type ClientReplicator = BR_Public<ClientReplicator>

---------------------------------------------------------------

return {
	Signal = Signal,
	TableManager = TableManagerModule,
	Promise = Promise,
	Janitor = Janitor,
}
