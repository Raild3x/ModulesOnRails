--!strict
--[=[
	@ignore
	@class Emitter

	The single emit/notify core for TableManager. Every change event — whether
	from the diff-driven Set path (ChangeDetector callbacks) or the synthetic
	array-op path — flows through `makeEmit`/`fireArrayOperation` so the
	signal+listener dual-fire lives in exactly one place.
]=]

--// Imports //--
const PathHelpers = require("./PathHelpers")
const BatchUtilsModule = require("./BatchUtils")
const BatchFlushModule = require("./BatchFlush")
const ArrayDiffModule = require("./ArrayDiff")
const ChangeDetectorModule = require("./ChangeDetector")
const LinkGroupModule = require("./LinkGroup")
const Diff = require("./Diff")
const TMTypes = require("./TMTypes")

--// Types //--
type PathArray<S = string> = PathHelpers.PathArray<S>
type ChangeMetadata = ChangeDetectorModule.ChangeMetadata
type MoveMetadata = ArrayDiffModule.MoveMetadata
type DiffNode = Diff.DiffNode
type TableManagerLike = TMTypes.TableManagerLike

const createSyntheticSnapshot = BatchUtilsModule.CreateSyntheticSnapshot

const Emitter = {}

-- ---------------------------------------------------------------------------
-- Synthetic metadata helpers
-- ---------------------------------------------------------------------------

local function createSyntheticDiffNode(
	kind: "added" | "removed" | "changed",
	key: any,
	newValue: any,
	oldValue: any
): DiffNode
	return {
		type = kind,
		new = newValue,
		old = oldValue,
		key = key,
	}
end

local function createSyntheticMetadata(
	rootTable: any,
	leafPath: PathArray,
	kind: "added" | "removed" | "changed",
	key: any,
	newValue: any,
	oldValue: any
): ChangeMetadata
	return {
		Diff = createSyntheticDiffNode(kind, key, newValue, oldValue),
		OriginPath = leafPath,
		OriginDiff = createSyntheticDiffNode(kind, key, newValue, oldValue),
		Snapshot = createSyntheticSnapshot(rootTable, leafPath, newValue),
	}
end

-- ---------------------------------------------------------------------------
-- Core notification primitives
-- ---------------------------------------------------------------------------

--[[
	Fires ancestor `ValueChanged` (and, when `includeKeyChanged` is not false,
	`KeyChanged`) listeners from `basePath` up to the root, building a
	"descendant changed" metadata for each ancestor.
]]
function Emitter.fireAncestorValueChangedNotifications(
	manager: any, -- TableManagerLike (typed `any` to avoid Luau generic-recursive poison)
	basePath: PathArray,
	metadata: ChangeMetadata,
	includeKeyChanged: boolean?
)
	const ancestorMetadata: ChangeMetadata = {
		Diff = nil,
		OriginPath = metadata.OriginPath,
		OriginDiff = metadata.OriginDiff,
		Snapshot = metadata.Snapshot,
		ArrayOp = metadata.ArrayOp,
	}

	const keyChangedMode = if includeKeyChanged == false then "none" else "child"

	ChangeDetectorModule.EmitAncestorNotifications(
		basePath :: { any },
		#basePath,
		ancestorMetadata,
		nil,
		keyChangedMode,
		function(path, key, newValue, oldValue, m)
			manager._listenerRegistry:FireListenersExact("KeyChanged", path, {
				Key = key,
				NewValue = newValue,
				OldValue = oldValue,
				Metadata = m,
			})
		end,
		function(path, newValue, oldValue, m)
			manager._listenerRegistry:FireListenersExact("ValueChanged", path, {
				NewValue = newValue,
				OldValue = oldValue,
				Metadata = m,
			})
		end
	)
end

--[[
	Fires the appropriate `Array*` signal + exact-path listeners + ancestor
	ValueChanged callbacks, and fans out to any linked managers. Must be
	called AFTER the mutation so `manager._originalData` reflects the new state.
]]
function Emitter.fireArrayOperation(
	manager: TableManagerLike,
	eventName: "ArrayInserted" | "ArrayRemoved" | "ArraySet",
	basePath: PathArray,
	leafPath: PathArray,
	payload: any
)
	-- Tag metadata with explicit shift semantics for diff-tree consumers
	-- (OriginDiff via root OnChange listeners).
	payload.Metadata.ArrayOp = { Kind = eventName, Index = payload.Index }

	-- Fire at element path first (element-level listeners), then at array
	-- path (array-level listeners), then ancestors (ValueChanged).
	manager._listenerRegistry:FireListenersExact(eventName, leafPath, payload)
	manager._listenerRegistry:FireListenersExact(eventName, basePath, payload)
	Emitter.fireAncestorValueChangedNotifications(manager, basePath, payload.Metadata)

	if eventName == "ArrayInserted" then
		manager.ArrayInserted:Fire(basePath, payload.Index, payload.NewValue)
	elseif eventName == "ArrayRemoved" then
		manager.ArrayRemoved:Fire(basePath, payload.Index, payload.OldValue)
	elseif eventName == "ArraySet" then
		manager.ArraySet:Fire(basePath, payload.Index, payload.NewValue, payload.OldValue)
	end

	if not manager._suppressLinkFanOut then
		LinkGroupModule.FanOutArrayOp(manager, eventName, basePath, payload)
	end
end

