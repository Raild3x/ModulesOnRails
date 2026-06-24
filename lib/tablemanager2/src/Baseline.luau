--!strict
--[=[
	@ignore
	@class Baseline

	The seam between TableManager's flush/dispatch logic and the concrete
	"last-emitted" baseline store (`ShadowNode`, the global identity-keyed node
	registry). Every read, reconcile, pre-write seed, and post-op sync of the
	baseline goes through here instead of touching `manager._shadow` directly,
	and consolidates the `IsTrackable` + `PassesThroughOpaqueAncestor` gate that
	the array-op / batch / linked-apply sync sites each open-coded.
]=]

const PathHelpers = require("./PathHelpers")
const CoverageModule = require("./Coverage")
const TMTypes = require("./TMTypes")
const ShadowNodeModule = require("./ShadowNode")
const PropagationModule = require("./Propagation")

--// Types //--
type PathArray = PathHelpers.PathArray
type TableManagerLike = TMTypes.TableManagerLike

const Baseline = {}

-- Creates the baseline store for a new manager (its `self._shadow`). The store
-- is handed the global `IsObserved` predicate so each table slot's shape
-- (content node vs. live ref) is keyed on global observership, independent of
-- this manager's own opacity — see `ShadowNode.copyForShadow`.
function Baseline.NewStore(manager: TableManagerLike): any
	return ShadowNodeModule.new(manager, PropagationModule.IsObserved)
end

--[[
	Read: the last-emitted baseline value at `path` (the diff "old"). `nil` when
	`path` was never materialized.
]]
function Baseline.Get(manager: TableManagerLike, path: PathArray): any
	return manager._shadow:Get(path)
end

--[[
	Post-diff reconcile: bring the baseline at `path` up to the current live
	value (the new "last emitted"). `ctx` is the manager's opacity oracle.
]]
function Baseline.Reconcile(manager: TableManagerLike, path: PathArray, ctx: any)
	manager._shadow:Reconcile(path, manager.Raw, ctx)
end

--[[
	Post-op sync: materialize the baseline at `path` to the live value IF `path`
	is trackable and does not pass through an opaque ancestor. This is the single
	primitive the array-op, batch-resume, and linked-apply sync sites call instead
	of re-deriving the same gate around `Shadow:Materialize`.
]]
function Baseline.Materialize(manager: TableManagerLike, path: PathArray)
	if not CoverageModule.IsTrackable(manager, path) then
		return
	end
	const ctx = manager._changeDetector:GetOpaqueCtx()
	if CoverageModule.PassesThroughOpaqueAncestor(manager, path, ctx) then
		return
	end
	manager._shadow:Materialize(path, manager.Raw, ctx)
end

--[[
	Post-array-op sync (Phase 4): applies a known array mutation (already
	applied to `manager.Raw`) directly to the existing baseline array at `path`,
	instead of re-copying the whole array via `Materialize`. Falls back to a full
	`Materialize` the first time `path` is tracked (no existing baseline array to
	mutate incrementally) — identical result to the pre-Phase-4 behavior for that
	case. Same trackable / opaque-ancestor gate as `Materialize`.
]]
function Baseline.ApplyArrayOp(
	manager: TableManagerLike,
	path: PathArray,
	opKind: "ArrayInserted" | "ArrayRemoved" | "ArraySet",
	index: number,
	newValue: any
)
	if not CoverageModule.IsTrackable(manager, path) then
		return
	end
	const ctx = manager._changeDetector:GetOpaqueCtx()
	if CoverageModule.PassesThroughOpaqueAncestor(manager, path, ctx) then
		return
	end
	const applied = manager._shadow:ApplyArrayOp(path, manager.Raw, opKind, index, newValue, ctx)
	if not applied then
		manager._shadow:Materialize(path, manager.Raw, ctx)
	end
end

--[[
	Root-identity swap (`Set({}, newRoot)`): re-key the root baseline node from
	`oldRoot` to `newRoot` so the post-swap root diff still reads the seeded
	pre-swap baseline. Must be called AFTER `manager.Raw` becomes `newRoot` and
	BEFORE the root flush. See `ShadowNode.RebindRoot`.
]]
function Baseline.RebindRoot(manager: TableManagerLike, oldRoot: any, newRoot: any)
	manager._shadow:RebindRoot(oldRoot, newRoot)
end

--[[
	Pre-write seed: the FIRST time a now-trackable `path` is written, capture its
	pre-write value as the baseline so the upcoming diff has the correct "old".
	`oldValue == nil` needs no seed (a missing entry already reads as `nil`); an
	already-seeded path is left untouched. Must be called BEFORE the write so
	`manager.Raw` still reflects the pre-write state. The caller is responsible
	for the trackable / opaque-ancestor gate (the previous `ensureShadowSeeded`
	contract; see `Coverage.PassesThroughOpaqueAncestor`).
]]
function Baseline.SeedIfNeeded(manager: TableManagerLike, path: PathArray, oldValue: any, ctx: any)
	if oldValue == nil then
		return
	end
	if manager._shadow:Get(path) ~= nil then
		return
	end
	manager._shadow:Materialize(path, manager.Raw, ctx)
end

return Baseline
