--!strict
--!native
--!optimize 2
--[=[
	@ignore
	@class Baseline

	The seam between TableManager's flush/dispatch logic and the concrete
	"last-emitted" baseline store (`ShadowNode`, a stateless, global
	identity-keyed node registry). Every read, reconcile, pre-write seed, and
	post-op sync of the baseline goes through here, which supplies `ShadowNode`
	with the two things it needs and never holds itself: `manager.Raw` (the
	root to resolve against) and `Propagation.IsObserved` (the global
	observership predicate that decides each slot's shape). Also consolidates
	the `IsTrackable` + `PassesThroughOpaqueAncestor` gate that the array-op /
	batch / linked-apply sync sites each open-coded.
]=]

const PathHelpers = require("../PathHelpers")
const CoverageModule = require("../Diffing/Coverage")
const TMTypes = require("../TMTypes")
const ShadowNodeModule = require("./ShadowNode")
const PropagationModule = require("../Propagation")

--// Types //--
type PathArray = PathHelpers.PathArray
type TableManagerLike = TMTypes.TableManagerLike

const shadowGet = ShadowNodeModule.Get
const shadowReconcile = ShadowNodeModule.Reconcile
const shadowMaterialize = ShadowNodeModule.Materialize
const isObserved = PropagationModule.IsObserved
const isTrackable = CoverageModule.IsTrackable

const Baseline = {}

--[[
	Read: the last-emitted baseline value at `path` (the diff "old"). `nil` when
	`path` was never materialized.
]]
function Baseline.Get(manager: TableManagerLike, path: PathArray): any
	return shadowGet(manager.Raw, path)
end

--[[
	Post-diff reconcile: bring the baseline at `path` up to the current live
	value (the new "last emitted"). Slot shape is decided by global
	observership, not this manager's opacity.
]]
function Baseline.Reconcile(manager: TableManagerLike, path: PathArray)
	shadowReconcile(manager.Raw, path, isObserved)
end

--[[
	Post-op sync: materialize the baseline at `path` to the live value IF `path`
	is trackable and does not pass through an opaque ancestor. This is the single
	primitive the array-op, batch-resume, and linked-apply sync sites call instead
	of re-deriving the same gate around `ShadowNode.Materialize`.
]]
function Baseline.Materialize(manager: TableManagerLike, path: PathArray)
	if not isTrackable(manager, path) then
		return
	end
	const ctx = manager._changeDetector:GetOpaqueCtx()
	if CoverageModule.PassesThroughOpaqueAncestor(manager, path, ctx) then
		return
	end
	shadowMaterialize(manager.Raw, path, isObserved)
end

--[[
	Post-write baseline patch for the known-delta scalar write lane
	(`Mutator.applyWrite`'s fast lane): applies a scalar leaf write (already
	applied to `manager.Raw`) directly to the baseline spine instead of a full
	`Reconcile` walk + re-copy, falling back to a full `Materialize` the first
	time `path` is tracked (no spine to patch yet). The CALLER owns the
	trackable / opaque-ancestor gate, same contract as `SeedIfNeeded`.
]]
function Baseline.ApplyLeafSet(manager: TableManagerLike, path: PathArray, newValue: any)
	if not ShadowNodeModule.ApplyLeafSet(manager.Raw, path, newValue) then
		shadowMaterialize(manager.Raw, path, isObserved)
	end
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
	newValue: any,
	knownTrackable: boolean?
)
	-- `knownTrackable == true` means the emitting mutator already resolved the
	-- trackable gate for this same op; anything else re-derives it here.
	if knownTrackable ~= true and not isTrackable(manager, path) then
		return
	end
	const ctx = manager._changeDetector:GetOpaqueCtx()
	if CoverageModule.PassesThroughOpaqueAncestor(manager, path, ctx) then
		return
	end
	const applied =
		ShadowNodeModule.ApplyArrayOp(manager.Raw, path, opKind, index, newValue, isObserved)
	if not applied then
		shadowMaterialize(manager.Raw, path, isObserved)
	end
end

--[[
	Root-identity swap (`Set({}, newRoot)`): re-key the root baseline node from
	`oldRoot` to `newRoot` so the post-swap root diff still reads the seeded
	pre-swap baseline. Must be called AFTER `manager.Raw` becomes `newRoot` and
	BEFORE the root flush. See `ShadowNode.RebindRoot`.
]]
function Baseline.RebindRoot(oldRoot: any, newRoot: any)
	ShadowNodeModule.RebindRoot(oldRoot, newRoot)
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
function Baseline.SeedIfNeeded(manager: TableManagerLike, path: PathArray, oldValue: any)
	if oldValue == nil or shadowGet(manager.Raw, path) ~= nil then
		return
	end
	shadowMaterialize(manager.Raw, path, isObserved)
end

return Baseline