--[[
	Builds the `Emit` interface for a single array path, wiring the three
	callbacks to fire `ArrayRemoved`/`ArrayInserted`/`ArraySet` signals,
	exact-path listeners, and ancestor callbacks in the correct order.

	The returned table is stored on `self._MakeEmit` so BatchFlush can call
	it without a circular require.
]]
-- Return type is intentionally unannotated: the `set` callback accepts an
-- optional 4th `move` arg (used by ArraySwapRemove) beyond what
-- `ArrayDiff.Emit` declares, and the inferred type captures that correctly.
function Emitter.makeEmit(manager: TableManagerLike, path: PathArray)
	return {
		removed = function(index: number, oldValue: any, move: MoveMetadata?)
			const removedPath: PathArray = PathHelpers.Append(path, index)
			const metadata =
				createSyntheticMetadata(manager._originalData, removedPath, "removed", index, nil, oldValue)
			metadata.Move = move
			Emitter.fireArrayOperation(manager, "ArrayRemoved", path, removedPath, {
				Index = index,
				OldValue = oldValue,
				Metadata = metadata,
			})
		end,
		inserted = function(index: number, newValue: any, move: MoveMetadata?)
			const insertedPath = PathHelpers.Append(path, index)
			const metadata = createSyntheticMetadata(manager._originalData, insertedPath, "added", index, newValue, nil)
			metadata.Move = move
			Emitter.fireArrayOperation(manager, "ArrayInserted", path, insertedPath, {
				Index = index,
				NewValue = newValue,
				Metadata = metadata,
			})
		end,
		set = function(index: number, newValue: any, oldValue: any, move: MoveMetadata?)
			const setPath = PathHelpers.Append(path, index)
			const metadata =
				createSyntheticMetadata(manager._originalData, setPath, "changed", index, newValue, oldValue)
			metadata.Move = move
			Emitter.fireArrayOperation(manager, "ArraySet", path, setPath, {
				Index = index,
				NewValue = newValue,
				OldValue = oldValue,
				Metadata = metadata,
			})
		end,
	}
end

--[[
	Builds the synthetic-metadata struct used by `ForceNotify` and by the
	`onArrayAppended` fast path (for externally-supplied roots/paths/values).
]]
function Emitter.makeSyntheticMetadata(
	rootTable: any,
	leafPath: PathArray,
	kind: "added" | "removed" | "changed",
	key: any,
	newValue: any,
	oldValue: any
): ChangeMetadata
	return createSyntheticMetadata(rootTable, leafPath, kind, key, newValue, oldValue)
end

-- ---------------------------------------------------------------------------
-- ChangeDetector callback factory
-- ---------------------------------------------------------------------------

--[[
	Builds the four ChangeDetector callbacks for a newly-constructed
	TableManager, wrapping the signal+listener dual-fire in a single call site.
	Replaces the ~80 lines of near-identical inline closures in
	`TableManager.new`.
]]
function Emitter.makeChangeDetectorCallbacks(manager: TableManagerLike)
	-- Suppresses non-array change events during batch array flush whose location
	-- is at or under a tracked array path (see BatchFlush.ShouldSuppress).
	local function shouldSuppress(location: PathArray): boolean
		return BatchFlushModule.ShouldSuppress(manager :: any, location)
	end

	return {
		OnKeyAdded = function(path: PathArray, key: any, newValue: any, metadata: ChangeMetadata)
			if shouldSuppress(PathHelpers.Append(path, key)) then
				return
			end
			-- Signal before registry listeners: if a listener performs a re-entrant
			-- write its nested signal fires after this one, keeping the public
			-- signal stream in write-initiation order (deterministic for replication).
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				manager.KeyAdded:Fire(path, key, newValue)
			end
			manager._listenerRegistry:FireListenersExact("KeyAdded", path, {
				NewValue = newValue,
				Key = key,
				Metadata = metadata,
			})
		end,

		OnKeyRemoved = function(path: PathArray, key: any, oldValue: any, metadata: ChangeMetadata)
			if shouldSuppress(PathHelpers.Append(path, key)) then
				return
			end
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				manager.KeyRemoved:Fire(path, key, oldValue)
			end
			manager._listenerRegistry:FireListenersExact("KeyRemoved", path, {
				OldValue = oldValue,
				Key = key,
				Metadata = metadata,
			})
		end,

		OnKeyChanged = function(path: PathArray, key: any, newValue: any, oldValue: any, metadata: ChangeMetadata)
			if shouldSuppress(PathHelpers.Append(path, key)) then
				return
			end
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				manager.KeyChanged:Fire(path, key, newValue, oldValue)
			end
			manager._listenerRegistry:FireListenersExact("KeyChanged", path, {
				NewValue = newValue,
				OldValue = oldValue,
				Key = key,
				Metadata = metadata,
			})
		end,

		OnValueChanged = function(path: PathArray, newValue: any, oldValue: any?, metadata: ChangeMetadata)
			-- Suppress events at or under a tracked array path during batch array
			-- flush; those arrays emit their own coalesced Array* events.
			if shouldSuppress(path) then
				return
			end
			-- Signal before listeners (see OnKeyAdded for rationale).
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				manager.ValueChanged:Fire(path, newValue, oldValue)
			end
			manager._listenerRegistry:FireListenersExact("ValueChanged", path, {
				NewValue = newValue,
				OldValue = oldValue,
				Metadata = metadata,
			})
			-- Link fan-out: only for leaf changes, never while replaying fan-out.
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" and not manager._suppressLinkFanOut then
				LinkGroupModule.FanOutSet(manager, path, newValue, oldValue)
			end
		end,
	}
end

return Emitter
