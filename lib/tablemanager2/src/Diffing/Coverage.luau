--!strict
--[=[
	@ignore
	@class Coverage

	Shared "could a write at this path be observed by anything at all" gate.
	Used by `Mutator` (skip the shadow-seed + flush for unobserved writes),
	`Emitter` (skip the array-shadow-sync for unobserved array ops),
	`TableManager` (the public `Flush`), and `BatchFlush` (the post-Resume
	shadow reconciliation pass). Kept as its own leaf module (rather than
	living in `Mutator`, which it originated in) so `Emitter`/`TableManager`/
	`BatchFlush` can all call it without creating a circular require.

	A single OR of three independent observation sources:
	- a `ListenerRegistry` listener covering `path` (`CoversChangesAt`);
	- a connection on one of the 7 global Signals (each fires for ANY path,
	  so any connection forces full tracking);
	- co-observing a shared table identity with another manager (cross-manager
	  fan-out rides inside the same diff-dispatch this gate would otherwise skip —
	  see `Propagation.FanOutSet`/`FanOutArrayOp`).

	False means a write at `path` is provably unobservable right now.
]=]

const PathHelpers = require("../PathHelpers")
const TMTypes = require("../TMTypes")
const Diff = require("./Diff")

--// Types //--
type PathArray<S = string> = PathHelpers.PathArray<S>
type TM_Internal<T> = TMTypes.TM_Internal<T>
type TableManagerLike = TMTypes.TableManagerLike

const Coverage = {}

--[=[
	True if a change at `path` would fire any of THIS manager's own
	listeners/signals — a global Signal connection (each fires for any path) or
	a registry listener covering `path` (including via an ancestor/subtree, see
	`ListenerRegistry.CoversChangesAt`). Unlike `IsTrackable`, membership in a
	link group does NOT make this true: it answers "does this manager itself
	observe `path`", independent of fan-out obligations.
]=]
-- True if ANY of the manager's 7 public per-change Signals has a connection.
-- Each Signal fires for ANY path, and the dict diff drives one fire per changed
-- leaf, so a single connection both forces tracking AND makes the full diff depth
-- observable (see `ResolveDiffMaxDepth`).
const function hasConnectedSignal(self: TableManagerLike): boolean
	return self.ValueChanged:IsConnectedTo()
		or self.KeyAdded:IsConnectedTo()
		or self.KeyRemoved:IsConnectedTo()
		or self.KeyChanged:IsConnectedTo()
		or self.ArrayInserted:IsConnectedTo()
		or self.ArrayRemoved:IsConnectedTo()
		or self.ArraySet:IsConnectedTo()
end

function Coverage.IsLocallyObserved(self: TableManagerLike, path: PathArray): boolean
	if hasConnectedSignal(self) then
		return true
	end
	return self._listenerRegistry:CoversChangesAt(path)
end

--[=[
	Resolves the diff depth bound for a write at `path`: `nil` (unbounded / full
	depth) when any forcing condition holds, else the deepest registered listener
	reach strictly below `path` (`ListenerRegistry.MaxObservedDepth`). Each forcing
	condition makes the full subtree depth observable, so the bound must not apply:
	- a connected global Signal (one fire per changed leaf);
	- a link group (`_sharesObservers`; fan-out replays `metadata.Diff`);
	- any wildcard listener (depth not cheaply knowable);
	- any covering `ProvideDiff` listener (explicitly wants the subtree).

	Returning `0` means "no descendant listener" — diff only the `path` node itself.
	Only consulted on the immediate (non-`arraySink`) diff path for now; the batch
	flush stays full-depth.
]=]
function Coverage.ResolveDiffMaxDepth(self: TableManagerLike, path: PathArray): number?
	if hasConnectedSignal(self) then
		return nil
	end
	if self._sharesObservers then
		return nil
	end
	const registry = self._listenerRegistry
	if registry._hasWildcards then
		return nil
	end
	if registry:WantsFullDiff(path) then
		return nil
	end
	const depth = registry:MaxObservedDepth(path)
	if depth == math.huge then
		return nil
	end
	return depth
end

function Coverage.IsTrackable(self: TableManagerLike, path: PathArray): boolean
	-- Co-observing a shared identity forces tracking even with no local
	-- observers: a member's own write must still diff so it can fan out to
	-- managers that DO observe (cross-manager fan-out rides inside this
	-- diff-dispatch). See `Propagation` for the `_sharesObservers` flag.
	if self._sharesObservers then
		return true
	end
	return Coverage.IsLocallyObserved(self, path)
end

--[=[
	True if some ancestor of `path` (root through, and including, its direct
	parent) is marked opaque. `Shadow` can never safely persist an entry
	through an opaque ancestor: an opaque value is mirrored BY REFERENCE (so
	identity comparisons at ITS OWN level still work), which means treating it
	as a navigable container for a deeper path's shadow entry would alias live
	data — the next write through that same path would silently mutate the
	"old" baseline together with "new", or (if deep-copied instead) would
	violate the entire point of marking it opaque (callers may rely on it
	never being iterated/cloned, e.g. an Instance or a class instance with a
	metatable).

	Callers use this to bypass the persistent shadow for such paths and fall
	back to a one-off diff using a value already read fresh from live data —
	matching the old per-write CaptureSnapshot behavior for this narrow case.
]=]
function Coverage.PassesThroughOpaqueAncestor(self: TableManagerLike, path: PathArray, ctx: Diff.Ctx?): boolean
	if ctx == nil then
		return false
	end
	local current: any = self.Raw
	for i = 1, #path - 1 do
		if type(current) ~= "table" then
			return false
		end
		if ctx.isOpaque(current) then
			return true
		end
		current = current[path[i]]
	end
	return type(current) == "table" and ctx.isOpaque(current)
end

return Coverage
