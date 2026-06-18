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
	- an active link group (cross-manager fan-out rides inside the same
	  diff-dispatch this gate would otherwise skip — see
	  `LinkGroup.FanOutSet`/`FanOutArrayOp`).

	False means a write at `path` is provably unobservable right now.
]=]

const PathHelpers = require("./PathHelpers")
const TMTypes = require("./TMTypes")
const Diff = require("./Diff")

--// Types //--
type PathArray<S = string> = PathHelpers.PathArray<S>
type TM_Internal<T> = TMTypes.TM_Internal<T>
type TableManagerLike = TMTypes.TableManagerLike

const Coverage = {}

function Coverage.IsTrackable(self: TableManagerLike, path: PathArray): boolean
	if self._linkGroups ~= nil and self._linkGroups[1] ~= nil then
		return true
	end
	if
		self.ValueChanged:IsConnectedTo()
		or self.KeyAdded:IsConnectedTo()
		or self.KeyRemoved:IsConnectedTo()
		or self.KeyChanged:IsConnectedTo()
		or self.ArrayInserted:IsConnectedTo()
		or self.ArrayRemoved:IsConnectedTo()
		or self.ArraySet:IsConnectedTo()
	then
		return true
	end
	return self._listenerRegistry:CoversChangesAt(path)
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
